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
}
