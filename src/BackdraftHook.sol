// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IHooks}                from "v4-core/interfaces/IHooks.sol";
import {IPoolManager}          from "v4-core/interfaces/IPoolManager.sol";
import {IUnlockCallback}       from "v4-core/interfaces/callback/IUnlockCallback.sol";
import {PoolKey}         from "v4-core/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {BalanceDelta}    from "v4-core/types/BalanceDelta.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary, toBeforeSwapDelta} from "v4-core/types/BeforeSwapDelta.sol";
import {Currency, CurrencyLibrary} from "v4-core/types/Currency.sol";
import {Hooks}           from "v4-core/libraries/Hooks.sol";
import {StateLibrary}    from "v4-core/libraries/StateLibrary.sol";
import {SafeCast}        from "@openzeppelin/contracts/utils/math/SafeCast.sol";

import {IReferencePrice}   from "./interfaces/IReferencePrice.sol";
import {GapMath}           from "./libraries/GapMath.sol";
import {SurchargeMath}     from "./libraries/SurchargeMath.sol";
import {EligibilityLib}    from "./libraries/EligibilityLib.sol";

/// @title BackdraftHook
/// @notice Prices the mispricing a swap leaves behind and returns the captured value
///         to the traders who created it and the LPs who funded it.
///
/// Mechanism (see idea.md for full design):
///   - Contribution ledger: tracks which addresses widened the gap and by how much
///   - Surcharge: closing swaps pay proportional to gap size and notional
///   - Settlement: escrowed value split between traders (α) and LPs (1-α),
///     scaled by the fraction of the gap the ledger explains (poisoning defence)
///   - LP eligibility: age filter closes JIT attack; top-up resets the clock
contract BackdraftHook is IHooks, IUnlockCallback {
    using PoolIdLibrary  for PoolKey;
    using StateLibrary   for IPoolManager;
    using CurrencyLibrary for Currency;
    using GapMath        for int24;
    using SafeCast       for uint256;

    // =========================================================================
    // State structs
    // =========================================================================

    struct PoolCfg {
        address fastPool;           // v3 0.01% — reference price
        address deepPool;           // v3 0.05% — manipulation guard
        uint32  twapWindow;         // 1800 seconds
        uint24  guardMaxDevTicks;   // 50
        uint24  gapThresholdTicks;  // 65 — from measured p100 of 57.97 bps
        uint16  captureRateBps;     // sweep parameter
        uint16  surchargeCapBps;    // hard ceiling
        uint16  traderShareBps;     // alpha
        uint32  minAgeBlocks;
        uint32  expiryBlocks;
        bool    invertTicks;        // true if v3 and v4 ordering differ
    }

    struct Gap {
        uint48  openBlock;
        uint48  expiryBlock;
        int24   refTickAtOpen;
        int24   tickAtOpen;         // pool tick at gap open (for LP range checks)
        uint128 eligibleLiqAtOpen;
        uint128 escrowed;
        uint128 totalContribution;  // sum of tick-widening across all contributors
        uint24  maxAbsGap;          // largest |gap| reached — denominator of poisoning defence
        bool    gapPositive;        // sign at open; sign flip CLOSES the gap
        bool    isCurrency0;        // set on first surcharge, then asserted
        bool    settled;
    }

    struct PositionInfo {
        uint128 liquidity;
        uint48  addBlock;           // reset on ANY increase — closes the top-up attack
        int24   tickLower;
        int24   tickUpper;
    }

    // =========================================================================
    // Storage
    // =========================================================================

    IPoolManager public immutable poolManager;
    IReferencePrice public referenceOracle;

    mapping(PoolId => PoolCfg)                       public cfg;
    mapping(PoolId => Gap[])                         internal _gaps;
    mapping(PoolId => uint256)                       public openGapIdx;   // 0 = none open
    mapping(bytes32 => uint128)                      public contribution; // keccak(poolId,gapIdx,addr)
    mapping(bytes32 => PositionInfo)                 public positions;
    mapping(address => mapping(Currency => uint256)) public traderClaimable;
    mapping(bytes32 => mapping(uint256 => bool))     public lpClaimed;

    // Transient slot: cached |gap| from beforeSwap for afterSwap to read (same tx)
    // Using regular storage here because tstore is tx-scoped and we're on a single call path
    /// @dev Per-swap scratch written by beforeSwap and read by afterSwap.
    ///      Packs into one slot (uint24 + 2 bools). `wasNarrowing` is the swap's
    ///      direction relative to the gap AT ENTRY — the only honest basis for
    ///      attribution, because where a swap LANDS is gameable (an arbitrageur
    ///      that overshoots ends up further from the reference than it started).
    ///      `valid` is written on every beforeSwap path, including the frozen-oracle
    ///      path, so afterSwap can never attribute using a cache from an earlier swap.
    struct SwapCache {
        uint24 absGapBefore;
        bool   wasNarrowing;
        bool   valid;
    }

    mapping(PoolId => SwapCache) private _swapCache;

    // Simple cumulative liquidity-added checkpoint for eligibility denominator
    // Keyed by poolId; stores (blockNumber => cumulative added)
    // Full OZ Checkpoints would be ideal — this is a simplified version
    mapping(PoolId => uint256[]) private _addedCheckpointBlocks;
    mapping(PoolId => uint128[]) private _addedCheckpointValues;
    mapping(PoolId => uint128)   private _totalAdded;
    mapping(PoolId => Currency)  private _currency0;
    mapping(PoolId => Currency)  private _currency1;

    // =========================================================================
    // Events
    // =========================================================================

    event GapOpened(PoolId indexed id, uint256 gapIdx, int24 refTick, uint48 openBlock);
    event Contributed(PoolId indexed id, uint256 gapIdx, address indexed trader, uint128 ticks);
    event GapClosed(PoolId indexed id, uint256 gapIdx, uint128 escrowed);
    event Surcharged(PoolId indexed id, uint256 gapIdx, address indexed swapper, uint128 amount);
    event Settled(PoolId indexed id, uint256 gapIdx, uint256 traderPot, uint256 lpPot);
    event TraderClaimed(PoolId indexed id, uint256 gapIdx, address indexed trader, uint256 amount);
    event LpClaimed(PoolId indexed id, uint256 gapIdx, bytes32 positionKey, uint256 amount);

    // =========================================================================
    // Constructor
    // =========================================================================

    constructor(IPoolManager _poolManager, IReferencePrice _referenceOracle, address _owner) {
        poolManager = _poolManager;
        referenceOracle = _referenceOracle;
        owner = _owner;
    }

    // =========================================================================
    // Hook permissions
    // =========================================================================

    function getHookPermissions() public pure returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize:          false,
            afterInitialize:           true,   // validate v3 sources, cache tick ordering
            beforeAddLiquidity:        true,   // record addBlock, reset on increase
            afterAddLiquidity:         false,
            beforeRemoveLiquidity:     true,   // update tracking on remove
            afterRemoveLiquidity:      false,
            beforeSwap:                true,   // classify + surcharge
            afterSwap:                 true,   // update ledger, open/close gaps
            beforeDonate:              false,
            afterDonate:               false,
            beforeSwapReturnDelta:     true,   // load-bearing: take surcharge from swapper
            afterSwapReturnDelta:      false,
            afterAddLiquidityReturnDelta:    false,
            afterRemoveLiquidityReturnDelta: false
        });
    }

    // =========================================================================
    // Admin
    // =========================================================================

    address public owner;

    modifier onlyOwner() {
        require(msg.sender == owner, "not owner");
        _;
    }

    function setPoolCfg(PoolId id, PoolCfg calldata c) external onlyOwner {
        cfg[id] = c;
    }

    function setReferenceOracle(IReferencePrice oracle) external onlyOwner {
        referenceOracle = oracle;
    }

    // =========================================================================
    // IHooks — afterInitialize
    // =========================================================================

    function afterInitialize(address, PoolKey calldata key, uint160, int24)
        external
        override
        returns (bytes4)
    {
        require(msg.sender == address(poolManager), "not PM");
        PoolId id = key.toId();
        // Store currencies for payout — needed by _payout since we only have PoolId there
        _currency0[id] = key.currency0;
        _currency1[id] = key.currency1;
        // Push sentinel at index 0 so openGapIdx==0 unambiguously means "no open gap".
        // Real gaps start at index 1.
        _gaps[id].push(Gap({
            openBlock: 0, expiryBlock: 0, refTickAtOpen: 0, tickAtOpen: 0,
            eligibleLiqAtOpen: 0, escrowed: 0, totalContribution: 0,
            maxAbsGap: 0, gapPositive: false, isCurrency0: false, settled: true
        }));
        return IHooks.afterInitialize.selector;
    }

    // =========================================================================
    // IHooks — beforeAddLiquidity / beforeRemoveLiquidity
    // =========================================================================

    function beforeAddLiquidity(
        address sender,
        PoolKey calldata key,
        IPoolManager.ModifyLiquidityParams calldata params,
        bytes calldata
    ) external override returns (bytes4) {
        require(msg.sender == address(poolManager), "not PM");
        PoolId id = key.toId();
        // Use tx.origin as position owner — sender is the router (periphery), not the LP.
        bytes32 pk = _positionKey(id, tx.origin, params.tickLower, params.tickUpper, params.salt);
        PositionInfo storage p = positions[pk];

        // ANY increase resets the age clock — closes the top-up attack
        p.addBlock  = uint48(block.number);
        if (params.liquidityDelta > 0) {
            p.liquidity += uint128(uint256(int256(params.liquidityDelta)));
        }
        p.tickLower = params.tickLower;
        p.tickUpper = params.tickUpper;

        // Track cumulative liquidity added for eligibility denominator
        if (params.liquidityDelta > 0) {
            _pushCheckpoint(id, uint128(uint256(int256(params.liquidityDelta))));
        }

        return IHooks.beforeAddLiquidity.selector;
    }

    function beforeRemoveLiquidity(
        address sender,
        PoolKey calldata key,
        IPoolManager.ModifyLiquidityParams calldata params,
        bytes calldata
    ) external override returns (bytes4) {
        require(msg.sender == address(poolManager), "not PM");
        PoolId id = key.toId();
        bytes32 pk = _positionKey(id, tx.origin, params.tickLower, params.tickUpper, params.salt);
        PositionInfo storage p = positions[pk];
        if (params.liquidityDelta < 0) {
            uint128 removed = uint128(uint256(-int256(params.liquidityDelta)));
            if (p.liquidity >= removed) p.liquidity -= removed;
        }
        return IHooks.beforeRemoveLiquidity.selector;
    }

    // =========================================================================
    // IHooks — beforeSwap
    // =========================================================================

    function beforeSwap(
        address,
        PoolKey calldata key,
        IPoolManager.SwapParams calldata params,
        bytes calldata
    ) external override returns (bytes4, BeforeSwapDelta, uint24) {
        require(msg.sender == address(poolManager), "not PM");
        PoolId id = key.toId();
        PoolCfg storage c = cfg[id];

        (int24 refTick, bool ok) = referenceOracle.getRefTick(id);
        if (!ok) {
            // Invalidate the cache: afterSwap must not attribute this swap using
            // direction data from a previous one.
            _swapCache[id] = SwapCache({absGapBefore: 0, wasNarrowing: false, valid: false});
            return (IHooks.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
        }

        (, int24 tick,,) = StateLibrary.getSlot0(poolManager, id);
        int24 gapBefore = tick - refTick;

        // Direction is decided here, on the PRE-swap gap, and cached for afterSwap.
        // Computed before every early return below: a swap that is not surcharged
        // (exact-output, no open gap) can still be a legitimate widener.
        bool narrowing = GapMath.isNarrowing(gapBefore, params.zeroForOne);
        _swapCache[id] = SwapCache({
            absGapBefore: GapMath.abs(gapBefore),
            wasNarrowing: narrowing,
            valid:        true
        });

        uint256 idx = openGapIdx[id];

        if (idx == 0) {
            // A gap that already exceeds the threshold BEFORE this swap was not
            // created by it — the external market moved while this pool sat stale.
            // Open it here, pre-swap, so the very first arbitrage against the stale
            // price is surcharged. Previously this branch returned early and gap
            // detection happened only in afterSwap, by which time a single-swap close
            // had already corrected the pool: the gap opened AFTER the arbitrage and
            // captured nothing. Measured before this change: zero escrow on the pure
            // exogenous path, i.e. the exogenous claim did not hold.
            //
            // The classification is structural, not heuristic:
            //   gap present at entry            -> pre-existing  -> open here
            //   gap absent at entry, present at exit -> this swap caused it -> afterSwap
            // The gap opens with an empty ledger, so if nothing widens it before it
            // closes, settlement routes 100% to LPs by the existing rule.
            if (GapMath.abs(gapBefore) > c.gapThresholdTicks) {
                _openGap(id, refTick, tick, gapBefore);
                idx = openGapIdx[id];
            } else {
                return (IHooks.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
            }
        }

        // Only exact-input swaps are surcharged (amountSpecified < 0)
        if (params.amountSpecified >= 0) return (IHooks.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);

        bool narrowingSwap = narrowing;
        if (!narrowingSwap) return (IHooks.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);

        // Price on maxAbsGap — the widest the gap has been during its life — not on
        // the gap prevailing at this instant.
        //
        // Pricing on the prevailing gap is split-gameable. Each leg of a split close
        // sees a smaller gap than the last, so the rate decays across the sequence and
        // the total collected approaches the integral of a linear function from 0 to G
        // instead of its value at G. Measured on the unpatched branch: one swap paid
        // 3840, the same notional in eight legs paid 1380 — a 64% discount for a
        // two-line change to a searcher's bundle.
        //
        // maxAbsGap is constant for a gap's life (afterSwap only raises it, and only
        // for wideners after the task-2 fix), so N legs at rate f(maxAbsGap) sum to
        // exactly what one leg of the same total notional pays.
        //
        // Trade-off, stated rather than hidden: a swap arriving when the gap is nearly
        // closed still pays the peak rate. That is the partial-close overcharge already
        // documented in idea.md §6, slightly enlarged and still bounded by surchargeCapBps.
        Gap storage gp = _gaps[id][idx];
        uint128 surcharge = SurchargeMath.compute(
            uint256(-params.amountSpecified),
            gp.maxAbsGap,
            c.captureRateBps,
            c.surchargeCapBps
        );
        if (surcharge == 0) return (IHooks.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);

        Currency spec = params.zeroForOne ? key.currency0 : key.currency1;
        poolManager.mint(address(this), spec.toId(), surcharge);

        if (gp.escrowed == 0) {
            gp.isCurrency0 = params.zeroForOne;
        } else {
            assert(gp.isCurrency0 == params.zeroForOne);
        }
        gp.escrowed += surcharge;

        emit Surcharged(id, idx, tx.origin, surcharge);

        // Positive deltaSpecified => hook is owed => taken from the swapper
        return (IHooks.beforeSwap.selector, toBeforeSwapDelta(int128(surcharge), 0), 0);
    }

    // =========================================================================
    // IHooks — afterSwap
    // =========================================================================

    function afterSwap(
        address,
        PoolKey calldata key,
        IPoolManager.SwapParams calldata,
        BalanceDelta,
        bytes calldata
    ) external override returns (bytes4, int128) {
        require(msg.sender == address(poolManager), "not PM");
        PoolId id = key.toId();
        PoolCfg storage c = cfg[id];

        (int24 refTick, bool ok) = referenceOracle.getRefTick(id);
        if (!ok) return (IHooks.afterSwap.selector, 0);

        (, int24 tick,,) = StateLibrary.getSlot0(poolManager, id);
        int24 gapNow  = tick - refTick;
        uint24 absNow = GapMath.abs(gapNow);

        uint256 idx = openGapIdx[id];
        SwapCache memory sc = _swapCache[id];

        // A swap earns ledger credit only if it ENTERED moving away from the
        // reference. Direction at entry, never final position: an arbitrageur that
        // overshoots ends up further from the reference than it started, and under
        // the old `absNow > absBefore` test that made the corrector the pool's
        // largest "contributor" — the exact rebate-to-the-arbitrageur failure that
        // killed the own-pool-EMA design (appendix §5).
        bool creditable = sc.valid && !sc.wasNarrowing;

        if (idx == 0) {
            // Reaching here means the gap was BELOW threshold at entry (beforeSwap
            // would otherwise have opened it) and is above it now — so this swap
            // created the dislocation. It is the originator and must be credited.
            if (absNow > c.gapThresholdTicks) {
                _openGap(id, refTick, tick, gapNow);
                _credit(id, openGapIdx[id], sc.absGapBefore, absNow, creditable);
            }
            return (IHooks.afterSwap.selector, 0);
        }

        Gap storage g = _gaps[id][idx];

        _credit(id, idx, sc.absGapBefore, absNow, creditable);

        // maxAbsGap is the denominator of the poisoning defence (§3.3) and must
        // track only how wide WIDENERS pushed the gap. A narrowing swap can only
        // exceed it by overshooting, and counting that overshoot would inflate the
        // denominator, shrink `explained`, and silently move value from the trader
        // pot to LPs on every overshot close.
        if (creditable && absNow > g.maxAbsGap) g.maxAbsGap = absNow;

        // Close on: narrowed under threshold, OR overshoot (sign flip)
        // Sign flip must close — otherwise escrow currency direction is ambiguous (§3.2)
        bool flipped = gapNow != 0 && (gapNow > 0) != g.gapPositive;
        if (absNow <= c.gapThresholdTicks || flipped) {
            _closeGap(id, idx);
        }

        return (IHooks.afterSwap.selector, 0);
    }

    // =========================================================================
    // IHooks — stubs for disabled callbacks
    // =========================================================================

    function beforeInitialize(address, PoolKey calldata, uint160) external pure override returns (bytes4) {
        revert("disabled");
    }

    function afterAddLiquidity(address, PoolKey calldata, IPoolManager.ModifyLiquidityParams calldata, BalanceDelta, BalanceDelta, bytes calldata)
        external pure override returns (bytes4, BalanceDelta) { revert("disabled"); }

    function afterRemoveLiquidity(address, PoolKey calldata, IPoolManager.ModifyLiquidityParams calldata, BalanceDelta, BalanceDelta, bytes calldata)
        external pure override returns (bytes4, BalanceDelta) { revert("disabled"); }

    function beforeDonate(address, PoolKey calldata, uint256, uint256, bytes calldata)
        external pure override returns (bytes4) { revert("disabled"); }

    function afterDonate(address, PoolKey calldata, uint256, uint256, bytes calldata)
        external pure override returns (bytes4) { revert("disabled"); }

    // =========================================================================
    // Settlement
    // =========================================================================

    function settle(PoolId id, uint256 gapIdx) public {
        Gap storage g = _gaps[id][gapIdx];
        require(!g.settled, "already settled");
        require(
            block.number > g.expiryBlock || !_isGapOpen(id, gapIdx),
            "still open"
        );
        g.settled = true;
        // If this gap expired while still marked open, clear the pointer so
        // openGapIdx never points to a settled gap.
        if (openGapIdx[id] == gapIdx) openGapIdx[id] = 0;

        uint256 tp = _traderPot(id, g);
        uint256 lp = g.escrowed - tp;
        emit Settled(id, gapIdx, tp, lp);
    }

    /// @notice v4 settlement: trader pot scaled by the fraction of the gap the ledger explains.
    ///         Kills the dust-poisoning attack — 2 manufactured ticks on a 200-tick exogenous
    ///         gap earns 1% of alpha, below the dust swap's own loss plus claim gas.
    function _traderPot(PoolId id, Gap storage g) internal view returns (uint256) {
        if (g.totalContribution == 0 || g.maxAbsGap == 0) return 0;
        // Cap at 1 for oscillating gaps where totalContribution can exceed maxAbsGap
        uint256 explained = uint256(g.totalContribution) > uint256(g.maxAbsGap)
            ? uint256(g.maxAbsGap)
            : uint256(g.totalContribution);
        return (uint256(g.escrowed) * uint256(cfg[id].traderShareBps) * explained)
             / (uint256(g.maxAbsGap) * 10_000);
    }

    function claimTrader(PoolId id, uint256 gapIdx) external {
        Gap storage g = _gaps[id][gapIdx];
        require(g.settled && g.totalContribution > 0, "n/a");
        bytes32 k = _contributionKey(id, gapIdx, msg.sender);
        uint128 c = contribution[k];
        require(c > 0, "nothing");
        contribution[k] = 0;

        uint256 owed = (_traderPot(id, g) * c) / g.totalContribution;
        _payout(id, g, msg.sender, owed);
        emit TraderClaimed(id, gapIdx, msg.sender, owed);
    }

    /// @notice Claim an LP's share of a settled gap's escrow.
    /// @dev    The position key is DERIVED from msg.sender — never accepted as an
    ///         argument. Taking it as a parameter let any address pass another LP's
    ///         key and be paid, because every input to _positionKey (poolId, owner,
    ///         ticks, salt) is public or enumerable from events.
    ///         Known limitation: positions are recorded against tx.origin in
    ///         beforeAddLiquidity (the router is `sender`), so an LP must claim from
    ///         the same EOA that added the liquidity. Smart-contract wallets and
    ///         ERC-4337 accounts cannot claim. Documented in the README alongside the
    ///         existing tx.origin attribution limitation.
    function claimLp(PoolId id, uint256 gapIdx, int24 tickLower, int24 tickUpper, bytes32 salt)
        external
    {
        bytes32 positionKey = _positionKey(id, msg.sender, tickLower, tickUpper, salt);

        Gap storage g = _gaps[id][gapIdx];
        require(g.settled, "not settled");
        require(!lpClaimed[positionKey][gapIdx], "claimed");

        PositionInfo memory p = positions[positionKey];
        require(p.liquidity > 0, "no position");
        require(EligibilityLib.isEligible(p.addBlock, g.openBlock, cfg[id].minAgeBlocks), "too new");
        require(EligibilityLib.isInRange(p.tickLower, p.tickUpper, g.tickAtOpen), "out of range");

        uint256 lpPot = uint256(g.escrowed) - _traderPot(id, g);
        require(g.eligibleLiqAtOpen > 0, "no eligible liq");
        uint256 owed = (lpPot * uint256(p.liquidity)) / uint256(g.eligibleLiqAtOpen);

        lpClaimed[positionKey][gapIdx] = true;
        _payout(id, g, msg.sender, owed);
        emit LpClaimed(id, gapIdx, positionKey, owed);
    }

    // =========================================================================
    // Internals
    // =========================================================================

    /// @notice Credit a widening swap to the gap's contribution ledger.
    /// @param  absBefore |gap| at swap entry
    /// @param  absNow    |gap| at swap exit
    /// @param  creditable false for correctors (entered narrowing) and for swaps
    ///         whose direction could not be established
    /// @dev    Credits only the INCREMENT this swap added. On a gap that was already
    ///         partly open from an external move, the pre-existing portion stays
    ///         unexplained, so `explained = totalContribution / maxAbsGap` falls
    ///         below 1 and settlement routes that share to LPs. Mixed
    ///         exogenous/endogenous gaps therefore split correctly with no extra
    ///         branch — the same property that makes an empty ledger mean "wholly
    ///         exogenous".
    function _credit(PoolId id, uint256 idx, uint24 absBefore, uint24 absNow, bool creditable)
        internal
    {
        if (!creditable || absNow <= absBefore) return;
        uint128 d = uint128(absNow - absBefore);
        contribution[_contributionKey(id, idx, tx.origin)] += d;
        _gaps[id][idx].totalContribution += d;
        emit Contributed(id, idx, tx.origin, d);
    }

    function _openGap(PoolId id, int24 refTick, int24 tickNow, int24 gapNow) internal {
        PoolCfg storage c = cfg[id];
        uint48 openBlock = uint48(block.number);

        // Eligible liquidity denominator: in-range liquidity minus recently-added
        uint128 inRange    = StateLibrary.getLiquidity(poolManager, id);
        uint128 addedNow   = _totalAdded[id];
        uint48  lookback   = openBlock > c.minAgeBlocks ? openBlock - c.minAgeBlocks : 0;
        uint128 addedThen  = _cumulativeAddedAt(id, lookback);
        uint128 eligibleLiq = inRange > (addedNow - addedThen)
            ? inRange - (addedNow - addedThen)
            : 0;

        _gaps[id].push(Gap({
            openBlock:        openBlock,
            expiryBlock:      openBlock + c.expiryBlocks,
            refTickAtOpen:    refTick,
            tickAtOpen:       tickNow,
            eligibleLiqAtOpen: eligibleLiq,
            escrowed:         0,
            totalContribution: 0,
            maxAbsGap:        GapMath.abs(gapNow),
            gapPositive:      gapNow > 0,
            isCurrency0:      false,
            settled:          false
        }));

        uint256 newIdx = _gaps[id].length - 1;
        openGapIdx[id] = newIdx;
        emit GapOpened(id, newIdx, refTick, openBlock);
    }

    function _closeGap(PoolId id, uint256 idx) internal {
        openGapIdx[id] = 0;
        emit GapClosed(id, idx, _gaps[id][idx].escrowed);
    }

    function _isGapOpen(PoolId id, uint256 idx) internal view returns (bool) {
        return openGapIdx[id] == idx;
    }

    // Encoded payload for unlockCallback — used by claimTrader/claimLp
    struct PayoutData {
        Currency currency;
        address  to;
        uint256  amount;
    }

    /// @notice IUnlockCallback — called back by PoolManager during claim payouts.
    ///         burn() and take() require the PM to be in an unlocked context.
    ///         Claim functions are called outside swaps, so we must self-unlock.
    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        require(msg.sender == address(poolManager), "not PM");
        PayoutData memory p = abi.decode(data, (PayoutData));
        poolManager.burn(address(this), p.currency.toId(), p.amount);
        poolManager.take(p.currency, p.to, p.amount);
        return "";
    }

    function _payout(PoolId id, Gap storage g, address to, uint256 amount) internal {
        if (amount == 0) return;
        Currency cur = g.isCurrency0 ? _currency0[id] : _currency1[id];
        // burn+take require an unlock context; claim functions are called outside swaps.
        poolManager.unlock(abi.encode(PayoutData({currency: cur, to: to, amount: amount})));
    }

    function _contributionKey(PoolId id, uint256 gapIdx, address addr) internal pure returns (bytes32) {
        return keccak256(abi.encode(id, gapIdx, addr));
    }

    function _positionKey(PoolId id, address owner_, int24 tickLower, int24 tickUpper, bytes32 salt)
        internal pure returns (bytes32)
    {
        return keccak256(abi.encode(id, owner_, tickLower, tickUpper, salt));
    }

    // =========================================================================
    // Checkpoint helpers (simplified — OZ Checkpoints in production)
    // =========================================================================

    function _pushCheckpoint(PoolId id, uint128 delta) internal {
        _totalAdded[id] += delta;
        _addedCheckpointBlocks[id].push(block.number);
        _addedCheckpointValues[id].push(_totalAdded[id]);
    }

    function _cumulativeAddedAt(PoolId id, uint48 blockNum) internal view returns (uint128) {
        uint256[] storage blocks = _addedCheckpointBlocks[id];
        uint128[] storage values = _addedCheckpointValues[id];
        uint256 len = blocks.length;
        if (len == 0) return 0;
        // Binary search for last entry <= blockNum
        uint256 lo = 0; uint256 hi = len;
        while (lo < hi) {
            uint256 mid = (lo + hi) / 2;
            if (blocks[mid] <= blockNum) lo = mid + 1;
            else hi = mid;
        }
        return lo == 0 ? 0 : values[lo - 1];
    }

    // =========================================================================
    // View helpers
    // =========================================================================

    /// @notice Compute the storage key for a position. Read-only convenience for
    ///         off-chain callers and tests; claimLp derives its own key from
    ///         msg.sender and never trusts a caller-supplied one.
    function positionKeyFor(PoolId id, address lpOwner, int24 tickLower, int24 tickUpper, bytes32 salt)
        external pure returns (bytes32)
    {
        return _positionKey(id, lpOwner, tickLower, tickUpper, salt);
    }

    function gaps(PoolId id) external view returns (Gap[] memory) {
        return _gaps[id];
    }

    function gapAt(PoolId id, uint256 idx) external view returns (Gap memory) {
        return _gaps[id][idx];
    }
}
