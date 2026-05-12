// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.24;

import {TokenVesting} from "../TokenVesting.sol";

/**
 * @title ITokenVesting
 * @notice Interface for the TokenVesting contract, used by external callers
 *         (e.g. Zapper) to create vesting schedules for governance tokens.
 */
interface ITokenVesting {
    function createVestingSchedule(
        address _beneficiary,
        uint256 _start,
        uint256 _cliff,
        uint256 _duration,
        uint256 _slicePeriodSeconds,
        bool _revocable,
        uint256 _amount
    ) external;

    function revoke(bytes32 vestingScheduleId) external;

    function withdraw(uint256 amount) external;

    function getToken() external view returns (address);

    function getWithdrawableAmount() external view returns (uint256);

    function getVestingSchedulesCountByBeneficiary(address _beneficiary) external view returns (uint256);

    function getAllVestingSchedulesForHolder(
        address holder
    ) external view returns (bytes32[] memory scheduleIds, TokenVesting.VestingSchedule[] memory schedules);

    function getFullVestingInfoForHolder(
        address holder
    )
        external
        view
        returns (
            bytes32[] memory scheduleIds,
            TokenVesting.VestingSchedule[] memory schedules,
            uint256[] memory releasableAmounts
        );
}
