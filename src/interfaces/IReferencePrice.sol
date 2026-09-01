// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {PoolId} from "v4-core/types/PoolId.sol";

interface IReferencePrice {
    /// @notice Read the external reference tick and how much the sources disagree.
    ///
    /// @return refTick  The reference tick from the external source
    /// @return ok       False ONLY on a hard read failure the caller cannot price
    ///                  around: pool unconfigured, or the guard window unreadable.
    ///                  Source disagreement no longer freezes — see divTicks.
    /// @return divTicks Maximum disagreement, in ticks, between the reference sources.
    ///                  Zero when a single source is used or when they agree exactly.
    ///                  The caller prices this rather than switching on it.
    ///
    /// @dev Appendix §10 measured that a boolean freeze on source disagreement is an
    ///      off-switch anyone can reach: pushing the thin fast pool one tick past the
    ///      guard tolerance costs ~$21 and stops ALL capture on gaps of ANY size, and
    ///      no setting of that tolerance closes both the freeze route and the masking
    ///      route (tightening it makes the freeze cheaper; loosening it widens the mask).
    ///      Reporting the divergence instead lets the caller make manipulation
    ///      progressively expensive rather than progressively effective.
    function getRefTick(PoolId id)
        external
        view
        returns (int24 refTick, bool ok, uint24 divTicks);
}
