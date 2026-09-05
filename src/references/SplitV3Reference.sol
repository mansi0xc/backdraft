// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {PoolId} from "v4-core/types/PoolId.sol";
import {IReferencePrice} from "../interfaces/IReferencePrice.sol";
import {IUniswapV3PoolMinimal} from "../interfaces/IUniswapV3PoolMinimal.sol";

/// @notice External v3 reference price that REPORTS source disagreement rather than
///         switching itself off on it.
///
/// Reference:  v3 0.01% spot tick   — freshest, most-frequently-corrected
/// Guard:      v3 0.05% spot vs TWAP — deepest, hardest to push
///
/// divTicks = max(|deepSpot − deepTwap|, |fastSpot − deepSpot|)
///
/// The caller prices divTicks through DivergenceMath: below guardMaxDevTicks the
/// surcharge is unchanged, above it the surcharge climbs. Appendix §10 measured the
/// previous design — freeze on divergence — as an off-switch reachable for $7–$21, and
/// showed no tolerance value closes both the freeze route and the masking route.
///
/// Freeze survives only for failures an attacker cannot induce and the caller cannot
/// price around (returns ok=false — caller must treat as no-op):
///   1. Pool unconfigured
///   2. observe() unavailable (insufficient observation cardinality)
///   3. divTicks > freezeMaxDevTicks, when that backstop is enabled — see below
///
/// TRUNCATION (appendix §7). Optionally, the reference the hook SEES may move at most
/// `maxTicksPerBlock` ticks per block from the last committed value. This is the fix for
/// the two attacks the guard cannot close: a push moves the hook's view by at most B per
/// block however much the attacker spends, so masking a gap stops being a one-shot trade
/// and becomes a sustained cost, and a single-block reference glitch enters the hook's
/// view as at most B ticks instead of in full.
///
/// It is DISABLED by default (`maxTicksPerBlock == 0` is raw, byte-identical to the
/// untruncated path) because the evidence does not yet support switching it on: real
/// capture rests on n = 2 independent episodes, and the phantom cost it introduces is
/// non-monotone in B and regime-dependent. Enable per pool with setMaxTicksPerBlock once
/// B has been derived for the flow regime in question.
///
/// divTicks is deliberately computed on the RAW reads and passed through untouched. If
/// divergence were measured from the clamped value, a push would be hidden from the very
/// signal that prices it — truncation would silently disable the graduated multiplier and
/// hand the attacker the clamp AND the 1.00x rate.
///
/// See the README (Reference price, Measurement) for the rationale and the measured
/// error, and APPENDIX.md for the manipulation-cost analysis.
contract SplitV3Reference is IReferencePrice {
    // -------------------------------------------------------------------------
    // Config (immutable per deployment — pool pairs are fixed)
    // -------------------------------------------------------------------------

    struct Config {
        address fastPool;         // v3 0.01% — reference tick source
        address deepPool;         // v3 0.05% — manipulation guard
        uint32  twapWindow;       // guard TWAP window in seconds (1800)
        uint24  guardMaxDevTicks; // disagreement tolerated at 1.00x surcharge (50)
        uint24  freezeMaxDevTicks;// absurdity backstop; 0 disables freezing entirely.
                                  // This is a bounded off-switch, not an eliminated one:
                                  // §10's argument applies to ANY freeze condition, so
                                  // set it far above guardMaxDevTicks (recommended 5x)
                                  // where the reference is not merely pushed but
                                  // nonsensical, and accept that reaching it costs the
                                  // attacker roughly that multiple of the $21 baseline.
                                  // Truncated-oracle reference smoothing is the real fix;
                                  // it is implemented below and disabled by default.
        bool    invertTicks;      // true when v3 token0/token1 order differs from v4
    }

    /// @notice Last committed reference for a pool. `seeded` distinguishes "never read"
    ///         from "read, and the tick happened to be 0".
    struct Anchor {
        int24  tick;
        uint48 blockNum;
        bool   seeded;
    }

    mapping(PoolId => Config) public configs;

    /// @notice Per-block movement bound in ticks. 0 = raw, no truncation. Default.
    mapping(PoolId => uint16) public maxTicksPerBlock;

    /// @notice Anchor the bound is measured from. Advanced by updateRefTick only.
    mapping(PoolId => Anchor) public anchors;

    address public owner;

    /// @notice Proposed next owner. Set by proposeOwner, cleared by acceptOwner.
    address public pendingOwner;

    event OwnerProposed(address indexed currentOwner, address indexed proposedOwner);
    event OwnerTransferred(address indexed previousOwner, address indexed newOwner);
    event ConfigSet(PoolId indexed id, Config cfg);
    event TruncationBoundSet(PoolId indexed id, uint16 ticksPerBlock);
    event AnchorMoved(PoolId indexed id, int24 rawTick, int24 seenTick, bool clamped);

    // Replace require(cond, "string") reverts below with named errors — same checks,
    // same call sites, no behavior change.
    error OwnerIsZero();
    error NotOwner();
    error AlreadyOwner();
    error NotPendingOwner();
    error ZeroAddress();
    error TwapWindowTooShort();
    error FreezeBelowGuard();

    /// @dev `owner` was immutable. That is stricter than it looks: it means a lost or
    ///      compromised deployer key can never be rotated, and this owner sets the
    ///      pool addresses the reference is read from. Mutable with a two-step
    ///      handover is the weaker-looking option that actually fails safe.
    constructor(address _owner) {
        if (_owner == address(0)) revert OwnerIsZero();
        owner = _owner;
        emit OwnerTransferred(address(0), _owner);
    }

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    /// @notice Nominate the next owner. Nothing changes until they accept.
    function proposeOwner(address newOwner) external onlyOwner {
        if (newOwner == owner) revert AlreadyOwner();
        pendingOwner = newOwner;
        emit OwnerProposed(owner, newOwner);
    }

    /// @notice Accept a pending nomination. Only the nominee can call it.
    function acceptOwner() external {
        if (msg.sender != pendingOwner) revert NotPendingOwner();
        address previous = owner;
        owner = pendingOwner;
        pendingOwner = address(0);
        emit OwnerTransferred(previous, owner);
    }

    // -------------------------------------------------------------------------
    // Admin
    // -------------------------------------------------------------------------

    function setConfig(PoolId id, Config calldata cfg) external onlyOwner {
        if (cfg.fastPool == address(0) || cfg.deepPool == address(0)) revert ZeroAddress();
        if (cfg.twapWindow < 60) revert TwapWindowTooShort();
        // A backstop at or below the 1.00x tolerance would freeze before the curve ever
        // engages, restoring the cheap off-switch the curve exists to remove.
        if (!(cfg.freezeMaxDevTicks == 0 || cfg.freezeMaxDevTicks > cfg.guardMaxDevTicks)) {
            revert FreezeBelowGuard();
        }
        configs[id] = cfg;
        emit ConfigSet(id, cfg);
    }

    /// @notice Set the per-block movement bound. 0 disables truncation.
    /// @dev    B is the p99 of honest per-block reference movement for the flow regime,
    ///         derived off-chain: 10-16 ticks across the three measured windows, none of
    ///         which is a calm market. There is deliberately no adaptive on-chain bound.
    ///         A bound that widens with observed volatility is a bound an attacker widens
    ///         by manufacturing volatility, which would reintroduce the class of attack
    ///         truncation exists to close.
    function setMaxTicksPerBlock(PoolId id, uint16 b) external onlyOwner {
        maxTicksPerBlock[id] = b;
        emit TruncationBoundSet(id, b);
    }

    // -------------------------------------------------------------------------
    // IReferencePrice
    // -------------------------------------------------------------------------

    /// @notice Read the reference without committing the truncation anchor. Returns
    ///         exactly what updateRefTick would return at this block, minus the write.
    function getRefTick(PoolId id)
        external
        view
        override
        returns (int24 refTick, bool ok, uint24 divTicks)
    {
        int24 raw;
        (raw, ok, divTicks) = _rawRead(id);
        if (!ok) return (0, false, divTicks);
        (refTick, ) = _truncate(id, raw);
    }

    /// @notice Read the reference and advance the truncation anchor. Called once per swap
    ///         from beforeSwap; afterSwap reuses the value from the transient swap cache,
    ///         so the anchor moves at most once per swap.
    /// @dev    A frozen read commits NOTHING. The anchor stays where the last trusted read
    ///         left it, and the blocks that elapse while frozen still count toward the
    ///         allowance on the next trusted read — so a freeze cannot manufacture a lag
    ///         that compounds with the bound.
    function updateRefTick(PoolId id)
        external
        override
        returns (int24 refTick, bool ok, uint24 divTicks)
    {
        int24 raw;
        (raw, ok, divTicks) = _rawRead(id);
        if (!ok) return (0, false, divTicks);

        bool clamped;
        (refTick, clamped) = _truncate(id, raw);

        anchors[id] = Anchor({tick: refTick, blockNum: uint48(block.number), seeded: true});
        emit AnchorMoved(id, raw, refTick, clamped);
    }

    /// @dev Clamp `raw` to within maxTicksPerBlock * blocksElapsed of the anchor.
    ///      Never overshoots: a raw value inside the allowance is returned unchanged, so
    ///      the truncated reference approaches raw from one side and stops there.
    function _truncate(PoolId id, int24 raw) internal view returns (int24 seen, bool clamped) {
        uint16 b = maxTicksPerBlock[id];
        Anchor storage a = anchors[id];

        // Raw mode, or the first ever read: no anchor to bound against.
        if (b == 0 || !a.seeded) return (raw, false);

        uint256 elapsed = block.number - uint256(a.blockNum);

        // Same block as the last commit: zero allowance. This is the line that makes a
        // same-block push-and-revert on the fast pool invisible to the hook.
        if (elapsed == 0) return (a.tick, a.tick != raw);

        // int24 spans +/-8.4M ticks. Cap the allowance so the multiply cannot overflow
        // int256 on a pool that has not been read in a very long time; past the full tick
        // range the bound is not binding on any real price anyway.
        uint256 allowance = elapsed * uint256(b);
        if (allowance > uint256(int256(type(int24).max))) return (raw, false);

        int256 lo = int256(a.tick) - int256(allowance);
        int256 hi = int256(a.tick) + int256(allowance);
        int256 r = int256(raw);

        if (r < lo) return (int24(lo), true);
        if (r > hi) return (int24(hi), true);
        return (raw, false);
    }

    /// @dev The untruncated read: two spot ticks, the deep TWAP, divergence, and the
    ///      freeze conditions. divTicks is computed HERE, on raw values, and is never
    ///      derived from the truncated reference.
    function _rawRead(PoolId id)
        internal
        view
        returns (int24 refTick, bool ok, uint24 divTicks)
    {
        Config storage c = configs[id];
        if (c.fastPool == address(0)) return (0, false, 0);

        int24 fast = _spotTick(c.fastPool);
        int24 deep = _spotTick(c.deepPool);

        // R1: observe() REVERTS when the pool's observation cardinality does not cover
        // the window. Left unguarded that propagates through getRefTick -> beforeSwap ->
        // the swap itself, bricking every trade in the pool. Appendix §7 specifies the
        // failure mode as "Freeze — no credit, no surcharge. An unreliable reference
        // should produce inaction, not a wrong charge." A reverted swap is not inaction.
        // Any failure to read the guard therefore freezes rather than reverts.
        (int24 deepTwap, bool twapOk) = _twapTick(c.deepPool, c.twapWindow);
        if (!twapOk) return (0, false, 0);

        // Signal 1: deep source diverging from its own TWAP — the deep pool is moving
        // faster than its own history, i.e. it is being pushed.
        uint24 dDeep = _abs(deep - deepTwap);
        // Signal 2: fast source diverging from the deep price the two agree on.
        uint24 dFast = _abs(fast - deep);
        // The worst of the two: either source misbehaving makes the reference suspect,
        // and taking the max means an attacker cannot hide by splitting the push.
        divTicks = dDeep > dFast ? dDeep : dFast;

        // Neither subtraction can overflow int24: v3 ticks are bounded by ±887272, so
        // the widest possible difference is 1_774_544, inside int24 and inside uint24.

        if (c.freezeMaxDevTicks != 0 && divTicks > c.freezeMaxDevTicks) {
            return (0, false, divTicks);
        }

        refTick = c.invertTicks ? -fast : fast;
        ok = true;
    }

    /// @notice Whether the configured pools can currently serve the guard window.
    /// @dev    Deployment prerequisite check. If this returns false, the deep pool needs
    ///         increaseObservationCardinalityNext() before the hook can do anything but
    ///         freeze. Call it after configuring a pool and before announcing it live.
    function isReady(PoolId id) external view returns (bool) {
        Config storage c = configs[id];
        if (c.fastPool == address(0)) return false;
        (, bool twapOk) = _twapTick(c.deepPool, c.twapWindow);
        return twapOk;
    }

    // -------------------------------------------------------------------------
    // Internals
    // -------------------------------------------------------------------------

    function _spotTick(address pool) internal view returns (int24 t) {
        (, t,,,,,) = IUniswapV3PoolMinimal(pool).slot0();
    }

    /// @dev Returns (tick, ok). ok=false when the pool cannot serve the window —
    ///      insufficient observation cardinality being the expected cause.
    function _twapTick(address pool, uint32 window) internal view returns (int24, bool) {
        uint32[] memory ago = new uint32[](2);
        ago[0] = window;
        ago[1] = 0;

        try IUniswapV3PoolMinimal(pool).observe(ago) returns (
            int56[] memory cum, uint160[] memory
        ) {
            int56 delta = cum[1] - cum[0];
            int56 w = int56(uint56(window));
            int24 t = int24(delta / w);

            // R2: Solidity truncates toward zero, so a negative delta that does not
            // divide evenly rounds UP (toward zero) and reports a tick one higher than
            // the true time-weighted average. Uniswap's own OracleLibrary.consult
            // applies this same correction. One tick is one basis point — small against
            // guardMaxDevTicks = 50, but it is a known-correct pattern and the guard
            // should not carry a systematic bias in one direction.
            if (delta < 0 && (delta % w != 0)) t--;

            return (t, true);
        } catch {
            return (0, false);
        }
    }

    function _abs(int24 x) internal pure returns (uint24) {
        return x < 0 ? uint24(-x) : uint24(x);
    }
}
