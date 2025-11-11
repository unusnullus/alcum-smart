// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test, console} from "forge-std/Test.sol";
import {DepositLib} from "../contracts/libraries/DepositLib.sol";

/**
 * @title TestContract
 * @notice Test contract that uses DepositLib to test library functions
 */
contract TestContract {
    using DepositLib for mapping(bytes32 => DepositLib.Deposit);

    mapping(bytes32 => DepositLib.Deposit) public deposits;
    bytes32[] public pendingDepositIds;
    mapping(address => bytes32[]) public userDeposits;

    function recordDeposit(bytes32 depositId, uint256 amount, address user) external {
        DepositLib.recordDeposit(deposits, pendingDepositIds, userDeposits, depositId, amount, user);
    }

    mapping(address => uint256) private nonces;

    function recordExternalDeposit(uint256 usdcAmount, address beneficiary_, bytes32 tag_) external returns (bytes32) {
        uint256 nonce = nonces[msg.sender]++;
        return
            DepositLib.recordExternalDeposit(
                deposits,
                pendingDepositIds,
                userDeposits,
                usdcAmount,
                beneficiary_,
                tag_,
                msg.sender,
                nonce
            );
    }

    function removePendingDeposit(bytes32 depositId) external {
        DepositLib.removePendingDeposit(pendingDepositIds, depositId);
    }

    function removeUserDeposit(address user, bytes32 depositId) external {
        DepositLib.removeUserDeposit(userDeposits, user, depositId);
    }

    function setDepositBeneficiary(bytes32 depositId, address beneficiary_) external {
        DepositLib.setDepositBeneficiary(deposits, depositId, beneficiary_);
    }

    function approveDeposit(bytes32 depositId, uint256 approvedAmount) external {
        DepositLib.approveDeposit(deposits, depositId, approvedAmount);
    }

    function approveExternalDepositWithPrice(bytes32 depositId, uint256 approvedUsdc, uint256 price) external {
        DepositLib.approveExternalDepositWithPrice(deposits, depositId, approvedUsdc, price);
    }

    function declineDeposit(bytes32 depositId) external returns (address user, uint256 refundAmount) {
        return DepositLib.declineDeposit(deposits, pendingDepositIds, userDeposits, depositId);
    }

    function approveDepositsProportionally(uint256 targetTotalAmount) external {
        DepositLib.approveDepositsProportionally(deposits, pendingDepositIds, targetTotalAmount);
    }

    function approveAllDeposits() external returns (uint256 totalApproved, uint256 depositsApproved) {
        return DepositLib.approveAllDeposits(deposits, pendingDepositIds);
    }

    function getDeposit(bytes32 depositId) external view returns (DepositLib.Deposit memory) {
        return deposits[depositId];
    }

    function getPendingDepositIds() external view returns (bytes32[] memory) {
        return pendingDepositIds;
    }

    function getUserDepositIds(address user) external view returns (bytes32[] memory) {
        return userDeposits[user];
    }
}

contract DepositLibTest is Test {
    TestContract public testContract;
    address public user1;
    address public user2;
    address public user3;
    address public beneficiary1;

    function setUp() public {
        testContract = new TestContract();
        user1 = makeAddr("user1");
        user2 = makeAddr("user2");
        user3 = makeAddr("user3");
        beneficiary1 = makeAddr("beneficiary1");
    }

    // ───────────────────────────── RECORD DEPOSIT TESTS ─────────────────────────────

    function testRecordDeposit() public {
        bytes32 depositId = keccak256("test1");
        uint256 amount = 1000 * 10 ** 6;

        testContract.recordDeposit(depositId, amount, user1);

        DepositLib.Deposit memory deposit = testContract.getDeposit(depositId);
        assertEq(deposit.user, user1);
        assertEq(deposit.amount, amount);
        assertEq(deposit.approvedAmount, 0);
        assertFalse(deposit.approved);
        assertFalse(deposit.isExternal);
        assertEq(deposit.beneficiary, address(0));

        bytes32[] memory pendingIds = testContract.getPendingDepositIds();
        assertEq(pendingIds.length, 1);
        assertEq(pendingIds[0], depositId);

        bytes32[] memory userDepositIds = testContract.getUserDepositIds(user1);
        assertEq(userDepositIds.length, 1);
        assertEq(userDepositIds[0], depositId);
    }

    function testRecordDepositDuplicateId() public {
        bytes32 depositId = keccak256("test1");
        uint256 amount = 1000 * 10 ** 6;

        testContract.recordDeposit(depositId, amount, user1);

        vm.expectRevert(DepositLib.DepositAlreadyExists.selector);
        testContract.recordDeposit(depositId, amount, user2);
    }

    function testRecordExternalDeposit() public {
        uint256 amount = 1000 * 10 ** 6;
        bytes32 tag = keccak256("tag1");

        bytes32 depositId = testContract.recordExternalDeposit(amount, beneficiary1, tag);

        DepositLib.Deposit memory deposit = testContract.getDeposit(depositId);
        assertEq(deposit.user, address(this));
        assertEq(deposit.amount, amount);
        assertEq(deposit.beneficiary, beneficiary1);
        assertTrue(deposit.isExternal);
        assertEq(deposit.tag, tag);
        assertEq(deposit.createdBy, address(this));

        bytes32[] memory userDepositIds = testContract.getUserDepositIds(beneficiary1);
        assertEq(userDepositIds.length, 1);
        assertEq(userDepositIds[0], depositId);
    }

    function testRecordExternalDepositInvalidBeneficiary() public {
        uint256 amount = 1000 * 10 ** 6;
        bytes32 tag = keccak256("tag1");

        vm.expectRevert(DepositLib.InvalidBeneficiary.selector);
        testContract.recordExternalDeposit(amount, address(0), tag);
    }

    // ───────────────────────────── REMOVE DEPOSIT TESTS ─────────────────────────────

    function testRemovePendingDeposit() public {
        bytes32 depositId1 = keccak256("test1");
        bytes32 depositId2 = keccak256("test2");
        bytes32 depositId3 = keccak256("test3");

        testContract.recordDeposit(depositId1, 1000, user1);
        testContract.recordDeposit(depositId2, 2000, user2);
        testContract.recordDeposit(depositId3, 3000, user3);

        bytes32[] memory pendingIds = testContract.getPendingDepositIds();
        assertEq(pendingIds.length, 3);

        testContract.removePendingDeposit(depositId2);

        pendingIds = testContract.getPendingDepositIds();
        assertEq(pendingIds.length, 2);
        // Order may change due to swap-and-pop
        bool found1 = false;
        bool found3 = false;
        for (uint256 i = 0; i < pendingIds.length; i++) {
            if (pendingIds[i] == depositId1) found1 = true;
            if (pendingIds[i] == depositId3) found3 = true;
        }
        assertTrue(found1);
        assertTrue(found3);
    }

    function testRemoveUserDeposit() public {
        bytes32 depositId1 = keccak256("test1");
        bytes32 depositId2 = keccak256("test2");

        testContract.recordDeposit(depositId1, 1000, user1);
        testContract.recordDeposit(depositId2, 2000, user1);

        bytes32[] memory userDepositIds = testContract.getUserDepositIds(user1);
        assertEq(userDepositIds.length, 2);

        testContract.removeUserDeposit(user1, depositId1);

        userDepositIds = testContract.getUserDepositIds(user1);
        assertEq(userDepositIds.length, 1);
        assertEq(userDepositIds[0], depositId2);
    }

    // ───────────────────────────── SET BENEFICIARY TESTS ─────────────────────────────

    function testSetDepositBeneficiary() public {
        uint256 amount = 1000 * 10 ** 6;
        bytes32 tag = keccak256("tag1");
        address newBeneficiary = makeAddr("newBeneficiary");

        bytes32 depositId = testContract.recordExternalDeposit(amount, beneficiary1, tag);

        testContract.setDepositBeneficiary(depositId, newBeneficiary);

        DepositLib.Deposit memory deposit = testContract.getDeposit(depositId);
        assertEq(deposit.beneficiary, newBeneficiary);
    }

    function testSetDepositBeneficiaryInvalidBeneficiary() public {
        uint256 amount = 1000 * 10 ** 6;
        bytes32 tag = keccak256("tag1");

        bytes32 depositId = testContract.recordExternalDeposit(amount, beneficiary1, tag);

        vm.expectRevert(DepositLib.InvalidBeneficiary.selector);
        testContract.setDepositBeneficiary(depositId, address(0));
    }

    function testSetDepositBeneficiaryNotPending() public {
        bytes32 depositId = keccak256("test1");
        uint256 amount = 1000 * 10 ** 6;
        address newBeneficiary = makeAddr("newBeneficiary");

        testContract.recordDeposit(depositId, amount, user1);
        testContract.approveDeposit(depositId, amount);

        vm.expectRevert(DepositLib.NotPendingDeposit.selector);
        testContract.setDepositBeneficiary(depositId, newBeneficiary);
    }

    // ───────────────────────────── APPROVE DEPOSIT TESTS ─────────────────────────────

    function testApproveDeposit() public {
        bytes32 depositId = keccak256("test1");
        uint256 amount = 1000 * 10 ** 6;
        uint256 approvedAmount = 800 * 10 ** 6;

        testContract.recordDeposit(depositId, amount, user1);
        testContract.approveDeposit(depositId, approvedAmount);

        DepositLib.Deposit memory deposit = testContract.getDeposit(depositId);
        assertTrue(deposit.approved);
        assertEq(deposit.approvedAmount, approvedAmount);
    }

    function testApproveDepositNotFound() public {
        bytes32 depositId = keccak256("nonexistent");

        vm.expectRevert(DepositLib.DepositNotFound.selector);
        testContract.approveDeposit(depositId, 1000);
    }

    function testApproveDepositAlreadyApproved() public {
        bytes32 depositId = keccak256("test1");
        uint256 amount = 1000 * 10 ** 6;

        testContract.recordDeposit(depositId, amount, user1);
        testContract.approveDeposit(depositId, amount);

        vm.expectRevert(DepositLib.DepositAlreadyApproved.selector);
        testContract.approveDeposit(depositId, amount);
    }

    function testApproveDepositInvalidAmount() public {
        bytes32 depositId = keccak256("test1");
        uint256 amount = 1000 * 10 ** 6;

        testContract.recordDeposit(depositId, amount, user1);

        vm.expectRevert(DepositLib.InvalidApprovedAmount.selector);
        testContract.approveDeposit(depositId, 0);
    }

    function testApproveDepositExceedsAmount() public {
        bytes32 depositId = keccak256("test1");
        uint256 amount = 1000 * 10 ** 6;

        testContract.recordDeposit(depositId, amount, user1);

        vm.expectRevert(DepositLib.ApprovedAmountExceedsDeposit.selector);
        testContract.approveDeposit(depositId, amount + 1);
    }

    function testApproveExternalDepositWithPrice() public {
        uint256 amount = 1000 * 10 ** 6;
        bytes32 tag = keccak256("tag1");
        uint256 price = 450000000; // $4.50 with 8 decimals
        uint256 approvedUsdc = 800 * 10 ** 6;

        bytes32 depositId = testContract.recordExternalDeposit(amount, beneficiary1, tag);
        testContract.approveExternalDepositWithPrice(depositId, approvedUsdc, price);

        DepositLib.Deposit memory deposit = testContract.getDeposit(depositId);
        assertTrue(deposit.approved);
        assertEq(deposit.approvedAmount, approvedUsdc);
        assertEq(deposit.priceSnapshot, price);
        assertEq(deposit.approvedCupAmount, (approvedUsdc * (10 ** 8)) / price);
    }

    function testApproveExternalDepositWithPriceNotExternal() public {
        bytes32 depositId = keccak256("test1");
        uint256 amount = 1000 * 10 ** 6;
        uint256 price = 450000000;

        testContract.recordDeposit(depositId, amount, user1);

        vm.expectRevert(DepositLib.NotExternalDeposit.selector);
        testContract.approveExternalDepositWithPrice(depositId, amount, price);
    }

    function testApproveExternalDepositWithPriceInvalidPrice() public {
        uint256 amount = 1000 * 10 ** 6;
        bytes32 tag = keccak256("tag1");

        bytes32 depositId = testContract.recordExternalDeposit(amount, beneficiary1, tag);

        vm.expectRevert(DepositLib.InvalidApprovedAmount.selector);
        testContract.approveExternalDepositWithPrice(depositId, amount, 0);
    }

    // ───────────────────────────── DECLINE DEPOSIT TESTS ─────────────────────────────

    function testDeclineDeposit() public {
        bytes32 depositId = keccak256("test1");
        uint256 amount = 1000 * 10 ** 6;

        testContract.recordDeposit(depositId, amount, user1);

        (address user, uint256 refundAmount) = testContract.declineDeposit(depositId);

        assertEq(user, user1);
        assertEq(refundAmount, amount);

        DepositLib.Deposit memory deposit = testContract.getDeposit(depositId);
        assertEq(deposit.user, address(0));

        bytes32[] memory pendingIds = testContract.getPendingDepositIds();
        assertEq(pendingIds.length, 0);

        bytes32[] memory userDepositIds = testContract.getUserDepositIds(user1);
        assertEq(userDepositIds.length, 0);
    }

    function testDeclineDepositNotFound() public {
        bytes32 depositId = keccak256("nonexistent");

        vm.expectRevert(DepositLib.DepositNotFound.selector);
        testContract.declineDeposit(depositId);
    }

    function testDeclineDepositAlreadyApproved() public {
        bytes32 depositId = keccak256("test1");
        uint256 amount = 1000 * 10 ** 6;

        testContract.recordDeposit(depositId, amount, user1);
        testContract.approveDeposit(depositId, amount);

        vm.expectRevert(DepositLib.DepositAlreadyApproved.selector);
        testContract.declineDeposit(depositId);
    }

    // ───────────────────────────── PROPORTIONAL APPROVAL TESTS ─────────────────────────────

    function testApproveDepositsProportionally() public {
        bytes32 depositId1 = keccak256("test1");
        bytes32 depositId2 = keccak256("test2");
        bytes32 depositId3 = keccak256("test3");

        testContract.recordDeposit(depositId1, 1000 * 10 ** 6, user1);
        testContract.recordDeposit(depositId2, 2000 * 10 ** 6, user2);
        testContract.recordDeposit(depositId3, 3000 * 10 ** 6, user3);

        // Approve 50% of total (3000 out of 6000)
        uint256 targetAmount = 3000 * 10 ** 6;
        testContract.approveDepositsProportionally(targetAmount);

        DepositLib.Deposit memory deposit1 = testContract.getDeposit(depositId1);
        DepositLib.Deposit memory deposit2 = testContract.getDeposit(depositId2);
        DepositLib.Deposit memory deposit3 = testContract.getDeposit(depositId3);

        assertTrue(deposit1.approved);
        assertTrue(deposit2.approved);
        assertTrue(deposit3.approved);

        // Each should get 50% of their amount
        assertEq(deposit1.approvedAmount, 500 * 10 ** 6);
        assertEq(deposit2.approvedAmount, 1000 * 10 ** 6);
        assertEq(deposit3.approvedAmount, 1500 * 10 ** 6);
    }

    function testApproveDepositsProportionallyInvalidAmount() public {
        vm.expectRevert(DepositLib.InvalidApprovedAmount.selector);
        testContract.approveDepositsProportionally(0);
    }

    function testApproveDepositsProportionallyNoDeposits() public {
        vm.expectRevert(DepositLib.NoPendingDeposits.selector);
        testContract.approveDepositsProportionally(1000);
    }

    function testApproveDepositsProportionallyExceedsTotal() public {
        bytes32 depositId = keccak256("test1");
        testContract.recordDeposit(depositId, 1000 * 10 ** 6, user1);

        vm.expectRevert(DepositLib.TargetAmountExceedsTotal.selector);
        testContract.approveDepositsProportionally(2000 * 10 ** 6);
    }

    // ───────────────────────────── APPROVE ALL DEPOSITS TESTS ─────────────────────────────

    function testApproveAllDeposits() public {
        bytes32 depositId1 = keccak256("test1");
        bytes32 depositId2 = keccak256("test2");
        bytes32 depositId3 = keccak256("test3");

        testContract.recordDeposit(depositId1, 1000 * 10 ** 6, user1);
        testContract.recordDeposit(depositId2, 2000 * 10 ** 6, user2);
        testContract.recordDeposit(depositId3, 3000 * 10 ** 6, user3);

        (uint256 totalApproved, uint256 depositsApproved) = testContract.approveAllDeposits();

        assertEq(totalApproved, 6000 * 10 ** 6);
        assertEq(depositsApproved, 3);

        DepositLib.Deposit memory deposit1 = testContract.getDeposit(depositId1);
        DepositLib.Deposit memory deposit2 = testContract.getDeposit(depositId2);
        DepositLib.Deposit memory deposit3 = testContract.getDeposit(depositId3);

        assertTrue(deposit1.approved);
        assertTrue(deposit2.approved);
        assertTrue(deposit3.approved);

        assertEq(deposit1.approvedAmount, 1000 * 10 ** 6);
        assertEq(deposit2.approvedAmount, 2000 * 10 ** 6);
        assertEq(deposit3.approvedAmount, 3000 * 10 ** 6);
    }

    function testApproveAllDepositsNoDeposits() public {
        vm.expectRevert(DepositLib.NoPendingDeposits.selector);
        testContract.approveAllDeposits();
    }

    function testApproveAllDepositsWithApprovedDeposit() public {
        bytes32 depositId1 = keccak256("test1");
        bytes32 depositId2 = keccak256("test2");

        testContract.recordDeposit(depositId1, 1000 * 10 ** 6, user1);
        testContract.recordDeposit(depositId2, 2000 * 10 ** 6, user2);

        // Approve first deposit
        testContract.approveDeposit(depositId1, 1000 * 10 ** 6);

        // Approve all should only approve the second one
        (uint256 totalApproved, uint256 depositsApproved) = testContract.approveAllDeposits();

        assertEq(totalApproved, 2000 * 10 ** 6);
        assertEq(depositsApproved, 1);
    }
}
