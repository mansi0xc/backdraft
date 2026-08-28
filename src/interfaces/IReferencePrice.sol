// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {PoolId} from "v4-core/types/PoolId.sol";

interface IReferencePrice {
    /// @return refTick The reference tick from the external v3 source
    /// @return ok      False when the guard fires — caller must treat as frozen
    function getRefTick(PoolId id) external view returns (int24 refTick, bool ok);
}
