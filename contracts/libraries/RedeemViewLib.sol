// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {RedeemLib} from "./RedeemLib.sol";

/**
 * @title RedeemViewLib
 * @notice External library for view functions related to redeem requests in RedeemEngine.
 * @dev Keeps RedeemEngine bytecode small by moving view logic here.
 *      Provides read-only access to redeem request information.
 */
library RedeemViewLib {
    /**
     * @notice Returns complete redeem request information for a given redeem ID
     * @param redeems Mapping of redeem IDs to redeem requests
     * @param redeemId The unique identifier of the redeem request to query
     * @return The complete RedeemRequest struct with all information
     */
    function getRedeem(
        mapping(bytes32 => RedeemLib.RedeemRequest) storage redeems,
        bytes32 redeemId
    ) external view returns (RedeemLib.RedeemRequest memory) {
        return redeems[redeemId];
    }

    /**
     * @notice Returns all pending redeem IDs awaiting curator approval
     * @param pendingRedeemIds Array of pending redeem IDs
     * @return Array of bytes32 redeem IDs currently pending approval
     */
    function getPendingRedeemIds(bytes32[] storage pendingRedeemIds) external view returns (bytes32[] memory) {
        return pendingRedeemIds;
    }

    /**
     * @notice Returns all pending redeem requests with complete information
     * @param redeems Mapping of redeem IDs to redeem requests
     * @param pendingRedeemIds Array of pending redeem IDs
     * @return redeemsArray Array of complete RedeemRequest structs for all pending redeems
     */
    function getPendingRedeems(
        mapping(bytes32 => RedeemLib.RedeemRequest) storage redeems,
        bytes32[] storage pendingRedeemIds
    ) external view returns (RedeemLib.RedeemRequest[] memory redeemsArray) {
        // First, count valid pending redeems
        uint256 validCount = 0;
        for (uint256 i = 0; i < pendingRedeemIds.length; i++) {
            RedeemLib.RedeemRequest storage req = redeems[pendingRedeemIds[i]];
            if (req.user != address(0) && !req.approved) {
                validCount++;
            }
        }

        // Create array with exact size needed
        redeemsArray = new RedeemLib.RedeemRequest[](validCount);
        uint256 currentIndex = 0;

        // Fill array with valid pending redeems
        for (uint256 i = 0; i < pendingRedeemIds.length; i++) {
            bytes32 redeemId = pendingRedeemIds[i];
            RedeemLib.RedeemRequest storage req = redeems[redeemId];

            if (req.user != address(0) && !req.approved) {
                redeemsArray[currentIndex] = req;
                currentIndex++;
            }
        }
    }

    /**
     * @notice Returns all redeem IDs for a given user
     * @param userRedeems Mapping of user addresses to their redeem IDs
     * @param user The user address to query
     * @return Array of bytes32 redeem IDs for the user
     */
    function getUserRedeemIds(
        mapping(address => bytes32[]) storage userRedeems,
        address user
    ) external view returns (bytes32[] memory) {
        return userRedeems[user];
    }

    /**
     * @notice Returns all redeem requests for a given user
     * @param redeems Mapping of redeem IDs to redeem requests
     * @param userRedeems Mapping of user addresses to their redeem IDs
     * @param user The user address to query
     * @return redeemsArray Array of complete RedeemRequest structs for the user
     */
    function getUserRedeems(
        mapping(bytes32 => RedeemLib.RedeemRequest) storage redeems,
        mapping(address => bytes32[]) storage userRedeems,
        address user
    ) external view returns (RedeemLib.RedeemRequest[] memory redeemsArray) {
        bytes32[] storage ids = userRedeems[user];
        redeemsArray = new RedeemLib.RedeemRequest[](ids.length);

        for (uint256 i = 0; i < ids.length; i++) {
            redeemsArray[i] = redeems[ids[i]];
        }
    }

    /**
     * @notice Returns the total shares of all pending redeem requests
     * @param redeems Mapping of redeem IDs to redeem requests
     * @param pendingRedeemIds Array of pending redeem IDs
     * @return totalShares The total shares of pending redeem requests
     */
    function getTotalPendingShares(
        mapping(bytes32 => RedeemLib.RedeemRequest) storage redeems,
        bytes32[] storage pendingRedeemIds
    ) external view returns (uint256 totalShares) {
        for (uint256 i = 0; i < pendingRedeemIds.length; i++) {
            RedeemLib.RedeemRequest storage req = redeems[pendingRedeemIds[i]];
            if (req.user != address(0) && !req.approved) {
                totalShares += req.shares;
            }
        }
    }
}
