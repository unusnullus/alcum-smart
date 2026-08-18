// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";

import {IEpochManager} from "./interfaces/IEpochManager.sol";

/**
 * @title EpochManager
 * @notice Time-boxed settlement cycle used by vaults that opt into epoch accounting.
 *
 * @dev Each vault that is created with `useEpochs = true` gets its own EpochManager
 *      proxy. The current epoch ends at a fixed `_epochEnd` timestamp. Changing
 *      `_epochDuration` via {setEpochDuration} applies only to epochs started after
 *      the next {nextEpoch} call — it does not move the current epoch boundary.
 *
 *      Role layout:
 *        DEFAULT_ADMIN_ROLE  — vault issuer admin (also initial `owner`)
 *        EPOCH_MANAGER_ROLE  — may call `nextEpoch` and `setEpochDuration`
 */
contract EpochManager is
    Initializable,
    IEpochManager,
    OwnableUpgradeable,
    AccessControlUpgradeable,
    PausableUpgradeable,
    UUPSUpgradeable
{
    bytes32 public constant EPOCH_MANAGER_ROLE = keccak256("EPOCH_MANAGER_ROLE");

    /// @dev Packed with `_epochEnd`.
    uint128 private _currentEpochId;

    /// @dev Unix timestamp when the current epoch ends (exclusive boundary for nextEpoch).
    uint128 private _epochEnd;

    /// @dev Timestamp when the current epoch started.
    uint128 private _epochStart;

    /// @dev Duration applied when the *next* epoch is started via {nextEpoch}.
    uint256 private _epochDuration;

    error InvalidEpochDuration();
    error EpochDurationTooLong();
    error EpochNotFinished();
    error SameDuration();

    event EpochStarted(uint256 indexed epochId, uint256 start, uint256 end, uint256 duration);
    event EpochDurationUpdated(uint256 oldDuration, uint256 newDuration, address indexed updatedBy);

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /**
     * @notice Initializes the EpochManager proxy. Can be called only once.
     * @dev Starts epoch 0 at `block.timestamp` with `_epochEnd = now + epochDuration_`.
     */
    function initialize(uint256 epochDuration_) public initializer {
        if (epochDuration_ == 0) revert InvalidEpochDuration();
        if (epochDuration_ > 365 days) revert EpochDurationTooLong();

        __Ownable_init(_msgSender());
        __AccessControl_init();
        __Pausable_init();
        __UUPSUpgradeable_init();

        _grantRole(DEFAULT_ADMIN_ROLE, _msgSender());
        _grantRole(EPOCH_MANAGER_ROLE, _msgSender());

        _epochDuration = epochDuration_;
        _epochStart = uint128(block.timestamp);
        _epochEnd = uint128(block.timestamp + epochDuration_);

        emit EpochStarted(_currentEpochId, _epochStart, _epochEnd, _epochDuration);
    }

    /// @inheritdoc IEpochManager
    function nextEpoch() external onlyRole(EPOCH_MANAGER_ROLE) whenNotPaused {
        if (block.timestamp < _epochEnd) revert EpochNotFinished();

        _currentEpochId++;
        _epochStart = uint128(block.timestamp);
        _epochEnd = uint128(block.timestamp + _epochDuration);

        emit EpochStarted(_currentEpochId, _epochStart, _epochEnd, _epochDuration);
    }

    /// @inheritdoc IEpochManager
    function timeLeftInEpoch() external view returns (uint256 timeLeft) {
        if (block.timestamp >= _epochEnd) {
            return 0;
        }
        return _epochEnd - block.timestamp;
    }

    /// @inheritdoc IEpochManager
    function currentEpochId() external view returns (uint256 epochId) {
        return _currentEpochId;
    }

    /// @inheritdoc IEpochManager
    function epochStart() public view returns (uint256 startTime) {
        return _epochStart;
    }

    /// @notice Unix timestamp when the current epoch ends.
    function epochEnd() public view returns (uint256 endTime) {
        return _epochEnd;
    }

    /// @inheritdoc IEpochManager
    function epochDuration() public view returns (uint256 duration) {
        return _epochDuration;
    }

    /**
     * @notice Updates the duration for epochs started after the next {nextEpoch} call.
     * @dev Does not change `_epochEnd` for the currently running epoch.
     */
    function setEpochDuration(uint256 newDuration) external onlyRole(EPOCH_MANAGER_ROLE) whenNotPaused {
        if (newDuration == 0) revert InvalidEpochDuration();
        if (newDuration > 365 days) revert EpochDurationTooLong();
        if (newDuration == _epochDuration) revert SameDuration();

        uint256 oldDuration = _epochDuration;
        _epochDuration = newDuration;

        emit EpochDurationUpdated(oldDuration, newDuration, _msgSender());
    }

    function pause() external onlyOwner {
        _pause();
    }

    function unpause() external onlyOwner {
        _unpause();
    }

    function _authorizeUpgrade(address) internal override onlyOwner {}

    uint256[44] private __gap;
}
