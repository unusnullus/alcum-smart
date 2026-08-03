// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/**
 * @title VaultLib
 * @notice Shared data structures and stateless helpers for the multi-vault RWA protocol.
 */
library VaultLib {

    // ─────────────────────────── STRUCTS ────────────────────────────────────

    /**
     * @notice On-chain record for every vault created by VaultFactory.
     * @dev Stored in VaultRegistry; read by OpenLiquidityRouter, RFQEngine,
     *      and SharedSettlementEngine to resolve per-vault addresses.
     */
    struct VaultRecord {
        address vault;             // RWAVault (ERC-4626) proxy
        address assetToken;        // underlying RWA ERC-20
        address settlementToken;   // settlement token (USDC, USDT, DAI, etc.)
        address capitalFacility;   // CapitalFacility — settlement token buffer with optional yield
        address rfqEngine;         // RFQEngine — T+0 instant redemption
        address assetOracle;       // IAssetOracle — price feed
        address uniswapRouter;     // Uniswap V2 router for price queries
        address epochManager;      // EpochManager — settlement cycle timing (address(0) for epoch-less vaults)
        bool    active;            // false → deposits and redemptions are paused
        address treasury;          // custodian / issuer treasury — appended for upgrade-safe layout
        /// @notice When true, epoch settlement writes NAV `assetInInventory` from the operator-reported
        ///         warehouse amount (including zero). On-vault asset liquidity is never used as inventory.
        /// @dev Only valid for epoch vaults (`epochManager != address(0)`).
        bool    reportedInventoryOnly;
    }

    /// @notice Pending deposit tracked inside OpenLiquidityRouter.
    struct Deposit {
        address user;
        bytes32 depositId;
        uint256 amount;              // USDC deposited
        uint256 approvedAmount;      // curator-approved USDC (≤ amount)
        uint256 approvedAssetAmount; // asset-token units calculated at approval price
        uint256 priceSnapshot;       // oracle price (8 dec) locked at approval
        address beneficiary;         // share recipient (zero → use user)
        address createdBy;
        address claimedBy;
        bool    approved;
        bool    isExternal;
        bytes32 tag;
    }

    /// @notice Queued redemption request (non-RFQ path).
    struct RedeemRequest {
        address user;
        uint256 shares;      // vault shares locked in OpenLiquidityRouter
        uint256 tokenAmount; // curator-approved settlement token payout
        bool    approved;
        bool    claimed;
    }

    // ─────────────────────────── ERRORS ─────────────────────────────────────

    error VaultNotFound(uint256 vaultId);
    error VaultNotActive(uint256 vaultId);
    error DepositNotFound();
    error DepositAlreadyExists();
    error DepositAlreadyApproved();
    error DepositNotApproved();
    error DepositAlreadyClaimed();
    error InvalidApprovedAmount();
    error InvalidBeneficiary();
    error NotExternalDeposit();
    error ExternalDepositRequiresPriceApproval();
    error RedeemNotFound();
    error RedeemAlreadyApproved();
    error RedeemNotApproved();
    error RedeemAlreadyClaimed();
    error NotRedeemOwner();

    // ─────────────────────────── DEPOSIT HELPERS ────────────────────────────

    function recordDeposit(
        mapping(bytes32 => Deposit) storage deposits,
        bytes32[] storage pendingIds,
        mapping(address => bytes32[]) storage userDeposits,
        bytes32 depositId,
        uint256 amount,
        address user
    ) internal {
        if (deposits[depositId].user != address(0)) revert DepositAlreadyExists();

        deposits[depositId] = Deposit({
            user:                user,
            depositId:           depositId,
            amount:              amount,
            approvedAmount:      0,
            approvedAssetAmount: 0,
            priceSnapshot:       0,
            beneficiary:         address(0),
            createdBy:           user,
            claimedBy:           address(0),
            approved:            false,
            isExternal:          false,
            tag:                 bytes32(0)
        });
        pendingIds.push(depositId);
        userDeposits[user].push(depositId);
    }

    function recordExternalDeposit(
        mapping(bytes32 => Deposit) storage deposits,
        bytes32[] storage pendingIds,
        mapping(address => bytes32[]) storage userDeposits,
        uint256 tokenAmount,
        address beneficiary_,
        bytes32 tag_,
        address createdBy,
        uint256 nonce
    ) internal returns (bytes32 depositId) {
        if (beneficiary_ == address(0)) revert InvalidBeneficiary();

        depositId = keccak256(abi.encodePacked(createdBy, block.timestamp, tokenAmount, beneficiary_, tag_, nonce));
        uint256 attempts;
        while (deposits[depositId].user != address(0) && attempts < 100) {
            nonce++;
            depositId = keccak256(abi.encodePacked(createdBy, block.timestamp, tokenAmount, beneficiary_, tag_, nonce));
            attempts++;
        }
        if (deposits[depositId].user != address(0)) revert DepositAlreadyExists();

        deposits[depositId] = Deposit({
            user:                createdBy,
            depositId:           depositId,
            amount:              tokenAmount,
            approvedAmount:      0,
            approvedAssetAmount: 0,
            priceSnapshot:       0,
            beneficiary:         beneficiary_,
            createdBy:           createdBy,
            claimedBy:           address(0),
            approved:            false,
            isExternal:          true,
            tag:                 tag_
        });
        pendingIds.push(depositId);
        userDeposits[beneficiary_].push(depositId);
    }

    function approveDeposit(
        mapping(bytes32 => Deposit) storage deposits,
        bytes32 depositId,
        uint256 approvedAmount,
        uint256 assetPrice,
        uint8   oracleDecimals
    ) internal {
        Deposit storage d = deposits[depositId];
        if (d.user == address(0))  revert DepositNotFound();
        if (d.isExternal)          revert ExternalDepositRequiresPriceApproval();
        if (d.approved)            revert DepositAlreadyApproved();
        if (approvedAmount == 0 || approvedAmount > d.amount) revert InvalidApprovedAmount();
        if (assetPrice == 0)       revert InvalidApprovedAmount();

        d.approved            = true;
        d.approvedAmount      = approvedAmount;
        d.priceSnapshot       = assetPrice;
        d.approvedAssetAmount = (approvedAmount * 10 ** uint256(oracleDecimals)) / assetPrice;
    }

    function approveExternalDeposit(
        mapping(bytes32 => Deposit) storage deposits,
        bytes32 depositId,
        uint256 approvedTokenAmount,
        uint256 assetPrice,
        uint8   oracleDecimals
    ) internal {
        Deposit storage d = deposits[depositId];
        if (d.user == address(0)) revert DepositNotFound();
        if (!d.isExternal)        revert NotExternalDeposit();
        if (d.approved)           revert DepositAlreadyApproved();
        if (approvedTokenAmount == 0 || approvedTokenAmount > d.amount) revert InvalidApprovedAmount();
        if (assetPrice == 0)      revert InvalidApprovedAmount();

        d.approved            = true;
        d.approvedAmount      = approvedTokenAmount;
        d.priceSnapshot       = assetPrice;
        d.approvedAssetAmount = (approvedTokenAmount * 10 ** uint256(oracleDecimals)) / assetPrice;
    }

    // ─────────────────────────── REDEEM HELPERS ─────────────────────────────

    function recordRedeemRequest(
        mapping(bytes32 => RedeemRequest) storage redeems,
        bytes32[] storage pendingIds,
        mapping(address => bytes32[]) storage userRedeems,
        bytes32 redeemId,
        address user,
        uint256 shares
    ) internal {
        if (redeems[redeemId].user != address(0)) revert RedeemAlreadyApproved();

        redeems[redeemId] = RedeemRequest({
            user:        user,
            shares:      shares,
            tokenAmount: 0,
            approved:    false,
            claimed:     false
        });
        pendingIds.push(redeemId);
        userRedeems[user].push(redeemId);
    }

    // ─────────────────────────── ARRAY HELPERS ──────────────────────────────

    /// @dev O(n) removal — acceptable for reasonably-sized pending queues.
    function removeFromArray(bytes32[] storage arr, bytes32 id) internal {
        uint256 len = arr.length;
        for (uint256 i; i < len; i++) {
            if (arr[i] == id) {
                arr[i] = arr[len - 1];
                arr.pop();
                return;
            }
        }
    }

    function removeUserEntry(
        mapping(address => bytes32[]) storage map,
        address user,
        bytes32 id
    ) internal {
        bytes32[] storage arr = map[user];
        uint256 len = arr.length;
        for (uint256 i; i < len; i++) {
            if (arr[i] == id) {
                arr[i] = arr[len - 1];
                arr.pop();
                return;
            }
        }
    }
}
