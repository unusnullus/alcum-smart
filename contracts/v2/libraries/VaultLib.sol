// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/**
 * @title VaultLib
 * @notice Shared data structures and stateless helpers for the multi-vault RWA protocol.
 */
library VaultLib {

    /// @dev RWAVault share token always exposes 6 decimals.
    uint8 internal constant VAULT_SHARE_DECIMALS = 6;

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
        uint256 amount;              // settlement token deposited
        uint256 approvedAmount;      // curator-approved settlement amount (= amount when approved)
        uint256 approvedAssetAmount; // asset-token units calculated at approval price
        uint256 approvedShares;      // vault shares escrowed on router after approve
        uint256 priceSnapshot;       // oracle price (8 dec) locked at approval
        address claimedBy;           // non-zero after claim
        bool    approved;
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
    error MustApproveFullDeposit();
    error RedeemNotFound();
    /// @notice A redeem request with this id already exists (not necessarily approved).
    error RedeemAlreadyExists();
    error RedeemAlreadyApproved();
    error RedeemNotApproved();
    error RedeemAlreadyClaimed();
    error NotRedeemOwner();

    // ─────────────────────────── DECIMAL CONVERSION ─────────────────────────

    /**
     * @notice Convert asset-token units to settlement-token units using an oracle USD price.
     * @dev `assetPrice` uses `oracleDecimals` (typically 8). Result uses `settlementDecimals`.
     */
    function assetToSettlementAmount(
        uint256 assetAmount,
        uint256 assetPrice,
        uint8 assetDecimals,
        uint8 oracleDecimals,
        uint8 settlementDecimals
    ) internal pure returns (uint256) {
        return (assetAmount * assetPrice * 10 ** uint256(settlementDecimals))
            / (10 ** uint256(assetDecimals) * 10 ** uint256(oracleDecimals));
    }

    /**
     * @notice Convert settlement-token units to asset-token units using an oracle USD price.
     * @dev Inverse of {assetToSettlementAmount}.
     */
    function settlementToAssetAmount(
        uint256 settlementAmount,
        uint256 assetPrice,
        uint8 assetDecimals,
        uint8 oracleDecimals,
        uint8 settlementDecimals
    ) internal pure returns (uint256) {
        return (settlementAmount * 10 ** uint256(oracleDecimals) * 10 ** uint256(assetDecimals))
            / (assetPrice * 10 ** uint256(settlementDecimals));
    }

    // ─────────────────────────── DEPOSIT HELPERS ────────────────────────────

    /**
     * @notice Store a pending on-chain zap deposit.
     * @dev Reverts if `depositId` is already used. `depositId` is caller-supplied;
     *      the router should document that clients must use a unique id.
     *      Index maps store 1-based positions for O(1) removal (FIND-020).
     */
    function recordDeposit(
        mapping(bytes32 => Deposit) storage deposits,
        bytes32[] storage pendingIds,
        mapping(bytes32 => uint256) storage pendingIndex,
        mapping(address => bytes32[]) storage userDeposits,
        mapping(address => mapping(bytes32 => uint256)) storage userIndex,
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
            approvedShares:      0,
            priceSnapshot:       0,
            claimedBy:           address(0),
            approved:            false
        });
        pushId(pendingIds, pendingIndex, depositId);
        pushId(userDeposits[user], userIndex[user], depositId);
    }

    /**
     * @notice Curator-approve a zap deposit and lock `approvedAssetAmount`.
     * @dev Uses {settlementToAssetAmount} so asset and settlement ERC-20 decimals may differ.
     */
    function approveDeposit(
        mapping(bytes32 => Deposit) storage deposits,
        bytes32 depositId,
        uint256 approvedAmount,
        uint256 assetPrice,
        uint8   oracleDecimals,
        uint8   assetDecimals,
        uint8   settlementDecimals
    ) internal {
        Deposit storage d = deposits[depositId];
        if (d.user == address(0))  revert DepositNotFound();
        if (d.approved)            revert DepositAlreadyApproved();
        if (approvedAmount == 0 || approvedAmount != d.amount) revert MustApproveFullDeposit();
        if (assetPrice == 0)       revert InvalidApprovedAmount();

        d.approved            = true;
        d.approvedAmount      = approvedAmount;
        d.priceSnapshot       = assetPrice;
        d.approvedAssetAmount = settlementToAssetAmount(
            approvedAmount,
            assetPrice,
            assetDecimals,
            oracleDecimals,
            settlementDecimals
        );
        // FIND-031: integer division can truncate dust deposits to zero asset units.
        if (d.approvedAssetAmount == 0) revert InvalidApprovedAmount();
    }

    // ─────────────────────────── REDEEM HELPERS ─────────────────────────────

    /**
     * @notice Store a queued redemption. Reverts if `redeemId` is already used.
     */
    function recordRedeemRequest(
        mapping(bytes32 => RedeemRequest) storage redeems,
        bytes32[] storage pendingIds,
        mapping(bytes32 => uint256) storage pendingIndex,
        mapping(address => bytes32[]) storage userRedeems,
        mapping(address => mapping(bytes32 => uint256)) storage userIndex,
        bytes32 redeemId,
        address user,
        uint256 shares
    ) internal {
        if (redeems[redeemId].user != address(0)) revert RedeemAlreadyExists();

        redeems[redeemId] = RedeemRequest({
            user:        user,
            shares:      shares,
            tokenAmount: 0,
            approved:    false,
            claimed:     false
        });
        pushId(pendingIds, pendingIndex, redeemId);
        pushId(userRedeems[user], userIndex[user], redeemId);
    }

    // ─────────────────────────── ARRAY HELPERS ──────────────────────────────

    /**
     * @dev Append `id` and record its 1-based index for O(1) removal.
     */
    function pushId(
        bytes32[] storage arr,
        mapping(bytes32 => uint256) storage indexMap,
        bytes32 id
    ) internal {
        arr.push(id);
        indexMap[id] = arr.length;
    }

    /**
     * @dev O(1) swap-and-pop removal using a 1-based index map. No-op if `id` is absent.
     */
    function removeFromArray(
        bytes32[] storage arr,
        mapping(bytes32 => uint256) storage indexMap,
        bytes32 id
    ) internal {
        uint256 idx = indexMap[id];
        if (idx == 0) return;

        uint256 i = idx - 1;
        uint256 last = arr.length - 1;
        if (i != last) {
            bytes32 moved = arr[last];
            arr[i] = moved;
            indexMap[moved] = idx;
        }
        arr.pop();
        delete indexMap[id];
    }

    function removeUserEntry(
        mapping(address => bytes32[]) storage map,
        mapping(address => mapping(bytes32 => uint256)) storage indexMap,
        address user,
        bytes32 id
    ) internal {
        removeFromArray(map[user], indexMap[user], id);
    }
}
