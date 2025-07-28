// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";

contract EpochManager is Ownable {
    uint256 public constant EPOCH_DURATION = 30 days;

    uint128 public currentEpochId;
    uint128 public epochStart;

    event EpochStarted(uint256 indexed epochId, uint256 start);

    constructor() Ownable(_msgSender()) {
        epochStart = uint128(block.timestamp);
        currentEpochId = 1;

        emit EpochStarted(currentEpochId, epochStart);
    }

    function nextEpoch() external onlyOwner {
        require(block.timestamp >= epochStart + EPOCH_DURATION, "Epoch not over");

        currentEpochId++;
        epochStart = uint128(block.timestamp);

        emit EpochStarted(currentEpochId, epochStart);
    }

    function timeLeftInEpoch() external view returns (uint256) {
        if (block.timestamp >= epochStart + EPOCH_DURATION) return 0;
        return (epochStart + EPOCH_DURATION) - block.timestamp;
    }
}
