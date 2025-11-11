// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test, console} from "forge-std/Test.sol";
import {DepositViewLib} from "../contracts/libraries/DepositViewLib.sol";
import {DepositLib} from "../contracts/libraries/DepositLib.sol";

/**
 * @title TestContract
 * @notice Test contract that uses DepositViewLib to test library functions
 */
contract TestContract {
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

    function approveDeposit(bytes32 depositId, uint256 approvedAmount) external {
        DepositLib.approveDeposit(deposits, depositId, approvedAmount);
    }

    function getDeposit(bytes32 depositId) external view returns (DepositLib.Deposit memory) {
        return DepositViewLib.getDeposit(deposits, depositId);
    }

    function getPendingDepositIds() external view returns (bytes32[] memory) {
        return DepositViewLib.getPendingDepositIds(pendingDepositIds);
    }

    function getPendingDeposits() external view returns (DepositLib.Deposit[] memory) {
        return DepositViewLib.getPendingDeposits(deposits, pendingDepositIds);
    }

    function getUserDepositIds(address user) external view returns (bytes32[] memory) {
        return DepositViewLib.getUserDepositIds(userDeposits, user);
    }

    function getUserDeposits(address user) external view returns (DepositLib.Deposit[] memory) {
        return DepositViewLib.getUserDeposits(deposits, userDeposits, user);
    }

    function getTotalPendingAmount() external view returns (uint256) {
        return DepositViewLib.getTotalPendingAmount(deposits, pendingDepositIds);
    }
}

contract DepositViewLibTest is Test {
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

    // ───────────────────────────── GET DEPOSIT TESTS ─────────────────────────────

    function testGetDeposit() public {
        bytes32 depositId = keccak256("test1");
        uint256 amount = 1000 * 10 ** 6;

        testContract.recordDeposit(depositId, amount, user1);

        DepositLib.Deposit memory deposit = testContract.getDeposit(depositId);
        assertEq(deposit.user, user1);
        assertEq(deposit.amount, amount);
        assertEq(deposit.depositId, depositId);
    }

    function testGetDepositNotFound() public {
        bytes32 depositId = keccak256("nonexistent");

        DepositLib.Deposit memory deposit = testContract.getDeposit(depositId);
        assertEq(deposit.user, address(0));
        assertEq(deposit.amount, 0);
    }

    // ───────────────────────────── GET PENDING DEPOSIT IDS TESTS ─────────────────────────────

    function testGetPendingDepositIds() public {
        bytes32 depositId1 = keccak256("test1");
        bytes32 depositId2 = keccak256("test2");

        testContract.recordDeposit(depositId1, 1000, user1);
        testContract.recordDeposit(depositId2, 2000, user2);

        bytes32[] memory pendingIds = testContract.getPendingDepositIds();
        assertEq(pendingIds.length, 2);
        assertTrue(pendingIds[0] == depositId1 || pendingIds[0] == depositId2);
        assertTrue(pendingIds[1] == depositId1 || pendingIds[1] == depositId2);
    }

    function testGetPendingDepositIdsEmpty() public {
        bytes32[] memory pendingIds = testContract.getPendingDepositIds();
        assertEq(pendingIds.length, 0);
    }

    // ───────────────────────────── GET PENDING DEPOSITS TESTS ─────────────────────────────

    function testGetPendingDeposits() public {
        bytes32 depositId1 = keccak256("test1");
        bytes32 depositId2 = keccak256("test2");

        testContract.recordDeposit(depositId1, 1000, user1);
        testContract.recordDeposit(depositId2, 2000, user2);

        DepositLib.Deposit[] memory deposits = testContract.getPendingDeposits();
        assertEq(deposits.length, 2);

        bool found1 = false;
        bool found2 = false;
        for (uint256 i = 0; i < deposits.length; i++) {
            if (deposits[i].depositId == depositId1) found1 = true;
            if (deposits[i].depositId == depositId2) found2 = true;
        }
        assertTrue(found1);
        assertTrue(found2);
    }

    function testGetPendingDepositsWithApproved() public {
        bytes32 depositId1 = keccak256("test1");
        bytes32 depositId2 = keccak256("test2");

        testContract.recordDeposit(depositId1, 1000, user1);
        testContract.recordDeposit(depositId2, 2000, user2);

        // Approve first deposit
        testContract.approveDeposit(depositId1, 1000);

        // Should only return pending (unapproved) deposits
        DepositLib.Deposit[] memory deposits = testContract.getPendingDeposits();
        assertEq(deposits.length, 1);
        assertEq(deposits[0].depositId, depositId2);
    }

    function testGetPendingDepositsEmpty() public {
        DepositLib.Deposit[] memory deposits = testContract.getPendingDeposits();
        assertEq(deposits.length, 0);
    }

    // ───────────────────────────── GET USER DEPOSIT IDS TESTS ─────────────────────────────

    function testGetUserDepositIds() public {
        bytes32 depositId1 = keccak256("test1");
        bytes32 depositId2 = keccak256("test2");

        testContract.recordDeposit(depositId1, 1000, user1);
        testContract.recordDeposit(depositId2, 2000, user1);

        bytes32[] memory userDepositIds = testContract.getUserDepositIds(user1);
        assertEq(userDepositIds.length, 2);
        assertTrue(userDepositIds[0] == depositId1 || userDepositIds[0] == depositId2);
        assertTrue(userDepositIds[1] == depositId1 || userDepositIds[1] == depositId2);
    }

    function testGetUserDepositIdsEmpty() public {
        bytes32[] memory userDepositIds = testContract.getUserDepositIds(user1);
        assertEq(userDepositIds.length, 0);
    }

    function testGetUserDepositIdsDifferentUsers() public {
        bytes32 depositId1 = keccak256("test1");
        bytes32 depositId2 = keccak256("test2");

        testContract.recordDeposit(depositId1, 1000, user1);
        testContract.recordDeposit(depositId2, 2000, user2);

        bytes32[] memory user1Deposits = testContract.getUserDepositIds(user1);
        bytes32[] memory user2Deposits = testContract.getUserDepositIds(user2);

        assertEq(user1Deposits.length, 1);
        assertEq(user2Deposits.length, 1);
        assertEq(user1Deposits[0], depositId1);
        assertEq(user2Deposits[0], depositId2);
    }

    // ───────────────────────────── GET USER DEPOSITS TESTS ─────────────────────────────

    function testGetUserDeposits() public {
        bytes32 depositId1 = keccak256("test1");
        bytes32 depositId2 = keccak256("test2");

        testContract.recordDeposit(depositId1, 1000, user1);
        testContract.recordDeposit(depositId2, 2000, user1);

        DepositLib.Deposit[] memory deposits = testContract.getUserDeposits(user1);
        assertEq(deposits.length, 2);

        bool found1 = false;
        bool found2 = false;
        for (uint256 i = 0; i < deposits.length; i++) {
            if (deposits[i].depositId == depositId1) found1 = true;
            if (deposits[i].depositId == depositId2) found2 = true;
        }
        assertTrue(found1);
        assertTrue(found2);
    }

    function testGetUserDepositsEmpty() public {
        DepositLib.Deposit[] memory deposits = testContract.getUserDeposits(user1);
        assertEq(deposits.length, 0);
    }

    function testGetUserDepositsWithExternalDeposit() public {
        uint256 amount = 1000 * 10 ** 6;
        bytes32 tag = keccak256("tag1");

        bytes32 depositId = testContract.recordExternalDeposit(amount, beneficiary1, tag);

        DepositLib.Deposit[] memory deposits = testContract.getUserDeposits(beneficiary1);
        assertEq(deposits.length, 1);
        assertEq(deposits[0].depositId, depositId);
        assertTrue(deposits[0].isExternal);
        assertEq(deposits[0].beneficiary, beneficiary1);
    }

    // ───────────────────────────── GET TOTAL PENDING AMOUNT TESTS ─────────────────────────────

    function testGetTotalPendingAmount() public {
        bytes32 depositId1 = keccak256("test1");
        bytes32 depositId2 = keccak256("test2");
        bytes32 depositId3 = keccak256("test3");

        testContract.recordDeposit(depositId1, 1000 * 10 ** 6, user1);
        testContract.recordDeposit(depositId2, 2000 * 10 ** 6, user2);
        testContract.recordDeposit(depositId3, 3000 * 10 ** 6, user3);

        uint256 totalPending = testContract.getTotalPendingAmount();
        assertEq(totalPending, 6000 * 10 ** 6);
    }

    function testGetTotalPendingAmountWithApproved() public {
        bytes32 depositId1 = keccak256("test1");
        bytes32 depositId2 = keccak256("test2");

        testContract.recordDeposit(depositId1, 1000 * 10 ** 6, user1);
        testContract.recordDeposit(depositId2, 2000 * 10 ** 6, user2);

        // Approve first deposit
        testContract.approveDeposit(depositId1, 1000 * 10 ** 6);

        // Should only count pending (unapproved) deposits
        uint256 totalPending = testContract.getTotalPendingAmount();
        assertEq(totalPending, 2000 * 10 ** 6);
    }

    function testGetTotalPendingAmountEmpty() public {
        uint256 totalPending = testContract.getTotalPendingAmount();
        assertEq(totalPending, 0);
    }

    function testGetTotalPendingAmountWithMultipleUsers() public {
        bytes32 depositId1 = keccak256("test1");
        bytes32 depositId2 = keccak256("test2");
        bytes32 depositId3 = keccak256("test3");
        bytes32 depositId4 = keccak256("test4");

        testContract.recordDeposit(depositId1, 500 * 10 ** 6, user1);
        testContract.recordDeposit(depositId2, 1500 * 10 ** 6, user1);
        testContract.recordDeposit(depositId3, 2500 * 10 ** 6, user2);
        testContract.recordDeposit(depositId4, 3500 * 10 ** 6, user3);

        uint256 totalPending = testContract.getTotalPendingAmount();
        assertEq(totalPending, 8000 * 10 ** 6);
    }
}
