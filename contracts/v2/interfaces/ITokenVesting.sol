// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/**
 * @title ITokenVesting
 * @notice Minimal interface consumed by OpenLiquidityRouter to create vesting
 *         schedules on deposit claim.
 * @dev The caller must hold VESTING_CREATOR role on the target TokenVesting contract
 *      and ensure the contract holds enough tokens to cover the vested amount.
 */
interface ITokenVesting {
    /**
     * @notice Create a linear vesting schedule for a beneficiary.
     * @param beneficiary          Recipient of the vested tokens.
     * @param start                Unix timestamp when vesting begins.
     * @param cliff                Seconds after `start` before any tokens vest.
     * @param duration             Total vesting duration in seconds.
     * @param slicePeriodSeconds   Minimum interval between release periods.
     * @param revocable            Whether the owner may revoke the schedule.
     * @param amount               Total token amount to vest.
     */
    function createVestingSchedule(
        address beneficiary,
        uint256 start,
        uint256 cliff,
        uint256 duration,
        uint256 slicePeriodSeconds,
        bool    revocable,
        uint256 amount
    ) external;

    /// @notice ERC-20 token that this contract vests.
    function getToken() external view returns (address);
}
