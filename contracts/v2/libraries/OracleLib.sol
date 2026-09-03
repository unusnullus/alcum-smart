// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IAssetOracle} from "../interfaces/IAssetOracle.sol";

/**
 * @title OracleLib
 * @notice Shared freshness checks for IAssetOracle (FIND-029).
 */
library OracleLib {
    error StaleOracle(address oracle, uint256 updatedAt, uint256 maxAge, uint256 blockTimestamp);

    /// @dev Reverts when `updatedAt == 0` or age exceeds `maxAge`. `maxAge == 0` disables the check.
    function requireFresh(address oracle, uint256 maxAge) internal view {
        if (maxAge == 0) return;
        uint256 updatedAt = IAssetOracle(oracle).updatedAt();
        if (updatedAt == 0 || block.timestamp > updatedAt + maxAge) {
            revert StaleOracle(oracle, updatedAt, maxAge, block.timestamp);
        }
    }
}
