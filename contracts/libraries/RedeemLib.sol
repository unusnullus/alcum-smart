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

    // ───────────────────────────── ERRORS ─────────────────────────────

    error InvalidRedeemRequest();
    error AlreadyApproved();
    error AlreadyClaimed();
    error NotApproved();
    error NotUser();
    error InvalidAmount();
    error InvalidPrice();
    error InsufficientBalance();

    // ───────────────────────────── REDEEM WORKFLOW ─────────────────────────────

    /**
     * @notice Creates a new redeem request.
     */
    function requestRedeem(mapping(bytes32 => RedeemRequest) storage self, address user, uint256 shares)
        external
        returns (bytes32 redeemId)
    {
        if (user == address(0)) revert InvalidRedeemRequest();
        if (shares == 0) revert InvalidAmount();

        redeemId = keccak256(abi.encodePacked(user, block.timestamp, shares));

        RedeemRequest storage req = self[redeemId];
        if (req.user != address(0)) revert InvalidRedeemRequest();

        self[redeemId] = RedeemRequest({user: user, shares: shares, usdcAmount: 0, approved: false, claimed: false});

        emit RedeemRequested(user, redeemId, shares);
    }

    /**
     * @notice Approves a pending redeem request.
     */
    function approveRedeem(mapping(bytes32 => RedeemRequest) storage self, bytes32 redeemId, uint256 usdcAmount)
        external
    {
        RedeemRequest storage req = self[redeemId];
        if (req.user == address(0)) revert InvalidRedeemRequest();
        if (req.approved) revert AlreadyApproved();
        if (req.claimed) revert AlreadyClaimed();

        req.approved = true;
        req.usdcAmount = usdcAmount;

        emit RedeemApproved(redeemId, req.shares, usdcAmount);
    }

    /**
     * @notice Performs redeem without commission using same logic as Zapper.redeem().
     * @dev User calls this after curator approval. Executes full redeem flow internally.
     * @param self Redeem storage mapping
     * @param redeemId Redeem request ID
     * @param user Address claiming the redeem
     * @param vault ERC4626 vault (xCUP)
     * @param cup CUP token
     * @param usdc USDC token
     * @param silo Silo contract (holding USDC)
     * @param copperPriceConsumer Oracle contract with price() view returning uint256
     * @return usdcToWithdraw The amount of USDC sent to user
     */
    function claimRedeem(
        mapping(bytes32 => RedeemRequest) storage self,
        bytes32 redeemId,
        address user,
        IERC4626 vault,
        IERC20 cup,
        IERC20 usdc,
        address silo,
        address copperPriceConsumer
    ) external returns (uint256 usdcToWithdraw) {
        RedeemRequest storage req = self[redeemId];
        if (req.user == address(0)) revert InvalidRedeemRequest();
        if (req.claimed) revert AlreadyClaimed();
        if (!req.approved) revert NotApproved();
        if (req.user != user) revert NotUser();

        req.claimed = true;

        uint256 sharesToRedeem = req.shares;
        if (sharesToRedeem == 0) revert InvalidAmount();

        //  Check ownership
        uint256 ownedShares = vault.balanceOf(user);
        if (ownedShares < sharesToRedeem) revert InsufficientBalance();

        // Pull xCUP shares from user
        IERC20(address(vault)).safeTransferFrom(user, address(this), sharesToRedeem);

        //  Redeem xCUP → CUP
        vault.approve(address(vault), sharesToRedeem);
        uint256 withdrawnCup = vault.redeem(sharesToRedeem, address(this), address(this));

        //  Get current copper price
        (bool ok, bytes memory data) = copperPriceConsumer.staticcall(abi.encodeWithSignature("price()"));
        require(ok, "Price oracle call failed");
        require(data.length >= 32, "Invalid price data returned");
        uint256 copperPrice = abi.decode(data, (uint256));
        if (copperPrice == 0) revert InvalidPrice();

        //  Convert CUP → USDC (no commission)
        uint256 totalUsdcAmount = (withdrawnCup * copperPrice) / (10 ** 11);

        //  Pull USDC from Silo
        usdc.safeTransferFrom(silo, address(this), totalUsdcAmount);

        if (usdc.balanceOf(address(this)) < totalUsdcAmount) revert InsufficientBalance();

        // Send to user
        usdc.safeTransfer(user, totalUsdcAmount);

        emit RedeemClaimed(user, redeemId, totalUsdcAmount);

        return totalUsdcAmount;
    }

    /**
     * @notice Returns full redeem info.
     */
    function getRedeem(mapping(bytes32 => RedeemRequest) storage self, bytes32 redeemId)
        external
        view
        returns (RedeemRequest memory)
    {
        return self[redeemId];
    }
}
