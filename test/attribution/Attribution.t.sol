// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {BackdraftTestBase} from "../BackdraftTestBase.sol";
import {BackdraftHook}     from "../../src/BackdraftHook.sol";

// ============================================================
// Attribution regression tests.
//
// History: afterSwap credited any swap satisfying `absNow > absBefore` — a test on
// where a swap LANDED, not which way it went. Two consequences, both measured on the
// unpatched branch:
//
//   * The swap that OPENED a gap returned early and was never credited, so the trader
//     whose price impact created the mispricing received nothing.
//   * An arbitrageur whose closing swap overshot the reference ended up further from it
//     than it started, satisfied the test, and was credited. Measured on the canonical
//     Rohan -> Vik scenario: Vik 1146 ticks, Rohan 377 of 1523 total. The corrector
//     took 75% of the trader pot out of the surcharge it had just paid.
//
// That is the rebate-to-the-arbitrageur failure that killed the own-pool-EMA design
// (appendix §5), reintroduced through the ledger.
//
// The rule these tests pin: credit follows DIRECTION AT ENTRY, never final position.
// A swap that entered narrowing is a corrector and can never earn ledger credit,
// wherever it lands.
// ============================================================
contract AttributionTest is BackdraftTestBase {

    address constant LP     = address(0x1001);
    address constant ROHAN  = address(0xaaaa);   // originator
    address constant RETAIL = address(0xcccc);   // second widener
    address constant VIK    = address(0xbbbb);   // arbitrageur / corrector

    int24 constant LO = -6000;
    int24 constant HI =  6000;

    function setUp() public override {
        super.setUp();
        _fund(LP); _fund(ROHAN); _fund(RETAIL); _fund(VIK);
        _addLiquidity(LP, LO, HI, 10_000_000e18);
        vm.roll(block.number + minAgeBlocks + 1);
    }

    function _fund(address who) internal {
        token0.transfer(who, 50_000_000e18);
        token1.transfer(who, 50_000_000e18);
    }

    function _contrib(uint256 idx, address who) internal view returns (uint128) {
        return hook.contribution(keccak256(abi.encode(poolId, idx, who)));
    }

    // ------------------------------------------------------------------
    // Originator is credited
    // ------------------------------------------------------------------

    /// @notice The swap that opens a gap is the originator and must be credited.
    ///         Previously afterSwap returned early on this branch.
    function test_OriginatorCreditedOnGapOpen() public {
        _swap(ROHAN, false, -500_000e18);
        uint256 idx = hook.openGapIdx(poolId);
        assertGt(idx, 0, "precondition: gap must open");

        assertGt(_contrib(idx, ROHAN), 0, "originator must be credited on the opening swap");
        assertEq(hook.gapAt(poolId, idx).totalContribution, _contrib(idx, ROHAN),
            "originator is the only contributor so far");
    }

    /// @notice Successive wideners accumulate, each credited its own increment.
    function test_SecondWidenerAccumulates() public {
        _swap(ROHAN, false, -500_000e18);
        uint256 idx = hook.openGapIdx(poolId);
        uint128 rohan = _contrib(idx, ROHAN);

        _swap(RETAIL, false, -100_000e18);

        assertGt(_contrib(idx, RETAIL), 0, "second widener must be credited");
        assertEq(_contrib(idx, ROHAN), rohan, "earlier credit must not change");
        assertEq(
            hook.gapAt(poolId, idx).totalContribution,
            _contrib(idx, ROHAN) + _contrib(idx, RETAIL),
            "ledger must equal the sum of its parts"
        );
    }

    // ------------------------------------------------------------------
    // Corrector is NOT credited — the headline
    // ------------------------------------------------------------------

    /// @notice The canonical scenario. The arbitrageur closes the gap, overshoots the
    ///         reference, and must receive ZERO ledger credit. On the unpatched
    ///         branch Vik held 75% of the ledger here.
    function test_ArbitrageurNotCreditedOnOvershoot() public {
        _swap(ROHAN, false, -500_000e18);
        uint256 idx = hook.openGapIdx(poolId);
        _swap(ROHAN, false, -200_000e18);

        uint128 ledgerBefore = hook.gapAt(poolId, idx).totalContribution;
        assertGt(ledgerBefore, 0, "precondition: ledger non-empty before the close");

        _swap(VIK, true, -2_000_000e18);        // closes, and overshoots past the reference

        assertEq(_contrib(idx, VIK), 0, "the corrector must never be credited");
        assertEq(hook.gapAt(poolId, idx).totalContribution, ledgerBefore,
            "closing swap must not change the ledger");
    }

    /// @notice A narrowing swap that does NOT overshoot is equally uncredited.
    function test_PartialCloseNotCredited() public {
        _swap(ROHAN, false, -500_000e18);
        uint256 idx = hook.openGapIdx(poolId);
        uint128 ledgerBefore = hook.gapAt(poolId, idx).totalContribution;

        _swap(VIK, true, -50_000e18);           // narrows a little, gap stays open

        assertEq(_contrib(idx, VIK), 0, "partial corrector must not be credited");
        assertEq(hook.gapAt(poolId, idx).totalContribution, ledgerBefore,
            "partial close must not change the ledger");
    }

    /// @notice Overshoot must still CLOSE the gap. The attribution fix must not
    ///         regress the sign-flip rule that keeps escrow single-currency (§3.2).
    function test_OvershootStillClosesGap() public {
        _swap(ROHAN, false, -500_000e18);
        uint256 idx = hook.openGapIdx(poolId);

        _swap(VIK, true, -2_000_000e18);

        assertTrue(hook.openGapIdx(poolId) != idx, "overshoot must close the gap");
    }

    /// @notice maxAbsGap is the denominator of the poisoning defence and must track
    ///         only how wide WIDENERS pushed the gap. An overshooting corrector
    ///         previously inflated it, shrinking `explained` and moving value from
    ///         the trader pot to LPs on every overshot close.
    function test_OvershootDoesNotInflateMaxAbsGap() public {
        _swap(ROHAN, false, -500_000e18);
        uint256 idx = hook.openGapIdx(poolId);
        uint24 maxBefore = hook.gapAt(poolId, idx).maxAbsGap;

        _swap(VIK, true, -2_000_000e18);

        assertEq(hook.gapAt(poolId, idx).maxAbsGap, maxBefore,
            "corrector must not move the poisoning-defence denominator");
    }

    // ------------------------------------------------------------------
    // End to end: the money follows the attribution
    // ------------------------------------------------------------------

    /// @notice The trader pot reaches the originator, and the arbitrageur cannot
    ///         claim any of the surcharge it paid.
    function test_TraderPotGoesToOriginatorNotArbitrageur() public {
        _swap(ROHAN, false, -500_000e18);
        uint256 idx = hook.openGapIdx(poolId);
        _swap(ROHAN, false, -200_000e18);
        _swap(VIK, true, -2_000_000e18);

        assertGt(hook.gapAt(poolId, idx).escrowed, 0, "precondition: surcharge escrowed");
        hook.settle(poolId, idx);

        uint256 vBefore0 = token0.balanceOf(VIK);
        uint256 vBefore1 = token1.balanceOf(VIK);
        vm.prank(VIK, VIK);
        vm.expectRevert(abi.encodeWithSignature("Error(string)", "nothing"));
        hook.claimTrader(poolId, idx);
        assertEq(token0.balanceOf(VIK), vBefore0, "arbitrageur must gain no currency0");
        assertEq(token1.balanceOf(VIK), vBefore1, "arbitrageur must gain no currency1");

        uint256 rBefore = token0.balanceOf(ROHAN) + token1.balanceOf(ROHAN);
        vm.prank(ROHAN, ROHAN);
        hook.claimTrader(poolId, idx);
        assertGt(token0.balanceOf(ROHAN) + token1.balanceOf(ROHAN), rBefore,
            "originator must receive the trader pot");
    }

    // ------------------------------------------------------------------
    // Fuzz
    // ------------------------------------------------------------------

    /// @notice No closing swap of any size can earn ledger credit — including sizes
    ///         that overshoot the reference by an arbitrary margin.
    function testFuzz_CorrectorNeverCredited(uint96 closeSize) public {
        closeSize = uint96(bound(closeSize, 1e15, 5_000_000e18));

        _swap(ROHAN, false, -500_000e18);
        uint256 idx = hook.openGapIdx(poolId);
        uint128 ledgerBefore = hook.gapAt(poolId, idx).totalContribution;

        _swap(VIK, true, -int256(uint256(closeSize)));

        assertEq(_contrib(idx, VIK), 0, "corrector credited at some size");
        assertEq(hook.gapAt(poolId, idx).totalContribution, ledgerBefore,
            "ledger moved on a narrowing swap");
    }

    /// @notice Whatever the widening size, credit lands on the widener and never
    ///         exceeds the widest the gap actually reached.
    function testFuzz_LedgerNeverExceedsMaxAbsGap(uint96 openSize, uint96 secondSize) public {
        openSize   = uint96(bound(openSize,   200_000e18, 2_000_000e18));
        secondSize = uint96(bound(secondSize,  10_000e18,   500_000e18));

        _swap(ROHAN, false, -int256(uint256(openSize)));
        uint256 idx = hook.openGapIdx(poolId);
        vm.assume(idx > 0);

        _swap(RETAIL, false, -int256(uint256(secondSize)));

        BackdraftHook.Gap memory g = hook.gapAt(poolId, idx);
        assertLe(g.totalContribution, g.maxAbsGap,
            "ledger cannot explain more than the gap ever was");
        assertEq(_contrib(idx, VIK), 0, "an address that never swapped holds credit");
    }
}
