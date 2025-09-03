// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

interface IEpochManager {
    function currentEpochId() external view returns (uint256);

    function epochStart() external view returns (uint256);

    function epochDuration() external view returns (uint256);

    function nextEpoch() external;

    function timeLeftInEpoch() external view returns (uint256);
}
