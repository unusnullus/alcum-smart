// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";

import {IEpochManager} from "./interfaces/IEpochManager.sol";

/**
 * @title EpochManager
 * @notice Manages time-based epochs for organizing trading activities and revenue settlement cycles
 * @dev This contract handles the progression of epochs, which are fixed time periods
 *      used to organize trading activities and revenue settlement cycles. Each epoch
 *      represents a complete cycle of copper trading operations.
 */
contract EpochManager is
    Initializable,
    IEpochManager,
    OwnableUpgradeable,
    AccessControlUpgradeable,
    PausableUpgradeable
{
    /// @notice Role identifier for epoch managers
    bytes32 public constant EPOCH_MANAGER_ROLE = keccak256("EPOCH_MANAGER_ROLE");

    /// @notice Current epoch identifier (starts from 0)
    /// @dev Packed with _epochStart to save storage slot
    uint128 private _currentEpochId;

    /// @notice Timestamp when the current epoch started
    /// @dev Packed with _currentEpochId to save storage slot
    uint128 private _epochStart;

    /// @notice Duration of each epoch in seconds
    uint256 private _epochDuration;

    /// @notice Thrown when epoch duration is zero
    error InvalidEpochDuration();

    /// @notice Thrown when epoch duration exceeds maximum allowed
    error EpochDurationTooLong();

    /// @notice Thrown when trying to advance epoch before it's finished
    error EpochNotFinished();

    /// @notice Thrown when trying to set the same duration
    error SameDuration();

    /**
     * @notice Emitted when a new epoch begins
     * @param epochId The identifier of the new epoch
     * @param start The timestamp when the epoch started
     * @param duration The duration of the epoch in seconds
     */
    event EpochStarted(uint256 indexed epochId, uint256 start, uint256 duration);

    /**
     * @notice Emitted when the epoch duration is updated
     * @param oldDuration The previous epoch duration
     * @param newDuration The new epoch duration
     * @param updatedBy The address that updated the duration
     */
    event EpochDurationUpdated(uint256 oldDuration, uint256 newDuration, address indexed updatedBy);

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /**
     * @notice Initializes the EpochManager contract
     * @dev This function replaces the constructor for upgradeable contracts.
     *      Sets the initial epoch duration.
     *
     * Requirements:
     * - Can only be called once due to initializer modifier
     * - `epochDuration_` must be greater than 0
     * - Caller becomes the owner of the contract
     *
     * @param epochDuration_ Duration of each epoch in seconds
     *
     * @custom:oz-initializer
     */
    function initialize(uint256 epochDuration_) public initializer {
        if (epochDuration_ == 0) revert InvalidEpochDuration();
        if (epochDuration_ > 365 days) revert EpochDurationTooLong();

        __Ownable_init(_msgSender());
        __AccessControl_init();
        __Pausable_init();

        // Grant the deployer the default admin role and epoch manager role
        _grantRole(DEFAULT_ADMIN_ROLE, _msgSender());
        _grantRole(EPOCH_MANAGER_ROLE, _msgSender());

        _epochDuration = epochDuration_;
    }

    /**
     * @notice Advances to the next epoch
     * @dev Only callable by addresses with EPOCH_MANAGER_ROLE. Requires the current epoch to be finished.
     *      This function should be called at the end of each trading cycle to start
     *      the next epoch for new trading activities.
     *
     * Requirements:
     * - Caller must have EPOCH_MANAGER_ROLE
     * - Current epoch must be finished (current time >= epoch start + duration)
     * - Contract must not be paused
     *
     * Effects:
     * - Increments the current epoch ID
     * - Sets the new epoch start time to current block timestamp
     * - Emits an EpochStarted event
     */
    function nextEpoch() external onlyRole(EPOCH_MANAGER_ROLE) whenNotPaused {
        if (block.timestamp < epochStart() + epochDuration()) revert EpochNotFinished();

        _currentEpochId++;
        _epochStart = uint128(block.timestamp);

        emit EpochStarted(_currentEpochId, _epochStart, _epochDuration);
    }

    /**
     * @notice Calculates the time remaining in the current epoch
     * @dev Returns 0 if the epoch has already ended. Used by other contracts
     *      to check if operations are allowed within the current epoch.
     *
     * @return timeLeft The number of seconds remaining in the current epoch
     */
    function timeLeftInEpoch() external view returns (uint256 timeLeft) {
        uint256 epochEndTime = epochStart() + epochDuration();
        if (block.timestamp >= epochEndTime) {
            return 0;
        }
        return epochEndTime - block.timestamp;
    }

    /**
     * @notice Returns the current epoch identifier
     * @dev Epoch IDs start from 0 and increment with each new epoch.
     *      Used by other contracts to track which epoch operations belong to.
     *
     * @return epochId The current epoch ID
     */
    function currentEpochId() external view returns (uint256 epochId) {
        return _currentEpochId;
    }

    /**
     * @notice Returns the timestamp when the current epoch started
     * @dev Used for calculating epoch progress and time remaining.
     *
     * @return startTime The epoch start timestamp in seconds since Unix epoch
     */
    function epochStart() public view returns (uint256 startTime) {
        return _epochStart;
    }

    /**
     * @notice Returns the duration of each epoch in seconds
     * @dev All epochs have the same duration.
     *
     * @return duration The epoch duration in seconds
     */
    function epochDuration() public view returns (uint256 duration) {
        return _epochDuration;
    }

    /**
     * @notice Updates the duration for future epochs
     * @dev Only callable by addresses with EPOCH_MANAGER_ROLE. Does not affect the current epoch.
     *      The new duration will apply to epochs started after this change.
     *
     * Requirements:
     * - Caller must have EPOCH_MANAGER_ROLE
     * - `newDuration` must be greater than 0
     * - `newDuration` must not exceed 365 days
     * - Contract must not be paused
     *
     * @param newDuration The new epoch duration in seconds
     *
     * Emits an {EpochDurationUpdated} event.
     */
    function setEpochDuration(uint256 newDuration) external onlyRole(EPOCH_MANAGER_ROLE) whenNotPaused {
        if (newDuration == 0) revert InvalidEpochDuration();
        if (newDuration > 365 days) revert EpochDurationTooLong();
        if (newDuration == _epochDuration) revert SameDuration();

        uint256 oldDuration = _epochDuration;
        _epochDuration = newDuration;

        emit EpochDurationUpdated(oldDuration, newDuration, _msgSender());
    }

    /**
     * @notice Pauses all contract operations
     * @dev Only callable by the contract owner. Prevents epoch advancement
     *      and other state-changing operations.
     *
     * Requirements:
     * - Caller must be the contract owner
     * - Contract must not already be paused
     */
    function pause() external onlyOwner {
        _pause();
    }

    /**
     * @notice Unpauses all contract operations
     * @dev Only callable by the contract owner. Restores normal functionality.
     *
     * Requirements:
     * - Caller must be the contract owner
     * - Contract must be paused
     */
    function unpause() external onlyOwner {
        _unpause();
    }
}
