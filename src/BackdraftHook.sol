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
import {Hooks}            from "v4-core/libraries/Hooks.sol";
import {Hooks}           from "v4-core/libraries/Hooks.sol";
import {StateLibrary}    from "v4-core/libraries/StateLibrary.sol";
import {FullMath}        from "v4-core/libraries/FullMath.sol";
import {LPFeeLibrary}    from "v4-core/libraries/LPFeeLibrary.sol";
import {FixedPoint96}    from "v4-core/libraries/FixedPoint96.sol";
import {SafeCast}        from "@openzeppelin/contracts/utils/math/SafeCast.sol";

import {IReferencePrice}   from "./interfaces/IReferencePrice.sol";
import {GapMath}           from "./libraries/GapMath.sol";
import {SurchargeMath}     from "./libraries/SurchargeMath.sol";
import {DivergenceMath}    from "./libraries/DivergenceMath.sol";
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
        uint24  guardMaxDevTicks;   // 50 — divergence tolerated at 1.00x surcharge
        uint16  divSlopeBps;        // multiplier bps added per tick of excess divergence
        uint16  maxDivMultBps;      // ceiling on the divergence multiplier (>= 10_000)
        uint24  gapThresholdTicks;  // 65 — from measured p100 of 57.97 bps
        uint16  captureRateBps;     // sweep parameter
        uint16  surchargeCapBps;    // hard ceiling
        uint16  traderShareBps;     // alpha
        uint24  baseFee;            // dynamic-fee pools initialise to 0; this is the
                                    // normal fee, applied in afterInitialize. Units are
                                    // v4 fee units (hundredths of a bip): 3000 = 0.30%.
        uint24  narrowingFee;       // fee charged to GAP-CLOSING swaps while a gap is
                                    // open. NO_FEE_OVERRIDE disables the flip entirely.
        uint32  minAgeBlocks;
        uint32  expiryBlocks;
        uint32  sweepGraceBlocks;   // delay after expiry before unclaimed funds return to LPs
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
        uint128 lpPaid;             // cumulative LP claims — caps the pot (see claimLp)
        uint128 traderPaid;         // cumulative trader claims — caps the pot
        uint24  maxAbsGap;          // largest |gap| reached — denominator of poisoning defence
        bool    gapPositive;        // sign at open; sign flip CLOSES the gap
        bool    isCurrency0;        // set on first surcharge, then asserted
        bool    settled;
        bool    swept;
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
    ///      R3: `refTick` is cached here so afterSwap does not re-read the oracle.
    ///      getRefTick performs two slot0 reads plus an observe() — three external calls
    ///      — and calling it from both beforeSwap and afterSwap made six per swap, about
    ///      148k gas at the measured 74k per read. The external v3 pools cannot move
    ///      during our own v4 swap, so the second read could only ever return the same
    ///      value. Caching also removes a real inconsistency: beforeSwap seeing ok=true
    ///      and afterSwap seeing ok=false within one transaction, which would surcharge
    ///      a swap and then decline to record the gap it belongs to.
    struct SwapCache {
        uint24 absGapBefore;
        int24  refTick;
        bool   wasNarrowing;
        bool   valid;
    }

    mapping(PoolId => SwapCache) private _swapCache;

    /// @notice Routers whose hookData is trusted to name the end user.
    /// @dev    In v4 the `sender` argument to a hook callback is the ROUTER, never the
    ///         end user, so a hook that needs user identity must be told it. Uniswap's
    ///         own v4-security-foundations skill lists `tx.origin` as Absolute
    ///         Prohibition #9 for this purpose, and the concrete failure is ERC-4337:
    ///         for a UserOperation `tx.origin` is the BUNDLER, so a smart-account LP's
    ///         position would be recorded against the bundler and the bundler could
    ///         claim it. Same for swap contributions.
    ///
    ///         hookData is only trusted from an allowlisted router. An arbitrary router
    ///         could otherwise name any address as the user and credit itself for
    ///         someone else's swap — which is the phishing vector the prohibition warns
    ///         about, merely relocated.
    mapping(address => bool) public allowedRouters;

    /// @dev Kept so sweepUnclaimed() can call donate(). The individual currencies are
    ///      already cached for payouts; donate needs the whole key.
    mapping(PoolId => PoolKey) private _poolKeys;

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

    /// @notice A gap's escrow must stay in a single currency. Unreachable while the
    ///         sign-flip rule holds (narrowing direction is fixed for a gap's life);
    ///         a named error rather than assert() so a trace says which invariant broke.
    error EscrowCurrencyMismatch(PoolId id, uint256 gapIdx);

    event SweptToLps(PoolId indexed id, uint256 gapIdx, uint256 amount);
    event RouterAllowed(address indexed router, bool allowed);
    event UnattributedAction(PoolId indexed id, address indexed router);

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

        // Assert the deployed address encodes exactly the permission bits declared in
        // getHookPermissions(). Without this a mis-mined CREATE2 salt yields a hook that
        // silently never receives beforeSwap — discovered live, not in tests.
        Hooks.validateHookPermissions(this, getHookPermissions());
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

    /// @notice Sentinel for PoolCfg.narrowingFee: no override, pool fee applies to all
    ///         swaps. Distinguishable from a legitimate zero fee, which is a real
    ///         configuration (waive the LP fee entirely for correcting flow).
    uint24 internal constant NO_FEE_OVERRIDE = type(uint24).max;

    // =========================================================================
    // Admin
    // =========================================================================

    address public owner;

    modifier onlyOwner() {
        require(msg.sender == owner, "not owner");
        _;
    }

    function setPoolCfg(PoolId id, PoolCfg calldata c) external onlyOwner {
        // A fee above MAX_LP_FEE is rejected by v4 at swap time, which would revert every
        // narrowing swap in the pool rather than failing here where it can be seen.
        require(
            c.narrowingFee == NO_FEE_OVERRIDE || c.narrowingFee <= LPFeeLibrary.MAX_LP_FEE,
            "narrowingFee > max"
        );
        require(c.baseFee <= LPFeeLibrary.MAX_LP_FEE, "baseFee > max");
        // The flip is funded by the surcharge taken from the same swap. A discount is
        // only coherent if it is a discount: charging correcting flow MORE than the
        // pool's normal fee inverts the mechanism into a second tax on the arbitrage
        // that fixes the price.
        require(
            c.narrowingFee == NO_FEE_OVERRIDE || c.narrowingFee <= c.baseFee,
            "narrowingFee > baseFee"
        );
        cfg[id] = c;
    }

    /// @notice Allow or disallow a router's hookData as a source of user identity.
    /// @dev    Allowlisting a router is a trust decision: that router can name any
    ///         address as the user for swaps and liquidity it submits. Allowlist only
    ///         routers whose identity-forwarding you have read.
    function setRouterAllowed(address router, bool allowed) external onlyOwner {
        allowedRouters[router] = allowed;
        emit RouterAllowed(router, allowed);
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
        _poolKeys[id]  = key;
        _currency0[id] = key.currency0;
        _currency1[id] = key.currency1;
        // Push sentinel at index 0 so openGapIdx==0 unambiguously means "no open gap".
        // Real gaps start at index 1.
        _gaps[id].push(Gap({
            openBlock: 0, expiryBlock: 0, refTickAtOpen: 0, tickAtOpen: 0,
            eligibleLiqAtOpen: 0, escrowed: 0, totalContribution: 0,
            lpPaid: 0, traderPaid: 0,
            maxAbsGap: 0, gapPositive: false, isCurrency0: false, settled: true, swept: true
        }));

        // A dynamic-fee pool initialises with an LP fee of ZERO (LPFeeLibrary
        // .getInitialLPFee). Without this the pool would trade fee-free until someone
        // called updateDynamicLPFee, and the fee flip would be a discount off nothing.
        if (LPFeeLibrary.isDynamicFee(key.fee)) {
            poolManager.updateDynamicLPFee(key, cfg[id].baseFee);
        }

        return IHooks.afterInitialize.selector;
    }

    // =========================================================================
    // IHooks — beforeAddLiquidity / beforeRemoveLiquidity
    // =========================================================================

    function beforeAddLiquidity(
        address sender,
        PoolKey calldata key,
        IPoolManager.ModifyLiquidityParams calldata params,
        bytes calldata hookData
    ) external override returns (bytes4) {
        require(msg.sender == address(poolManager), "not PM");
        PoolId id = key.toId();
        address lp = _resolveUser(sender, hookData);
        if (lp == sender && !allowedRouters[sender]) emit UnattributedAction(id, sender);
        bytes32 pk = _positionKey(id, lp, params.tickLower, params.tickUpper, params.salt);
        PositionInfo storage p = positions[pk];

        // ANY increase resets the age clock — closes the top-up attack
        p.addBlock  = uint48(block.number);
        if (params.liquidityDelta > 0) {
            p.liquidity += uint128(uint256(int256(params.liquidityDelta)));
        }
        p.tickLower = params.tickLower;
        p.tickUpper = params.tickUpper;

        // Track NET recently-added IN-RANGE liquidity for the eligibility denominator.
        if (params.liquidityDelta > 0 && _isInRange(id, params.tickLower, params.tickUpper)) {
            _pushCheckpoint(id, uint128(uint256(int256(params.liquidityDelta))), true);
        }

        return IHooks.beforeAddLiquidity.selector;
    }

    function beforeRemoveLiquidity(
        address sender,
        PoolKey calldata key,
        IPoolManager.ModifyLiquidityParams calldata params,
        bytes calldata hookData
    ) external override returns (bytes4) {
        require(msg.sender == address(poolManager), "not PM");
        PoolId id = key.toId();
        bytes32 pk = _positionKey(
            id, _resolveUser(sender, hookData), params.tickLower, params.tickUpper, params.salt
        );
        PositionInfo storage p = positions[pk];
        if (params.liquidityDelta < 0) {
            uint128 removed = uint128(uint256(-int256(params.liquidityDelta)));
            if (p.liquidity >= removed) p.liquidity -= removed;

            // Mirror the add: withdrawing in-range liquidity must decrement the running
            // total, or an add-then-remove permanently inflates `recentAdds`.
            if (_isInRange(id, params.tickLower, params.tickUpper)) {
                _pushCheckpoint(id, removed, false);
            }
        }
        return IHooks.beforeRemoveLiquidity.selector;
    }

    /// @notice The LP fee to return from beforeSwap for a gap-CLOSING swap.
    ///
    /// @dev Returns 0 (no override, pool fee applies) unless the flip is configured AND
    ///      the pool is a dynamic-fee pool. The second condition is not defensive
    ///      politeness: v4 reverts the swap if a static-fee pool's hook returns an
    ///      override, so returning one unconditionally would brick every narrowing swap
    ///      in any statically-priced pool the hook is attached to.
    ///
    ///      Why the discount exists at all. The surcharge alone makes this pool a worse
    ///      venue for the flow that fixes its price: an arbitrageur's break-even widens,
    ///      so the equilibrium gap sits WIDER here than in a vanilla pool, and capture is
    ///      funded by degrading the very thing it measures. The flip inverts that. A swap
    ///      that closes the gap pays a reduced LP fee, funded by the surcharge collected
    ///      from the swaps that opened it, which makes this the cheapest venue in
    ///      existence for corrective flow while widening flow still pays full freight.
    ///
    ///      The net arithmetic, which must stay true and is asserted in FeeFlip.t.sol:
    ///
    ///          closer  pays  surcharge − (baseFee − narrowingFee)  >  0
    ///          widener pays  baseFee, no surcharge
    ///
    ///      Closing a gap is still MORE expensive than widening one. The discount reduces
    ///      the penalty on correction; it does not pay anyone to correct. setPoolCfg
    ///      enforces narrowingFee <= baseFee so the discount cannot become a surcharge,
    ///      but the surcharge side depends on gap and notional and cannot be bounded
    ///      statically — a captureRateBps low enough relative to the fee discount would
    ///      make correcting flow net-cheaper than not trading. Sweep for it.
    function _narrowingFeeOverride(uint24 poolFee, uint24 narrowingFee)
        internal
        pure
        returns (uint24)
    {
        if (narrowingFee == NO_FEE_OVERRIDE) return 0;
        if (!LPFeeLibrary.isDynamicFee(poolFee)) return 0;
        return narrowingFee | LPFeeLibrary.OVERRIDE_FEE_FLAG;
    }

    // =========================================================================
    // IHooks — beforeSwap
    // =========================================================================

    function beforeSwap(
        address sender,
        PoolKey calldata key,
        IPoolManager.SwapParams calldata params,
        bytes calldata hookData
    ) external override returns (bytes4, BeforeSwapDelta, uint24) {
        require(msg.sender == address(poolManager), "not PM");
        PoolId id = key.toId();
        PoolCfg storage c = cfg[id];

        (int24 refTick, bool ok, uint24 divTicks) = referenceOracle.getRefTick(id);
        if (!ok) {
            // Invalidate the cache: afterSwap must not attribute this swap using
            // direction data from a previous one.
            _swapCache[id] = SwapCache({
                absGapBefore: 0, refTick: 0, wasNarrowing: false, valid: false
            });
            return (IHooks.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
        }

        (uint160 sqrtPriceX96, int24 tick,,) = StateLibrary.getSlot0(poolManager, id);
        int24 gapBefore = tick - refTick;

        // Direction is decided here, on the PRE-swap gap, and cached for afterSwap.
        // Computed before every early return below: a swap that is not surcharged
        // (exact-output, no open gap) can still be a legitimate widener.
        bool narrowing = GapMath.isNarrowing(gapBefore, params.zeroForOne);
        _swapCache[id] = SwapCache({
            absGapBefore: GapMath.abs(gapBefore),
            refTick:      refTick,
            wasNarrowing: narrowing,
            valid:        true
        });

        uint256 idx = openGapIdx[id];

        // An expired gap must stop charging. Nothing on the swap path read expiryBlock,
        // so a gap whose dislocation vanished — because the REFERENCE moved back and no
        // swap occurred, which the hook never sees — stayed open indefinitely, and the
        // next swap that happened to be narrowing against a 2-tick residual paid the
        // full maxAbsGap peak rate. One innocent trader eating a stale surcharge.
        if (idx != 0 && block.number > _gaps[id][idx].expiryBlock) {
            _closeGap(id, idx);
            idx = 0;
        }

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

        if (!narrowing) return (IHooks.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);

        // Exact-output swaps are surcharged too. They previously returned early on
        // `amountSpecified >= 0`, which in v4 is EXACT OUTPUT — so an arbitrageur flipped
        // one flag in their swap params and paid nothing. Measured: 1920e18 via exact
        // input, 0 via exact output on the same gap. Every router supports exact output,
        // so this was the mechanism's cheapest and most complete bypass.
        bool exactInput = params.amountSpecified < 0;

        // Notional must be expressed in the currency the surcharge is taken in, which is
        // always the INPUT currency (see the return statement below). For an exact-output
        // swap `amountSpecified` counts OUTPUT tokens, so it is converted at the pre-swap
        // pool price. Skipping this conversion would misprice by the whole exchange rate
        // — on ETH/USDC by a factor of ~3000.
        //
        // The conversion ignores the price impact of the swap itself, so an exact-output
        // surcharge is a slight approximation of its exact-input equivalent. Bounded by
        // the same surchargeCapBps and measured at under 10% in ExactOutput.t.sol.
        uint256 notional = exactInput
            ? uint256(-params.amountSpecified)
            : _outputToInput(sqrtPriceX96, uint256(params.amountSpecified), params.zeroForOne);

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
            notional,
            gp.maxAbsGap,
            c.captureRateBps,
            c.surchargeCapBps
        );

        // Reference-source disagreement is PRICED, not switched on. Appendix §10: the
        // previous design froze the hook above guardMaxDevTicks, and freezing means zero
        // surcharge on every gap of every size — an off-switch anyone could reach for a
        // measured $7-$21 by pushing the thin fast pool one tick past the tolerance. No
        // value of that tolerance closed both the freeze route and the masking route.
        //
        // The curve removes the state to aim at. Each extra tick of manipulation raises
        // the cost of the very arbitrage the manipulator is protecting, monotonically,
        // with no discontinuity. The multiplier is applied AFTER surchargeCapBps so the
        // ceiling itself rises with divergence: a cap applied last would neutralise the
        // deterrent exactly when it is needed, handing back a rate-limited off-switch.
        uint256 multBps =
            DivergenceMath.multiplierBps(divTicks, c.guardMaxDevTicks, c.divSlopeBps, c.maxDivMultBps);
        if (multBps > DivergenceMath.ONE && surcharge != 0) {
            uint256 scaled = FullMath.mulDiv(uint256(surcharge), multBps, DivergenceMath.ONE);

            // Two ceilings, both load-bearing: the swapper's input, and the uint128 the
            // escrow is stored in. See DivergenceMath.clampToEscrow — the second one is
            // what stops a large enough swap from truncating the surcharge to near-zero
            // and handing back the off-switch through an arithmetic edge.
            surcharge = DivergenceMath.clampToEscrow(scaled, notional);
        }

        // The discount is a property of DIRECTION, not of surcharge size. A narrowing
        // swap whose surcharge rounds to zero is still corrective flow and still gets
        // the cheaper fee; withholding it here would make the incentive fire only on
        // large gaps, which is exactly where correction already pays for itself.
        if (surcharge == 0) {
            return (
                IHooks.beforeSwap.selector,
                BeforeSwapDeltaLibrary.ZERO_DELTA,
                _narrowingFeeOverride(key.fee, c.narrowingFee)
            );
        }

        // Escrow is ALWAYS taken in the input currency, for both swap types. This is
        // what preserves the one-currency-per-gap invariant: for exact input the input
        // currency is the SPECIFIED one, for exact output it is the UNSPECIFIED one, and
        // v4-core maps them accordingly (Hooks.afterSwap picks the BalanceDelta ordering
        // from `amountSpecified < 0 == zeroForOne`). Taking exact output on the specified
        // side instead would land escrow in the output currency and make a gap closed by
        // a mix of swap types revert on the currency invariant.
        Currency spec = params.zeroForOne ? key.currency0 : key.currency1;
        poolManager.mint(address(this), spec.toId(), surcharge);

        if (gp.escrowed == 0) {
            gp.isCurrency0 = params.zeroForOne;
        } else if (gp.isCurrency0 != params.zeroForOne) {
            revert EscrowCurrencyMismatch(id, idx);
        }
        gp.escrowed += surcharge;

        emit Surcharged(id, idx, _resolveUser(sender, hookData), surcharge);

        // Positive delta => hook is owed => taken from the swapper.
        // Exact input:  the input currency is SPECIFIED   -> (surcharge, 0)
        // Exact output: the input currency is UNSPECIFIED -> (0, surcharge)
        // Third slot: the LP fee override. Every OTHER return path in this function
        // returns 0 there — a widener, a swap with no gap open, and a frozen reference
        // all pay the pool's normal fee. Only a swap that closes an open gap is
        // discounted, and it is the same swap paying the surcharge.
        uint24 feeOverride = _narrowingFeeOverride(key.fee, c.narrowingFee);

        return exactInput
            ? (IHooks.beforeSwap.selector, toBeforeSwapDelta(int128(surcharge), 0), feeOverride)
            : (IHooks.beforeSwap.selector, toBeforeSwapDelta(0, int128(surcharge)), feeOverride);
    }

    // =========================================================================
    // IHooks — afterSwap
    // =========================================================================

    function afterSwap(
        address sender,
        PoolKey calldata key,
        IPoolManager.SwapParams calldata,
        BalanceDelta,
        bytes calldata hookData
    ) external override returns (bytes4, int128) {
        require(msg.sender == address(poolManager), "not PM");
        PoolId id = key.toId();
        PoolCfg storage c = cfg[id];

        // R3: reuse beforeSwap's reference read rather than making three more external
        // calls. PoolManager always invokes beforeSwap immediately before the swap and
        // afterSwap immediately after, in the same transaction, so the cache is fresh by
        // construction. An invalid cache means beforeSwap froze; afterSwap must too.
        SwapCache memory sc = _swapCache[id];
        if (!sc.valid) return (IHooks.afterSwap.selector, 0);
        int24 refTick = sc.refTick;

        (, int24 tick,,) = StateLibrary.getSlot0(poolManager, id);
        int24 gapNow  = tick - refTick;
        uint24 absNow = GapMath.abs(gapNow);

        uint256 idx = openGapIdx[id];

        // A swap earns ledger credit only if it ENTERED moving away from the
        // reference. Direction at entry, never final position: an arbitrageur that
        // overshoots ends up further from the reference than it started, and under
        // the old `absNow > absBefore` test that made the corrector the pool's
        // largest "contributor" — the exact rebate-to-the-arbitrageur failure that
        // killed the own-pool-EMA design (appendix §5).
        bool creditable = sc.valid && !sc.wasNarrowing;
        address trader = _resolveUser(sender, hookData);

        if (idx == 0) {
            // Reaching here means the gap was BELOW threshold at entry (beforeSwap
            // would otherwise have opened it) and is above it now — so this swap
            // created the dislocation. It is the originator and must be credited.
            if (absNow > c.gapThresholdTicks) {
                _openGap(id, refTick, tick, gapNow);
                _credit(id, openGapIdx[id], trader, sc.absGapBefore, absNow, creditable);
            }
            return (IHooks.afterSwap.selector, 0);
        }

        Gap storage g = _gaps[id][idx];

        _credit(id, idx, trader, sc.absGapBefore, absNow, creditable);

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

    /// @notice Return a settled gap's unclaimed remainder to the pool's LPs.
    /// @dev    Permissionless, and only after the gap has been settled and expired plus
    ///         a grace period, so eligible claimants have had their window.
    ///
    ///         This exists because escrow could otherwise be stranded forever. The
    ///         eligibility denominator is pool-wide in-range liquidity minus recent
    ///         adds, while claims come from individual positions — when the denominator
    ///         exceeds the claimants (out-of-range liquidity at gap open, positions
    ///         added through a non-allowlisted router, LPs who simply never claim) the
    ///         difference has no owner and no route out. There is no owner withdrawal
    ///         and no treasury: the remainder is donated back into the pool, which
    ///         credits current in-range LPs. Nothing here requires trusting the admin.
    function sweepUnclaimed(PoolId id, uint256 gapIdx) external {
        Gap storage g = _gaps[id][gapIdx];
        require(g.settled, "not settled");
        require(!g.swept, "swept");
        require(block.number > uint256(g.expiryBlock) + cfg[id].sweepGraceBlocks, "too early");

        uint256 traderPot = _traderPot(id, g);
        uint256 lpPot     = uint256(g.escrowed) - traderPot;
        uint256 remainder = (lpPot - uint256(g.lpPaid)) + (traderPot - uint256(g.traderPaid));
        g.swept = true;
        if (remainder == 0) return;

        Currency cur = g.isCurrency0 ? _currency0[id] : _currency1[id];
        poolManager.unlock(abi.encode(PayoutData({
            currency: cur, to: address(0), amount: remainder, isDonate: true, key: _poolKeys[id]
        })));
        emit SweptToLps(id, gapIdx, remainder);
    }

    function claimTrader(PoolId id, uint256 gapIdx) external {
        Gap storage g = _gaps[id][gapIdx];
        require(g.settled && g.totalContribution > 0, "n/a");
        bytes32 k = _contributionKey(id, gapIdx, msg.sender);
        uint128 c = contribution[k];
        require(c > 0, "nothing");
        contribution[k] = 0;

        uint256 owed = (_traderPot(id, g) * c) / g.totalContribution;

        // Same cap as claimLp, for the same reason: never pay a gap more than it holds.
        uint256 remaining = _traderPot(id, g) - uint256(g.traderPaid);
        if (owed > remaining) owed = remaining;
        g.traderPaid += uint128(owed);

        _payout(id, g, msg.sender, owed);
        emit TraderClaimed(id, gapIdx, msg.sender, owed);
    }

    /// @notice Claim an LP's share of a settled gap's escrow.
    /// @dev    The position key is DERIVED from msg.sender — never accepted as an
    ///         argument. Taking it as a parameter let any address pass another LP's
    ///         key and be paid, because every input to _positionKey (poolId, owner,
    ///         ticks, salt) is public or enumerable from events.
    ///         Positions are recorded against the address an allowlisted router names
    ///         in hookData, or against the router itself when it is not allowlisted. An
    ///         LP therefore claims from the address their router declared — which for a
    ///         smart-contract wallet or ERC-4337 account is the account, as it should
    ///         be, rather than the bundler.
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

        // Cap against what this gap still owes. `eligibleLiqAtOpen` is derived from
        // pool-wide in-range liquidity minus recent adds, while claims sum over each
        // eligible position's own `p.liquidity` — two different quantities with no
        // structural guarantee that the second is bounded by the first.
        //
        // They diverge without any malice. An LP who adds in-range inside the lookback
        // window and whose range then falls OUT of range before the gap opens is
        // subtracted from the denominator but contributes nothing to the numerator, so
        // every other LP's share is scaled up. Measured shape: 10M eligible + 5M
        // subtracted leaves a 5M denominator against a 10M claimant — 200% of the pot.
        //
        // Escrow is held as one undifferentiated ERC-6909 balance, so an over-claim on
        // one gap is paid out of OTHER gaps' escrow. The cap turns a cross-gap solvency
        // leak into a bounded shortfall on the affected gap alone.
        uint256 remaining = lpPot - uint256(g.lpPaid);
        if (owed > remaining) owed = remaining;
        g.lpPaid += uint128(owed);

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
    function _credit(
        PoolId id, uint256 idx, address trader, uint24 absBefore, uint24 absNow, bool creditable
    ) internal {
        if (!creditable || absNow <= absBefore) return;
        uint128 d = uint128(absNow - absBefore);
        contribution[_contributionKey(id, idx, trader)] += d;
        _gaps[id][idx].totalContribution += d;
        emit Contributed(id, idx, trader, d);
    }

    function _openGap(PoolId id, int24 refTick, int24 tickNow, int24 gapNow) internal {
        PoolCfg storage c = cfg[id];
        uint48 openBlock = uint48(block.number);

        // Eligible liquidity denominator: in-range liquidity minus recently-added
        uint128 inRange    = StateLibrary.getLiquidity(poolManager, id);
        uint128 addedNow   = _totalAdded[id];
        uint48  lookback   = openBlock > c.minAgeBlocks ? openBlock - c.minAgeBlocks : 0;
        uint128 addedThen  = _cumulativeAddedAt(id, lookback);
        // addedNow can now be BELOW addedThen (net removals since the lookback), so the
        // difference must be clamped before it underflows a uint128.
        uint128 recentAdds = addedNow > addedThen ? addedNow - addedThen : 0;
        uint128 eligibleLiq = inRange > recentAdds ? inRange - recentAdds : 0;

        _gaps[id].push(Gap({
            openBlock:        openBlock,
            expiryBlock:      openBlock + c.expiryBlocks,
            refTickAtOpen:    refTick,
            tickAtOpen:       tickNow,
            eligibleLiqAtOpen: eligibleLiq,
            escrowed:         0,
            totalContribution: 0,
            lpPaid:           0,
            traderPaid:       0,
            maxAbsGap:        GapMath.abs(gapNow),
            gapPositive:      gapNow > 0,
            isCurrency0:      false,
            settled:          false,
            swept:            false
        }));

        uint256 newIdx = _gaps[id].length - 1;
        openGapIdx[id] = newIdx;
        emit GapOpened(id, newIdx, refTick, openBlock);
    }

    /// @dev Settles as it closes. settle() is permissionless and pays its caller
    ///      nothing, so in practice nobody would ever call it: gaps would close, escrow
    ///      would sit unsettled, and no claim could be made because claimTrader and
    ///      claimLp both require g.settled. Settling here costs one storage write on a
    ///      path that is already writing, and makes the claim path reachable without
    ///      relying on an altruistic keeper.
    function _closeGap(PoolId id, uint256 idx) internal {
        openGapIdx[id] = 0;
        Gap storage g = _gaps[id][idx];
        if (!g.settled) {
            g.settled = true;
            emit Settled(id, idx, _traderPot(id, g), uint256(g.escrowed) - _traderPot(id, g));
        }
        emit GapClosed(id, idx, g.escrowed);
    }

    function _isGapOpen(PoolId id, uint256 idx) internal view returns (bool) {
        return openGapIdx[id] == idx;
    }

    // Encoded payload for unlockCallback — used by claimTrader/claimLp
    struct PayoutData {
        Currency currency;
        address  to;        // ignored when isDonate
        uint256  amount;
        bool     isDonate;  // true => donate to the pool's LPs instead of transferring
        PoolKey  key;       // only used when isDonate
    }

    /// @notice IUnlockCallback — called back by PoolManager during claim payouts.
    ///         burn() and take() require the PM to be in an unlocked context.
    ///         Claim functions are called outside swaps, so we must self-unlock.
    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        require(msg.sender == address(poolManager), "not PM");
        PayoutData memory p = abi.decode(data, (PayoutData));
        poolManager.burn(address(this), p.currency.toId(), p.amount);
        if (p.isDonate) {
            // Return the remainder to the pool's current LPs rather than to an admin.
            // donate() credits in-range liquidity directly, so unclaimed LP capture goes
            // back to LPs — no treasury, no owner discretion, nothing to trust.
            bool zero = Currency.unwrap(p.currency) == Currency.unwrap(p.key.currency0);
            poolManager.donate(p.key, zero ? p.amount : 0, zero ? 0 : p.amount, "");
        } else {
            poolManager.take(p.currency, p.to, p.amount);
        }
        return "";
    }

    function _payout(PoolId id, Gap storage g, address to, uint256 amount) internal {
        if (amount == 0) return;
        Currency cur = g.isCurrency0 ? _currency0[id] : _currency1[id];
        // burn+take require an unlock context; claim functions are called outside swaps.
        poolManager.unlock(abi.encode(PayoutData({
            currency: cur, to: to, amount: amount, isDonate: false, key: _poolKeys[id]
        })));
    }

    function _contributionKey(PoolId id, uint256 gapIdx, address addr) internal pure returns (bytes32) {
        return keccak256(abi.encode(id, gapIdx, addr));
    }

    /// @notice Convert an exact-output amount into the equivalent input-token amount at
    ///         the current pool price, so the surcharge is bps of the right quantity.
    /// @dev    priceX96 = (sqrtP/2^96)^2 * 2^96 = token1 per token0, Q96. Computed with
    ///         FullMath because sqrtP^2 overflows uint256 for large prices; the 512-bit
    ///         intermediate keeps sqrtP^2 / 2^96 <= 2^224, which fits.
    ///           zeroForOne: input token0, output token1 -> in = out / price
    ///           oneForZero: input token1, output token0 -> in = out * price
    function _outputToInput(uint160 sqrtPriceX96, uint256 amountOut, bool zeroForOne)
        internal
        pure
        returns (uint256)
    {
        uint256 priceX96 = FullMath.mulDiv(
            uint256(sqrtPriceX96), uint256(sqrtPriceX96), FixedPoint96.Q96
        );
        if (priceX96 == 0) return 0;
        return zeroForOne
            ? FullMath.mulDiv(amountOut, FixedPoint96.Q96, priceX96)
            : FullMath.mulDiv(amountOut, priceX96, FixedPoint96.Q96);
    }

    /// @notice Resolve the end user behind a hook callback.
    /// @param  sender   the router, as v4 passes it
    /// @param  hookData abi.encode(address user) when the router forwards identity
    /// @dev    Falls back to `sender` rather than reverting. A hook must not brick swaps
    ///         for anyone using an unrecognised router — the same freeze-not-revert
    ///         principle the reference guard follows. The consequence of falling back is
    ///         that attribution accrues to the router rather than to its users, which is
    ///         a loss of a rebate, never a theft: the surcharge is charged identically
    ///         either way, so routing through an unknown router is not a bypass.
    function _resolveUser(address sender, bytes calldata hookData) internal view returns (address) {
        if (allowedRouters[sender] && hookData.length == 32) {
            address u = abi.decode(hookData, (address));
            if (u != address(0)) return u;
        }
        return sender;
    }

    function _positionKey(PoolId id, address owner_, int24 tickLower, int24 tickUpper, bytes32 salt)
        internal pure returns (bytes32)
    {
        return keccak256(abi.encode(id, owner_, tickLower, tickUpper, salt));
    }

    // =========================================================================
    // Checkpoint helpers (simplified — OZ Checkpoints in production)
    // =========================================================================

    /// @notice Record a change to the pool's recently-added in-range liquidity.
    /// @dev    Previously this only ever incremented, so an add-then-remove left the
    ///         cumulative permanently inflated. `eligibleLiq = inRange - recentAdds`
    ///         then clamped to zero and `claimLp` reverted with "no eligible liq" for
    ///         EVERY honest LP on gaps opened in that window — a griefing DoS on the LP
    ///         leg costing an attacker a round trip plus gas. It now decrements on
    ///         removal so the running total tracks NET recent adds.
    function _pushCheckpoint(PoolId id, uint128 delta, bool isAdd) internal {
        if (delta == 0) return;
        uint128 cur = _totalAdded[id];
        _totalAdded[id] = isAdd
            ? cur + delta
            : (cur > delta ? cur - delta : 0);
        _addedCheckpointBlocks[id].push(block.number);
        _addedCheckpointValues[id].push(_totalAdded[id]);
    }

    /// @dev A position only affects `getLiquidity(id)` — the in-range figure the
    ///      eligibility denominator is built from — while the current tick sits inside
    ///      its range. Counting out-of-range adds contaminated the subtraction with
    ///      liquidity that was never in the minuend, letting an attacker inflate
    ///      `recentAdds` with a position that contributes nothing to the pool.
    function _isInRange(PoolId id, int24 tickLower, int24 tickUpper) internal view returns (bool) {
        (, int24 tickNow,,) = StateLibrary.getSlot0(poolManager, id);
        return tickLower <= tickNow && tickNow < tickUpper;
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
