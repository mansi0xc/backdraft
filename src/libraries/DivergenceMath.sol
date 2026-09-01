// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @notice Prices reference-source disagreement instead of switching on it.
///
/// The shape is flat-then-linear:
///
///     multiplier
///         |                                        ,-- maxMultBps (ceiling)
///   maxM  |                              _________/
///         |                          ___/
///         |                      ___/   slope = slopeBps per tick of excess
///   1.00x |_____________________/
///         |
///         +---------------------|------------------------> divTicks
///                          flatTicks
///
/// Below `flatTicks` the surcharge is unchanged, so honest operation — where the fast
/// and deep sources normally disagree by a handful of ticks — is not taxed. Above it
/// the surcharge climbs without bound until the configured ceiling.
///
/// @dev Why this replaced a boolean freeze (appendix §10):
///
///      The previous design froze the hook when the sources disagreed by more than
///      `guardMaxDevTicks`. Freezing means no surcharge on ANY gap of ANY size, so the
///      freeze condition was an off-switch reachable for a measured $7–$21: shove the
///      thin 0.01% reference pool one tick past the tolerance and the mechanism stops.
///      The tolerance could not be tuned out of the problem because it governed two
///      attacks at once — lowering it made the freeze cheaper to trigger, raising it
///      widened the budget for quietly masking a gap underneath it.
///
///      A curve has no state to reach. Every additional tick of manipulation raises the
///      cost of the arbitrage the manipulator is trying to protect, at every level, with
///      no discontinuity to aim at. The attacker's spend buys them a worse price rather
///      than an inert hook.
///
///      Stated cost, not hidden: fast and deep genuinely diverge during real volatility,
///      so honest arbitrageurs closing a real gap in a fast market pay the elevated rate
///      too. That is the price of removing the switch. It is bounded by `maxMultBps` and
///      it is a cost paid by gap-CLOSING flow, which is also the flow the fee-override
///      discount is designed to rebate.
library DivergenceMath {
    uint256 internal constant ONE = 10_000; // 1.00x in basis points

    /// @param divTicks   Disagreement between reference sources, in ticks
    /// @param flatTicks  Disagreement tolerated at 1.00x (the old guardMaxDevTicks)
    /// @param slopeBps   Multiplier bps added per tick of excess above flatTicks
    /// @param maxMultBps Ceiling on the multiplier, in bps. Values below ONE are
    ///                   raised to ONE: a ceiling under 1.00x would let a manipulator
    ///                   REDUCE the surcharge by pushing harder, which reintroduces
    ///                   the off-switch through the config surface.
    /// @return multBps   Multiplier in basis points, always >= ONE
    function multiplierBps(uint24 divTicks, uint24 flatTicks, uint16 slopeBps, uint16 maxMultBps)
        internal
        pure
        returns (uint256 multBps)
    {
        uint256 ceiling = maxMultBps < ONE ? ONE : uint256(maxMultBps);

        if (divTicks <= flatTicks || slopeBps == 0) return ONE;

        // divTicks and flatTicks are uint24, slopeBps uint16: the product is at most
        // 2^24 * 2^16 = 2^40, so no overflow before the ceiling clamp.
        uint256 excess = uint256(divTicks) - uint256(flatTicks);
        multBps = ONE + excess * uint256(slopeBps);

        return multBps > ceiling ? ceiling : multBps;
    }

    /// @notice Clamp a multiplied surcharge into the uint128 the escrow is stored in.
    ///
    /// @param scaled   Surcharge after the multiplier, full uint256 precision
    /// @param notional The swap's input amount — the escrow comes out of it
    /// @return         min(scaled, notional, type(uint128).max)
    ///
    /// @dev Both ceilings are load-bearing, and the second is the non-obvious one.
    ///
    ///      `notional` bounds the take to what the swapper actually put in.
    ///
    ///      `type(uint128).max` exists because `notional` is itself a uint256. Clamping
    ///      only to the notional and casting would let the cast truncate modulo 2^128,
    ///      and truncating a value just above 2^128 yields a NEAR-ZERO surcharge — the
    ///      off-switch this library exists to remove, reachable by making the swap large
    ///      rather than by pushing the reference. Saturating is what keeps
    ///      "no input produces a zero surcharge" true at every magnitude.
    ///
    ///      Saturate rather than revert: reverting a swap is not an available answer on
    ///      the hook path (see the freeze-not-revert principle in SplitV3Reference).
    ///
    ///      Split out of the hook so the uint128 boundary is unit-testable. It is not
    ///      reachable through a swap in the test harness — ERC20 supply would have to
    ///      exceed ~3.4e39 — so an integration test cannot pin it and a mutation that
    ///      deletes the saturation would otherwise survive silently.
    function clampToEscrow(uint256 scaled, uint256 notional) internal pure returns (uint128) {
        uint256 maxTake = notional < type(uint128).max ? notional : type(uint128).max;
        return uint128(scaled > maxTake ? maxTake : scaled);
    }
}
