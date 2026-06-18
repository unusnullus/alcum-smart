// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/**
 * @title IEpochManager
 * @notice Minimal interface used by SharedSettlementEngine and OpenLiquidityRouter
 *         to read and advance the per-vault settlement cycle.
 */
interface IEpochManager {
    /// @notice Returns the current epoch identifier.
    function currentEpochId() external view returns (uint256);

    /// @notice Advance to the next epoch. Caller must hold EPOCH_MANAGER_ROLE.
    function nextEpoch() external;

    /// @notice Seconds remaining in the current epoch; 0 when epoch has ended.
    function timeLeftInEpoch() external view returns (uint256);
}
