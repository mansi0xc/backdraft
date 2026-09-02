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
/// See idea.md §4 for the measurement rationale, §4.4 for design, §10 for the attack.
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
                                  // Truncated-oracle reference smoothing is the real fix
                                  // and is documented, not implemented.
        bool    invertTicks;      // true when v3 token0/token1 order differs from v4
    }

    mapping(PoolId => Config) public configs;
    address public owner;

    /// @notice Proposed next owner. Set by proposeOwner, cleared by acceptOwner.
    address public pendingOwner;

    event OwnerProposed(address indexed currentOwner, address indexed proposedOwner);
    event OwnerTransferred(address indexed previousOwner, address indexed newOwner);
    event ConfigSet(PoolId indexed id, Config cfg);

    /// @dev `owner` was immutable. That is stricter than it looks: it means a lost or
    ///      compromised deployer key can never be rotated, and this owner sets the
    ///      pool addresses the reference is read from. Mutable with a two-step
    ///      handover is the weaker-looking option that actually fails safe.
    constructor(address _owner) {
        require(_owner != address(0), "owner is zero");
        owner = _owner;
        emit OwnerTransferred(address(0), _owner);
    }

    modifier onlyOwner() {
        require(msg.sender == owner, "not owner");
        _;
    }

    /// @notice Nominate the next owner. Nothing changes until they accept.
    function proposeOwner(address newOwner) external onlyOwner {
        require(newOwner != owner, "already owner");
        pendingOwner = newOwner;
        emit OwnerProposed(owner, newOwner);
    }

    /// @notice Accept a pending nomination. Only the nominee can call it.
    function acceptOwner() external {
        require(msg.sender == pendingOwner, "not pending owner");
        address previous = owner;
        owner = pendingOwner;
        pendingOwner = address(0);
        emit OwnerTransferred(previous, owner);
    }

    // -------------------------------------------------------------------------
    // Admin
    // -------------------------------------------------------------------------

    function setConfig(PoolId id, Config calldata cfg) external onlyOwner {
        require(cfg.fastPool != address(0) && cfg.deepPool != address(0), "zero addr");
        require(cfg.twapWindow >= 60, "twap too short");
        // A backstop at or below the 1.00x tolerance would freeze before the curve ever
        // engages, restoring the cheap off-switch the curve exists to remove.
        require(
            cfg.freezeMaxDevTicks == 0 || cfg.freezeMaxDevTicks > cfg.guardMaxDevTicks,
            "freeze <= guard"
        );
        configs[id] = cfg;
        emit ConfigSet(id, cfg);
    }

    // -------------------------------------------------------------------------
    // IReferencePrice
    // -------------------------------------------------------------------------

    function getRefTick(PoolId id)
        external
        view
        override
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
