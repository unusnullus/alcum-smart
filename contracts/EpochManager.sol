// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";

import {IEpochManager} from "./interfaces/IEpochManager.sol";

contract EpochManager is Ownable, IEpochManager {
    uint256 public constant EPOCH_DURATION = 30 days;

    uint128 private _currentEpochId;
    uint128 private _epochStart;

    event EpochStarted(uint256 indexed epochId, uint256 start);

    constructor() Ownable(_msgSender()) {}

    function nextEpoch() external onlyOwner {
        require(block.timestamp >= epochStart() + EPOCH_DURATION, "Epoch not over");

        _currentEpochId++;
        _epochStart = uint128(block.timestamp);

        emit EpochStarted(_currentEpochId, _epochStart);
    }

    function timeLeftInEpoch() external view returns (uint256) {
        if (block.timestamp >= epochStart() + EPOCH_DURATION) return 0;
        return (epochStart() + EPOCH_DURATION) - block.timestamp;
    }

    function currentEpochId() external view returns (uint256) {
        return _currentEpochId;
    }

    function epochStart() public view returns (uint256) {
        return _epochStart;
    }
}
