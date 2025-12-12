// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/**
 * @title RedeemLib
 * @notice External library for handling user redemption requests in Zapper.
 * @dev Keeps Zapper bytecode small. Same redemption logic as Zapper.redeem(),
 *      but without commission deduction.
 *      Manages 3-phase flow: request → approve → claim.
 */
library RedeemLib {
    using SafeERC20 for IERC20;

    // ───────────────────────────── STRUCTS ─────────────────────────────

    struct RedeemRequest {
        bytes32 redeemId; // unique identifier for the redeem request
        address user; // requester
        uint256 shares; // xCUP shares to redeem
        uint256 usdcAmount; // approved payout
        bool approved; // approved by admin
        bool claimed; // claimed by user
    }

    // ───────────────────────────── EVENTS ─────────────────────────────

    event RedeemRequested(address indexed user, bytes32 indexed redeemId, uint256 shares);
    event RedeemApproved(bytes32 indexed redeemId, uint256 shares, uint256 usdcAmount);
    event RedeemClaimed(address indexed user, bytes32 indexed redeemId, uint256 usdcAmount);
    event RedeemCancelled(bytes32 indexed redeemId, address indexed user, uint256 shares);
    event RedeemDeclined(bytes32 indexed redeemId, address indexed user, uint256 shares);
    event ProportionalApproval(uint256 totalApproved, uint256 totalShares, uint256 proportion);

    // ───────────────────────────── ERRORS ─────────────────────────────

    error InvalidRedeemRequest();
    error RedeemIdAlreadyExists();
    error AlreadyApproved();
    error AlreadyClaimed();
    error NotApproved();
    error NotUser();
    error InvalidAmount();
    error InvalidPrice();
    error InsufficientBalance();
    error RedeemNotFound();
    error RedeemAlreadyApproved();
    error NoPendingRedeems();
    error NoValidPendingRedeems();
    error TargetAmountExceedsTotal();
    error InvalidApprovedAmount();

    // ───────────────────────────── REDEEM WORKFLOW ─────────────────────────────

    /**
     * @notice Creates a new redeem request.
     * @param self Mapping of redeem IDs to redeem requests
     * @param pendingRedeemIds Array of pending redeem IDs
     * @param userRedeems Mapping of user addresses to their redeem IDs
     * @param redeemId The unique identifier for the redeem request (must be unique)
     * @param user The user address requesting the redeem
     * @param shares The number of xCUP shares to redeem
     */
    function requestRedeem(
        mapping(bytes32 => RedeemRequest) storage self,
        bytes32[] storage pendingRedeemIds,
        mapping(address => bytes32[]) storage userRedeems,
        bytes32 redeemId,
        address user,
        uint256 shares
    ) external {
        if (user == address(0)) revert InvalidRedeemRequest();
        if (shares == 0) revert InvalidAmount();

        // Check for collision (redeemId must be unique)
        // Check if redeemId already exists (even if deleted, we check by user address)
        if (self[redeemId].user != address(0)) revert RedeemIdAlreadyExists();

        self[redeemId] = RedeemRequest({
            redeemId: redeemId,
            user: user,
            shares: shares,
            usdcAmount: 0,
            approved: false,
            claimed: false
        });

        // Add to pending list and user's list
        pendingRedeemIds.push(redeemId);
        userRedeems[user].push(redeemId);

        emit RedeemRequested(user, redeemId, shares);
    }

    /**
     * @notice Approves a pending redeem request.
     */
    function approveRedeem(
        mapping(bytes32 => RedeemRequest) storage self,
        bytes32 redeemId,
        uint256 usdcAmount
    ) external {
        RedeemRequest storage req = self[redeemId];
        if (req.user == address(0)) revert InvalidRedeemRequest();
        if (req.approved) revert AlreadyApproved();
        if (req.claimed) revert AlreadyClaimed();

        req.approved = true;
        req.usdcAmount = usdcAmount;

        emit RedeemApproved(redeemId, req.shares, usdcAmount);
    }

    /**
     * @notice Claims an approved redeem request
     * @dev xCUP shares must already be in the contract (transferred during requestRedeem).
     *      CUP tokens are sent directly to Zapper contract.
     * @param self Redeem storage mapping
     * @param redeemId Redeem request ID
     * @param user Address claiming the redeem (must be msg.sender)
     * @param vault ERC4626 vault (xCUP)
     * @param usdc USDC token
     * @param silo Silo contract (holding USDC for redeems)
     * @param zapper Zapper contract address (where CUP tokens are sent)
     * @param copperPriceConsumer Oracle contract with price() view returning uint256
     * @param userRedeems Mapping of user addresses to their redeem IDs (for removal)
     * @return usdcAmount The amount of USDC sent to user
     */
    function claimRedeem(
        mapping(bytes32 => RedeemRequest) storage self,
        bytes32 redeemId,
        address user,
        IERC4626 vault,
        IERC20 usdc,
        address silo,
        address zapper,
        address copperPriceConsumer,
        mapping(address => bytes32[]) storage userRedeems
    ) external returns (uint256 usdcAmount) {
        RedeemRequest storage req = self[redeemId];
        if (req.user == address(0)) revert InvalidRedeemRequest();
        if (req.claimed) revert AlreadyClaimed();
        if (!req.approved) revert NotApproved();
        if (req.user != user) revert NotUser();
        if (req.shares == 0) revert InvalidAmount();

        // Check that contract has the shares (they were transferred during requestRedeem)
        if (vault.balanceOf(address(this)) < req.shares) revert InsufficientBalance();

        req.claimed = true;

        // Redeem xCUP → CUP (shares are already in this contract)
        // CUP tokens are sent directly to Zapper contract
        IERC20(address(vault)).approve(address(vault), req.shares);

        // Get current copper price
        (bool ok, bytes memory data) = copperPriceConsumer.staticcall(abi.encodeWithSignature("price()"));
        require(ok, "Price oracle call failed");
        require(data.length >= 32, "Invalid price data returned");
        uint256 copperPrice = abi.decode(data, (uint256));
        if (copperPrice == 0) revert InvalidPrice();

        // Redeem and calculate USDC amount in one step
        usdcAmount = (vault.redeem(req.shares, zapper, address(this)) * copperPrice) / (10 ** 8);

        // Pull USDC from redeem silo (redeem silo must be pre-funded)
        if (usdc.balanceOf(silo) < usdcAmount) revert InsufficientBalance();
        usdc.safeTransferFrom(silo, address(this), usdcAmount);

        // Send USDC to user (no commission)
        usdc.safeTransfer(user, usdcAmount);

        // Remove from user's list when claimed
        removeUserRedeem(userRedeems, user, redeemId);

        emit RedeemClaimed(user, redeemId, usdcAmount);

        return usdcAmount;
    }

    /**
     * @notice Returns full redeem info.
     */
    function getRedeem(
        mapping(bytes32 => RedeemRequest) storage self,
        bytes32 redeemId
    ) external view returns (RedeemRequest memory) {
        return self[redeemId];
    }

    /**
     * @notice Removes a redeem ID from the pending list
     * @param pendingRedeemIds Array of pending redeem IDs
     * @param redeemId The redeem ID to remove
     */
    function removePendingRedeem(bytes32[] storage pendingRedeemIds, bytes32 redeemId) internal {
        uint256 length = pendingRedeemIds.length;
        for (uint256 i = 0; i < length; i++) {
            if (pendingRedeemIds[i] == redeemId) {
                // Move last element to current position
                pendingRedeemIds[i] = pendingRedeemIds[length - 1];
                pendingRedeemIds.pop();
                return;
            }
        }
    }

    /**
     * @notice Removes a redeem ID from a user's list
     * @param userRedeems Mapping of user addresses to their redeem IDs
     * @param user The user address
     * @param redeemId The redeem ID to remove
     */
    function removeUserRedeem(
        mapping(address => bytes32[]) storage userRedeems,
        address user,
        bytes32 redeemId
    ) internal {
        bytes32[] storage redeems = userRedeems[user];
        uint256 length = redeems.length;
        for (uint256 i = 0; i < length; i++) {
            if (redeems[i] == redeemId) {
                // Move last element to current position
                redeems[i] = redeems[length - 1];
                redeems.pop();
                return;
            }
        }
    }

    /**
     * @notice Cancels a redeem request (user-initiated)
     * @param self Mapping of redeem IDs to redeem requests
     * @param pendingRedeemIds Array of pending redeem IDs
     * @param userRedeems Mapping of user addresses to their redeem IDs
     * @param redeemId The unique identifier of the redeem request to cancel
     * @return user The user address whose redeem was cancelled
     * @return shares The number of shares that were cancelled
     */
    function cancelRedeem(
        mapping(bytes32 => RedeemRequest) storage self,
        bytes32[] storage pendingRedeemIds,
        mapping(address => bytes32[]) storage userRedeems,
        bytes32 redeemId
    ) external returns (address user, uint256 shares) {
        RedeemRequest storage req = self[redeemId];

        if (req.user == address(0)) {
            revert RedeemNotFound();
        }
        if (req.approved) {
            revert RedeemAlreadyApproved();
        }
        if (req.claimed) {
            revert AlreadyClaimed();
        }

        user = req.user;
        shares = req.shares;

        delete self[redeemId];
        removePendingRedeem(pendingRedeemIds, redeemId);
        removeUserRedeem(userRedeems, user, redeemId);

        emit RedeemCancelled(redeemId, user, shares);
    }

    /**
     * @notice Declines a redeem request (curator-initiated)
     * @param self Mapping of redeem IDs to redeem requests
     * @param pendingRedeemIds Array of pending redeem IDs
     * @param userRedeems Mapping of user addresses to their redeem IDs
     * @param redeemId The unique identifier of the redeem request to decline
     * @return user The user address whose redeem was declined
     * @return shares The number of shares that were declined
     */
    function declineRedeem(
        mapping(bytes32 => RedeemRequest) storage self,
        bytes32[] storage pendingRedeemIds,
        mapping(address => bytes32[]) storage userRedeems,
        bytes32 redeemId
    ) external returns (address user, uint256 shares) {
        RedeemRequest storage req = self[redeemId];

        if (req.user == address(0)) {
            revert RedeemNotFound();
        }
        if (req.approved) {
            revert RedeemAlreadyApproved();
        }
        if (req.claimed) {
            revert AlreadyClaimed();
        }

        user = req.user;
        shares = req.shares;

        delete self[redeemId];
        removePendingRedeem(pendingRedeemIds, redeemId);
        removeUserRedeem(userRedeems, user, redeemId);

        emit RedeemDeclined(redeemId, user, shares);
    }

    /**
     * @notice Calculates proportional approval amounts for redeem requests
     * @dev This function only calculates the proportion and approved shares, but doesn't set approved flag.
     *      The caller should set approved flag and usdcAmount based on the calculated approvedShares.
     * @param self Mapping of redeem IDs to redeem requests
     * @param pendingRedeemIds Array of pending redeem IDs
     * @param targetTotalShares The total shares to approve across all redeems
     * @return proportion The proportion (scaled by 1e18) to apply to each redeem
     * @return totalPendingShares The total pending shares before approval
     */
    function calculateProportionalApproval(
        mapping(bytes32 => RedeemRequest) storage self,
        bytes32[] storage pendingRedeemIds,
        uint256 targetTotalShares
    ) external returns (uint256 proportion, uint256 totalPendingShares) {
        if (targetTotalShares == 0) {
            revert InvalidApprovedAmount();
        }
        if (pendingRedeemIds.length == 0) {
            revert NoPendingRedeems();
        }

        // Calculate total pending shares
        uint256 validRedeems;

        for (uint256 i = 0; i < pendingRedeemIds.length; i++) {
            RedeemRequest storage req = self[pendingRedeemIds[i]];
            if (req.user != address(0) && !req.approved) {
                totalPendingShares += req.shares;
                validRedeems++;
            }
        }

        if (totalPendingShares == 0) {
            revert NoValidPendingRedeems();
        }
        if (targetTotalShares > totalPendingShares) {
            revert TargetAmountExceedsTotal();
        }

        // Calculate proportion (scaled by 1e18 for precision)
        proportion = (targetTotalShares * 1e18) / totalPendingShares;

        emit ProportionalApproval(targetTotalShares, totalPendingShares, proportion);
    }

    /**
     * @notice Gets all pending redeem requests for batch processing
     * @param self Mapping of redeem IDs to redeem requests
     * @param pendingRedeemIds Array of pending redeem IDs
     * @return redeemIds Array of redeem IDs that are pending
     * @return totalShares The total shares of all pending redeems
     */
    function getPendingRedeemsForApproval(
        mapping(bytes32 => RedeemRequest) storage self,
        bytes32[] storage pendingRedeemIds
    ) external view returns (bytes32[] memory redeemIds, uint256 totalShares) {
        if (pendingRedeemIds.length == 0) {
            revert NoPendingRedeems();
        }

        // First pass: count valid redeems
        uint256 validCount = 0;
        for (uint256 i = 0; i < pendingRedeemIds.length; i++) {
            RedeemRequest storage req = self[pendingRedeemIds[i]];
            if (req.user != address(0) && !req.approved) {
                validCount++;
                totalShares += req.shares;
            }
        }

        if (validCount == 0) {
            revert NoValidPendingRedeems();
        }

        // Second pass: collect redeem IDs
        redeemIds = new bytes32[](validCount);
        uint256 currentIndex = 0;
        for (uint256 i = 0; i < pendingRedeemIds.length; i++) {
            RedeemRequest storage req = self[pendingRedeemIds[i]];
            if (req.user != address(0) && !req.approved) {
                redeemIds[currentIndex] = pendingRedeemIds[i];
                currentIndex++;
            }
        }
    }
}
