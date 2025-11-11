// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {DepositLib} from "./DepositLib.sol";

/**
 * @title DepositViewLib
 * @notice External library for view functions related to deposits in Zapper.
 * @dev Keeps Zapper bytecode small by moving view logic here.
 *      Provides read-only access to deposit information.
 */
library DepositViewLib {
    /**
     * @notice Returns complete deposit information for a given deposit ID
     * @param deposits Mapping of deposit IDs to deposits
     * @param depositId The unique identifier of the deposit to query
     * @return The complete Deposit struct with all information
     */
    function getDeposit(
        mapping(bytes32 => DepositLib.Deposit) storage deposits,
        bytes32 depositId
    ) external view returns (DepositLib.Deposit memory) {
        return deposits[depositId];
    }

    /**
     * @notice Returns all pending deposit IDs awaiting curator approval
     * @param pendingDepositIds Array of pending deposit IDs
     * @return Array of bytes32 deposit IDs currently pending approval
     */
    function getPendingDepositIds(bytes32[] storage pendingDepositIds) external view returns (bytes32[] memory) {
        return pendingDepositIds;
    }

    /**
     * @notice Returns all pending deposits with complete information
     * @param deposits Mapping of deposit IDs to deposits
     * @param pendingDepositIds Array of pending deposit IDs
     * @return depositsArray Array of complete Deposit structs for all pending deposits
     */
    function getPendingDeposits(
        mapping(bytes32 => DepositLib.Deposit) storage deposits,
        bytes32[] storage pendingDepositIds
    ) external view returns (DepositLib.Deposit[] memory depositsArray) {
        // First, count valid pending deposits
        uint256 validCount = 0;
        for (uint256 i = 0; i < pendingDepositIds.length; i++) {
            DepositLib.Deposit storage deposit = deposits[pendingDepositIds[i]];
            if (deposit.user != address(0) && !deposit.approved) {
                validCount++;
            }
        }

        // Create array with exact size needed
        depositsArray = new DepositLib.Deposit[](validCount);
        uint256 currentIndex = 0;

        // Fill array with valid pending deposits
        for (uint256 i = 0; i < pendingDepositIds.length; i++) {
            bytes32 depositId = pendingDepositIds[i];
            DepositLib.Deposit storage deposit = deposits[depositId];

            if (deposit.user != address(0) && !deposit.approved) {
                depositsArray[currentIndex] = deposit;
                currentIndex++;
            }
        }
    }

    /**
     * @notice Returns all deposit IDs for a given user
     * @param userDeposits Mapping of user addresses to their deposit IDs
     * @param user The user address to query
     * @return Array of bytes32 deposit IDs for the user
     */
    function getUserDepositIds(
        mapping(address => bytes32[]) storage userDeposits,
        address user
    ) external view returns (bytes32[] memory) {
        return userDeposits[user];
    }

    /**
     * @notice Returns all deposits for a given user
     * @param deposits Mapping of deposit IDs to deposits
     * @param userDeposits Mapping of user addresses to their deposit IDs
     * @param user The user address to query
     * @return depositsArray Array of complete Deposit structs for the user
     */
    function getUserDeposits(
        mapping(bytes32 => DepositLib.Deposit) storage deposits,
        mapping(address => bytes32[]) storage userDeposits,
        address user
    ) external view returns (DepositLib.Deposit[] memory depositsArray) {
        bytes32[] storage ids = userDeposits[user];
        depositsArray = new DepositLib.Deposit[](ids.length);

        for (uint256 i = 0; i < ids.length; i++) {
            depositsArray[i] = deposits[ids[i]];
        }
    }

    /**
     * @notice Returns the total amount of all pending deposits
     * @param deposits Mapping of deposit IDs to deposits
     * @param pendingDepositIds Array of pending deposit IDs
     * @return totalAmount The total amount of pending deposits in USDC
     */
    function getTotalPendingAmount(
        mapping(bytes32 => DepositLib.Deposit) storage deposits,
        bytes32[] storage pendingDepositIds
    ) external view returns (uint256 totalAmount) {
        for (uint256 i = 0; i < pendingDepositIds.length; i++) {
            DepositLib.Deposit storage deposit = deposits[pendingDepositIds[i]];
            if (deposit.user != address(0) && !deposit.approved) {
                totalAmount += deposit.amount;
            }
        }
    }
}
