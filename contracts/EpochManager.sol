// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";

import {IEpochManager} from "./interfaces/IEpochManager.sol";

/**
 * @title EpochManager
 * @dev This contract handles the progression of epochs, which are fixed time periods
 *      used to organize trading activities and revenue settlement cycles.
 */
contract EpochManager is Initializable, IEpochManager, OwnableUpgradeable, PausableUpgradeable {
    /// @notice Current epoch identifier (starts from 0)
    uint128 private _currentEpochId;

    /// @notice Timestamp when the current epoch started
    uint128 private _epochStart;

    /// @notice Duration of each epoch in seconds
    uint256 private _epochDuration;

    /**
     * @notice Emitted when a new epoch begins
     * @param epochId The identifier of the new epoch
     * @param start The timestamp when the epoch started
     */
    event EpochStarted(uint256 indexed epochId, uint256 start);

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /**
     * @notice Initializes the EpochManager contract
     * @dev This function replaces the constructor for upgradeable contracts
     * @param epochDuration_ Duration of each epoch in seconds
     */
    function initialize(uint256 epochDuration_) public initializer {
        require(epochDuration_ > 0, "Epoch duration must be greater than 0");

        __Ownable_init(_msgSender());
        __Pausable_init();

        _epochDuration = epochDuration_;
    }

    /**
     * @notice Advances to the next epoch
     * @dev Only callable by the contract owner. Requires the current epoch to be finished
     */
    function nextEpoch() external onlyOwner {
        require(block.timestamp >= epochStart() + epochDuration(), "Epoch not over");

        _currentEpochId++;
        _epochStart = uint128(block.timestamp);

        emit EpochStarted(_currentEpochId, _epochStart);
    }

    /**
     * @notice Calculates the time remaining in the current epoch
     * @dev Returns 0 if the epoch has already ended
     * @return The number of seconds remaining in the current epoch
     */
    function timeLeftInEpoch() external view returns (uint256) {
        if (block.timestamp >= epochStart() + epochDuration()) return 0;
        return (epochStart() + epochDuration()) - block.timestamp;
    }

    /**
     * @notice Returns the current epoch identifier
     * @return The current epoch ID
     */
    function currentEpochId() external view returns (uint256) {
        return _currentEpochId;
    }

    /**
     * @notice Returns the timestamp when the current epoch started
     * @return The epoch start timestamp
     */
    function epochStart() public view returns (uint256) {
        return _epochStart;
    }

    /**
     * @notice Returns the duration of each epoch
     * @return The epoch duration in seconds
     */
    function epochDuration() public view returns (uint256) {
        return _epochDuration;
    }

    /**
     * @notice Pauses all contract operations
     * @dev Only callable by the contract owner
     */
    function pause() external onlyOwner {
        _pause();
    }

    /**
     * @notice Unpauses all contract operations
     * @dev Only callable by the contract owner
     */
    function unpause() external onlyOwner {
        _unpause();
    }
}
