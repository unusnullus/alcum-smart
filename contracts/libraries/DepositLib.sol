// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/**
 * @title DepositLib
 * @notice External library for handling deposit operations in Zapper.
 * @dev Keeps Zapper bytecode small by moving deposit management logic here.
 *      Manages deposit lifecycle: creation, removal, approval, and decline.
 */
library DepositLib {
    // ───────────────────────────── STRUCTS ─────────────────────────────

    struct Deposit {
        address user; // originator (payer) for on-chain deposits
        bytes32 depositId; // unique identifier
        uint256 amount; // pending USDC value
        uint256 approvedAmount; // approved USDC value
        bool approved; // approved flag
        // Extended fields for host-to-host external deposits
        address beneficiary; // who will receive xCUP on claim
        address createdBy; // who initiated the deposit (EOA/adapter)
        address claimedBy; // who executed the claim
        bool isExternal; // true if created via external adapter flow
        bytes32 tag; // integration tag/ID for marking
        uint256 approvedCupAmount; // fixed CUP amount approved (for external)
        uint256 priceSnapshot; // price used for approval (for external)
    }

    // ───────────────────────────── EVENTS ─────────────────────────────

    event DepositApproved(bytes32 indexed depositId, uint256 approvedAmount);
    event DepositDeclined(bytes32 indexed depositId, address indexed user, uint256 refundAmount);
    event ProportionalApproval(uint256 totalApproved, uint256 totalDeposited, uint256 proportion);

    // ───────────────────────────── ERRORS ─────────────────────────────

    error DepositNotFound();
    error DepositAlreadyExists();
    error DepositAlreadyApproved();
    error InvalidApprovedAmount();
    error ApprovedAmountExceedsDeposit();
    error InvalidBeneficiary();
    error NotPendingDeposit();
    error NoPendingDeposits();
    error NoValidPendingDeposits();
    error TargetAmountExceedsTotal();
    error NotExternalDeposit();

    // ───────────────────────────── DEPOSIT MANAGEMENT ─────────────────────────────

    /**
     * @notice Removes a deposit ID from the pending deposits array using swap-and-pop pattern
     * @param pendingDepositIds Array of pending deposit IDs
     * @param depositId The deposit ID to remove
     */
    function removePendingDeposit(bytes32[] storage pendingDepositIds, bytes32 depositId) public {
        for (uint256 i = 0; i < pendingDepositIds.length; i++) {
            if (pendingDepositIds[i] == depositId) {
                pendingDepositIds[i] = pendingDepositIds[pendingDepositIds.length - 1];
                pendingDepositIds.pop();
                break;
            }
        }
    }

    /**
     * @notice Removes a deposit ID from a user's personal deposit tracking list
     * @param userDeposits Mapping of user addresses to their deposit IDs
     * @param user The user whose deposit list should be updated
     * @param depositId The deposit ID to remove
     */
    function removeUserDeposit(
        mapping(address => bytes32[]) storage userDeposits,
        address user,
        bytes32 depositId
    ) public {
        bytes32[] storage ids = userDeposits[user];
        for (uint256 i = 0; i < ids.length; i++) {
            if (ids[i] == depositId) {
                ids[i] = ids[ids.length - 1];
                ids.pop();
                break;
            }
        }
    }

    /**
     * @notice Records a new deposit in the system
     * @param deposits Mapping of deposit IDs to deposits
     * @param pendingDepositIds Array of pending deposit IDs
     * @param userDeposits Mapping of user addresses to their deposit IDs
     * @param depositId The unique identifier for the deposit
     * @param amount The amount of the deposit in USDC
     * @param user The user making the deposit
     */
    function recordDeposit(
        mapping(bytes32 => Deposit) storage deposits,
        bytes32[] storage pendingDepositIds,
        mapping(address => bytes32[]) storage userDeposits,
        bytes32 depositId,
        uint256 amount,
        address user
    ) external {
        if (deposits[depositId].user != address(0)) {
            revert DepositAlreadyExists();
        }

        deposits[depositId] = Deposit({
            user: user,
            depositId: depositId,
            amount: amount,
            approvedAmount: 0,
            approved: false,
            beneficiary: address(0),
            createdBy: user,
            claimedBy: address(0),
            isExternal: false,
            tag: bytes32(0),
            approvedCupAmount: 0,
            priceSnapshot: 0
        });
        pendingDepositIds.push(depositId);
        userDeposits[user].push(depositId);
    }

    /**
     * @notice Records a new external deposit for host-to-host integrations
     * @param deposits Mapping of deposit IDs to deposits
     * @param pendingDepositIds Array of pending deposit IDs
     * @param userDeposits Mapping of user addresses to their deposit IDs
     * @param usdcAmount The notional USDC amount for the deposit
     * @param beneficiary_ The address that will receive xCUP tokens upon claim
     * @param tag_ Integration-specific identifier for tracking
     * @param createdBy Who initiated the deposit
     * @param nonce Nonce to ensure uniqueness (incremented by caller if collision occurs)
     * @return depositId The generated unique identifier for this deposit
     */
    function recordExternalDeposit(
        mapping(bytes32 => Deposit) storage deposits,
        bytes32[] storage pendingDepositIds,
        mapping(address => bytes32[]) storage userDeposits,
        uint256 usdcAmount,
        address beneficiary_,
        bytes32 tag_,
        address createdBy,
        uint256 nonce
    ) external returns (bytes32 depositId) {
        if (beneficiary_ == address(0)) {
            revert InvalidBeneficiary();
        }

        // Generate deposit ID with nonce to prevent collisions
        depositId = keccak256(abi.encodePacked(createdBy, block.timestamp, usdcAmount, beneficiary_, tag_, nonce));

        // Check for collision and regenerate if needed (should be extremely rare with nonce)
        // This is a safety check - with nonce, collisions should be virtually impossible
        uint256 attempts = 0;
        while (deposits[depositId].user != address(0) && attempts < 100) {
            // If collision detected, increment nonce and regenerate
            nonce++;
            depositId = keccak256(abi.encodePacked(createdBy, block.timestamp, usdcAmount, beneficiary_, tag_, nonce));
            attempts++;
        }

        // If still collision after 100 attempts, revert (should never happen)
        if (deposits[depositId].user != address(0)) {
            revert DepositAlreadyExists();
        }

        deposits[depositId] = Deposit({
            user: createdBy,
            depositId: depositId,
            amount: usdcAmount,
            approvedAmount: 0,
            approved: false,
            beneficiary: beneficiary_,
            createdBy: createdBy,
            claimedBy: address(0),
            isExternal: true,
            tag: tag_,
            approvedCupAmount: 0,
            priceSnapshot: 0
        });
        pendingDepositIds.push(depositId);
        userDeposits[beneficiary_].push(depositId);
    }

    /**
     * @notice Sets the beneficiary of a pending deposit
     * @param deposits Mapping of deposit IDs to deposits
     * @param depositId The unique identifier of the deposit to update
     * @param beneficiary_ The new beneficiary address
     */
    function setDepositBeneficiary(
        mapping(bytes32 => Deposit) storage deposits,
        bytes32 depositId,
        address beneficiary_
    ) external {
        if (beneficiary_ == address(0)) {
            revert InvalidBeneficiary();
        }
        Deposit storage d = deposits[depositId];
        if (d.user == address(0) || d.approved) {
            revert NotPendingDeposit();
        }
        d.beneficiary = beneficiary_;
    }

    /**
     * @notice Approves a specific deposit for vault entry
     * @param deposits Mapping of deposit IDs to deposits
     * @param depositId The unique identifier of the deposit to approve
     * @param approvedAmount The amount to approve in USDC
     */
    function approveDeposit(
        mapping(bytes32 => Deposit) storage deposits,
        bytes32 depositId,
        uint256 approvedAmount
    ) external {
        Deposit storage deposit = deposits[depositId];

        if (deposit.user == address(0)) {
            revert DepositNotFound();
        }
        if (deposit.approved) {
            revert DepositAlreadyApproved();
        }
        if (approvedAmount == 0) {
            revert InvalidApprovedAmount();
        }
        if (approvedAmount > deposit.amount) {
            revert ApprovedAmountExceedsDeposit();
        }

        deposit.approved = true;
        deposit.approvedAmount = approvedAmount;

        emit DepositApproved(depositId, approvedAmount);
    }

    /**
     * @notice Approves an external deposit with a fixed copper price snapshot
     * @param deposits Mapping of deposit IDs to deposits
     * @param depositId The unique identifier of the external deposit
     * @param approvedUsdc The USDC amount to approve
     * @param price The copper price to use for CUP calculation (with 8 decimals)
     */
    function approveExternalDepositWithPrice(
        mapping(bytes32 => Deposit) storage deposits,
        bytes32 depositId,
        uint256 approvedUsdc,
        uint256 price
    ) external {
        Deposit storage deposit = deposits[depositId];
        if (deposit.user == address(0)) {
            revert DepositNotFound();
        }
        if (!deposit.isExternal) {
            revert NotExternalDeposit();
        }
        if (deposit.approved) {
            revert DepositAlreadyApproved();
        }
        if (approvedUsdc == 0) {
            revert InvalidApprovedAmount();
        }
        if (approvedUsdc > deposit.amount) {
            revert ApprovedAmountExceedsDeposit();
        }
        if (price == 0) {
            revert InvalidApprovedAmount(); // Invalid price
        }

        deposit.approved = true;
        deposit.approvedAmount = approvedUsdc;
        deposit.priceSnapshot = price;
        deposit.approvedCupAmount = (approvedUsdc * (10 ** 8)) / price;

        emit DepositApproved(depositId, approvedUsdc);
    }

    /**
     * @notice Declines a deposit (marks it for refund)
     * @param deposits Mapping of deposit IDs to deposits
     * @param pendingDepositIds Array of pending deposit IDs
     * @param userDeposits Mapping of user addresses to their deposit IDs
     * @param depositId The unique identifier of the deposit to decline
     * @return user The user address whose deposit was declined
     * @return refundAmount The amount to refund
     */
    function declineDeposit(
        mapping(bytes32 => Deposit) storage deposits,
        bytes32[] storage pendingDepositIds,
        mapping(address => bytes32[]) storage userDeposits,
        bytes32 depositId
    ) external returns (address user, uint256 refundAmount) {
        Deposit storage deposit = deposits[depositId];

        if (deposit.user == address(0)) {
            revert DepositNotFound();
        }
        if (deposit.approved) {
            revert DepositAlreadyApproved();
        }

        refundAmount = deposit.amount;
        user = deposit.user;

        delete deposits[depositId];
        removePendingDeposit(pendingDepositIds, depositId);
        removeUserDeposit(userDeposits, user, depositId);

        emit DepositDeclined(depositId, user, refundAmount);
    }

    /**
     * @notice Approves multiple deposits proportionally
     * @param deposits Mapping of deposit IDs to deposits
     * @param pendingDepositIds Array of pending deposit IDs
     * @param targetTotalAmount The total USDC amount to approve across all deposits
     */
    function approveDepositsProportionally(
        mapping(bytes32 => Deposit) storage deposits,
        bytes32[] storage pendingDepositIds,
        uint256 targetTotalAmount
    ) external {
        if (targetTotalAmount == 0) {
            revert InvalidApprovedAmount();
        }
        if (pendingDepositIds.length == 0) {
            revert NoPendingDeposits();
        }

        // Calculate total pending deposits
        uint256 totalPendingAmount;
        uint256 validDeposits;

        for (uint256 i = 0; i < pendingDepositIds.length; i++) {
            Deposit storage deposit = deposits[pendingDepositIds[i]];
            if (deposit.user != address(0) && !deposit.approved) {
                totalPendingAmount += deposit.amount;
                validDeposits++;
            }
        }

        if (totalPendingAmount == 0) {
            revert NoValidPendingDeposits();
        }
        if (targetTotalAmount > totalPendingAmount) {
            revert TargetAmountExceedsTotal();
        }

        // Calculate proportion (scaled by 1e18 for precision)
        uint256 proportion = (targetTotalAmount * 1e18) / totalPendingAmount;

        bytes32 depositId;
        uint256 approvedAmount;

        // Approve deposits proportionally
        for (uint256 i = 0; i < pendingDepositIds.length; i++) {
            depositId = pendingDepositIds[i];
            Deposit storage deposit = deposits[depositId];

            if (deposit.user != address(0) && !deposit.approved) {
                approvedAmount = (deposit.amount * proportion) / 1e18;
                if (approvedAmount > 0) {
                    deposit.approved = true;
                    deposit.approvedAmount = approvedAmount;
                    emit DepositApproved(depositId, approvedAmount);
                }
            }
        }

        emit ProportionalApproval(targetTotalAmount, totalPendingAmount, proportion);
    }

    /**
     * @notice Approves all pending deposits in full
     * @param deposits Mapping of deposit IDs to deposits
     * @param pendingDepositIds Array of pending deposit IDs
     * @return totalApproved The total USDC amount approved across all deposits
     * @return depositsApproved The number of individual deposits that were approved
     */
    function approveAllDeposits(
        mapping(bytes32 => Deposit) storage deposits,
        bytes32[] storage pendingDepositIds
    ) external returns (uint256 totalApproved, uint256 depositsApproved) {
        if (pendingDepositIds.length == 0) {
            revert NoPendingDeposits();
        }

        bytes32 depositId;

        // Approve all pending deposits in full
        for (uint256 i = 0; i < pendingDepositIds.length; i++) {
            depositId = pendingDepositIds[i];
            Deposit storage deposit = deposits[depositId];

            if (deposit.user != address(0) && !deposit.approved) {
                deposit.approved = true;
                deposit.approvedAmount = deposit.amount;
                totalApproved += deposit.amount;
                depositsApproved++;

                emit DepositApproved(depositId, deposit.amount);
            }
        }

        if (depositsApproved == 0) {
            revert NoValidPendingDeposits();
        }

        emit ProportionalApproval(totalApproved, totalApproved, 1e18); // 100% proportion
    }
}
