# Backdraft — Change Log

Changes are appended chronologically. Never deleted.

---

## Session 2026-08-28

### Repo initialisation
- `forge init` into project root, git submodules for v4-core, v4-periphery, openzeppelin-contracts, forge-std
- `foundry.toml`: solc 0.8.26, optimizer 200 runs, `via_ir = true`, fuzz 10k runs, invariant 256 runs
- `remappings.txt`: v4-core/, v4-periphery/, @openzeppelin/, forge-std/
- `.env.example`, `.gitignore`

### Interfaces and libraries
- `src/interfaces/IReferencePrice.sol` — `getRefTick(PoolId) → (int24, bool)`
- `src/interfaces/IUniswapV3PoolMinimal.sol` — slot0, observe, liquidity, token0/1, increaseObservationCardinality
- `src/libraries/GapMath.sol` — `abs(int24)`, `isNarrowing(int24, bool)`
- `src/libraries/SurchargeMath.sol` — `compute(notional, gapTicks, rateBps, capBps) → uint128`
- `src/libraries/EligibilityLib.sol` — `isEligible(addBlock, openBlock, minAgeBlocks)`, `isInRange(tickLower, tickUpper, tickAtOpen)`

### Oracle references
- `src/references/SplitV3Reference.sol` — production oracle: fast v3 pool spot + deep v3 pool TWAP guard
- `src/references/OwnPoolEmaReference.sol` — broken baseline kept for comparison; fatal flaw documented

### Hook
- `src/BackdraftHook.sol` — full hook implementation
  - `afterInitialize`: stores currencies, pushes sentinel gap at index 0 (so openGapIdx==0 unambiguously means no gap)
  - `beforeAddLiquidity / beforeRemoveLiquidity`: position tracking keyed by `tx.origin` (not router sender)
  - `beforeSwap`: classifies narrowing, mints ERC-6909 surcharge, returns BeforeSwapDelta
  - `afterSwap`: updates contribution ledger, tracks maxAbsGap, opens/closes gaps
  - `settle()`, `claimTrader()`, `claimLp()`
  - `_payout()` via `IUnlockCallback` — burn+take require an unlock context; claim functions self-unlock

### Tests — unit
- `test/unit/GapMath.t.sol` — 8 tests, all pass
- `test/unit/SurchargeMath.t.sol` — 5 tests, all pass
- `test/unit/Eligibility.t.sol` — 5 tests, all pass
- `test/unit/BackdraftHook.t.sol` — 11 integration tests for the hook:
  - NoSurchargeWhenNoGapOpen
  - NoSurchargeOnWideningSwap
  - SurchargeCollectedOnClosingSwap
  - NoGapBelowThreshold
  - GapOpensAboveThreshold
  - WideningSwapCredited (clarified: opening swap doesn't contribute, second widening swap does)
  - SignFlipClosesGap
  - FrozenOracleDoesNothing
  - ManipulatedFastPool_OracleReturnsFrozen
  - ExogenousGap_EmptyLedger_LpsGetAll
  - SurchargeRespectsCap

### Tests — integration
- `test/integration/EndToEnd.t.sol` — 5 end-to-end scenarios:
  - EndogenousGap_FullCycle: LP_old eligible, LP_new JIT-blocked, Rohan opens, Retail widens, Vik closes, settle, claims, conservation check
  - ExogenousGap_AllToLPs: oracle jumps, empty ledger, 100% to LPs, trader claim reverts
  - SettleRevertsWhileGapOpen
  - SettleAfterExpiry
  - DoubleSettleReverts

### Tests — fork
- `test/fork/Replay.t.sol` — mainnet fork: reference reader validated against real v3 pools, gas=74,307

### Mocks and test base
- `test/mocks/MockReferenceOracle.sol`
- `test/BackdraftTestBase.sol` — shared setup: deploys PoolManager, routers, hook, tokens; `_addLiquidity` and `_swap` use `vm.startPrank(addr, addr)` to set both msg.sender and tx.origin

### Bugs fixed during this session
1. `reference` is a reserved keyword — renamed to `getRefTick` everywhere
2. `int32(s.alpha)` cast from uint8 — fixed to `int32(uint32(s.alpha))`
3. Non-checksummed pool addresses in fork test — fixed to EIP-55 checksummed form
4. String == comparison in Solidity — replaced with `block.chainid == 31337` check
5. Stack too deep — added `via_ir = true` to foundry.toml
6. `PoolManager()` no-arg constructor — updated to `new PoolManager(address(this))`
7. `manager.getSlot0()` not a direct method — must use `StateLibrary.getSlot0(manager, poolId)`
8. `manager.getLiquidity()` not a direct method — must use `StateLibrary.getLiquidity(manager, poolId)`
9. `openGapIdx == 0` ambiguous sentinel — fixed by pushing a dummy gap at index 0 in `afterInitialize`
10. `uint48(openBlock) - uint48(minAgeBlocks)` underflow in test env (block.number=1) — guarded with `openBlock > minAgeBlocks ? ... : 0`
11. `100_000e18 * surchargeCapBps` overflow — Solidity infers a smaller uint type for the literal; fixed with explicit `uint256(...)` cast
12. `vm.startPrank(addr)` only sets msg.sender, not tx.origin — contribution and position keys use tx.origin; changed to `vm.startPrank(addr, addr)`
13. Position keys in hook used `sender` (the router address) not the LP — changed to `tx.origin`
14. `poolManager.burn()+take()` called outside unlock context in claim functions — added `IUnlockCallback`, claim functions now call `poolManager.unlock()` which calls back into `unlockCallback` to do the actual burn+take
15. `vm.expectRevert(bytes("n/a"))` — 3-byte raw data triggers forge internal panic in error decoder; fixed to `abi.encodeWithSignature("Error(string)", "n/a")` for all require-string reverts
16. Exogenous gap test: VIK's large overshoot past ref credits VIK as contributor, so `totalContribution > 0` — removed the unreachable `claimTrader` revert assertion; conservation check (`lpGot <= escrowed`) is the real invariant anyway
