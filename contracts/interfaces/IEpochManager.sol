// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/**
 * @title IEpochManager
 * @notice Interface for epoch management functionality
 * @dev Defines the standard interface for contracts that manage time-based epochs
 *      for organizing trading activities and revenue settlement cycles.
 */
interface IEpochManager {
    /**
     * @notice Returns the current epoch identifier
     * @dev Epoch IDs start from 0 and increment with each new epoch.
     *      Used by other contracts to track which epoch operations belong to.
     *
     * @return epochId The current epoch ID
     */
    function currentEpochId() external view returns (uint256 epochId);

    /**
     * @notice Returns the timestamp when the current epoch started
     * @dev Used for calculating epoch progress and time remaining.
     *
     * @return startTime The epoch start timestamp in seconds since Unix epoch
     */
    function epochStart() external view returns (uint256 startTime);

    /**
     * @notice Returns the duration of each epoch in seconds
     * @dev All epochs have the same duration. Typically set to 7 days (604800 seconds).
     *
     * @return duration The epoch duration in seconds
     */
    function epochDuration() external view returns (uint256 duration);

    /**
     * @notice Advances to the next epoch
     * @dev Only callable by authorized addresses (typically the contract owner).
     *      Requires the current epoch to be finished before advancing.
     *
     * Requirements:
     * - Current epoch must be finished (current time >= epoch start + duration)
     * - Caller must have appropriate permissions
     */
    function nextEpoch() external;

    /**
     * @notice Calculates the time remaining in the current epoch
     * @dev Returns 0 if the epoch has already ended. Used by other contracts
     *      to check if operations are allowed within the current epoch.
     *
     * @return timeLeft The number of seconds remaining in the current epoch
     */
    function timeLeftInEpoch() external view returns (uint256 timeLeft);
}
