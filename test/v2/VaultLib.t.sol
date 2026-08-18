// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {VaultLib} from "../../contracts/v2/libraries/VaultLib.sol";

/// @dev Thin contract wrapper to expose VaultLib internal functions for unit testing.
contract VaultLibHarness {
    using VaultLib for *;

    mapping(bytes32 => VaultLib.Deposit)              public deposits;
    bytes32[]                                          public pendingIds;
    mapping(address => bytes32[])                      public userDeposits;

    mapping(bytes32 => VaultLib.RedeemRequest)         public redeems;
    bytes32[]                                          public pendingRedeemIds;
    mapping(address => bytes32[])                      public userRedeems;

    function recordDeposit(bytes32 depositId, uint256 amount, address user) external {
        VaultLib.recordDeposit(deposits, pendingIds, userDeposits, depositId, amount, user);
    }

    function recordExternalDeposit(
        uint256 usdcAmount,
        address beneficiary,
        bytes32 tag,
        address createdBy,
        uint256 nonce
    ) external returns (bytes32) {
        return VaultLib.recordExternalDeposit(
            deposits, pendingIds, userDeposits, usdcAmount, beneficiary, tag, createdBy, nonce
        );
    }

    function approveDeposit(bytes32 depositId, uint256 approvedAmount, uint256 assetPrice, uint8 dec) external {
        VaultLib.approveDeposit(deposits, depositId, approvedAmount, assetPrice, dec);
    }

    function approveExternalDeposit(bytes32 depositId, uint256 approvedUsdc, uint256 assetPrice, uint8 dec) external {
        VaultLib.approveExternalDeposit(deposits, depositId, approvedUsdc, assetPrice, dec);
    }

    function recordRedeemRequest(bytes32 redeemId, address user, uint256 shares) external {
        VaultLib.recordRedeemRequest(redeems, pendingRedeemIds, userRedeems, redeemId, user, shares);
    }

    function removeFromArray(bytes32 id) external {
        VaultLib.removeFromArray(pendingIds, id);
    }

    function removeUserEntry(address user, bytes32 id) external {
        VaultLib.removeUserEntry(userDeposits, user, id);
    }

    function getDeposit(bytes32 depositId) external view returns (VaultLib.Deposit memory) {
        return deposits[depositId];
    }

    function getRedeem(bytes32 redeemId) external view returns (VaultLib.RedeemRequest memory) {
        return redeems[redeemId];
    }

    function getPendingIds() external view returns (bytes32[] memory) { return pendingIds; }
    function getUserDeposits(address user) external view returns (bytes32[] memory) { return userDeposits[user]; }
}

contract VaultLibTest is Test {

    VaultLibHarness internal h;

    address internal userA = makeAddr("userA");
    address internal userB = makeAddr("userB");

    bytes32 constant DID = keccak256("deposit1");
    bytes32 constant RID = keccak256("redeem1");

    function setUp() public {
        h = new VaultLibHarness();
    }

    // ─── recordDeposit ────────────────────────────────────────────────────────

    function test_recordDeposit_storesData() public {
        h.recordDeposit(DID, 1000e6, userA);

        VaultLib.Deposit memory d = h.getDeposit(DID);
        assertEq(d.user,   userA);
        assertEq(d.amount, 1000e6);
        assertFalse(d.isExternal);
        assertFalse(d.approved);
    }

    function test_recordDeposit_addsToPending() public {
        h.recordDeposit(DID, 1000e6, userA);
        assertEq(h.getPendingIds().length, 1);
        assertEq(h.getPendingIds()[0], DID);
    }

    function test_recordDeposit_addsToUserList() public {
        h.recordDeposit(DID, 1000e6, userA);
        bytes32[] memory uDeps = h.getUserDeposits(userA);
        assertEq(uDeps.length, 1);
        assertEq(uDeps[0], DID);
    }

    function test_recordDeposit_revertsAlreadyExists() public {
        h.recordDeposit(DID, 1000e6, userA);
        vm.expectRevert(VaultLib.DepositAlreadyExists.selector);
        h.recordDeposit(DID, 500e6, userA);
    }

    // ─── approveDeposit (non-external) ────────────────────────────────────────

    function test_approveDeposit_approvesCorrectly() public {
        h.recordDeposit(DID, 1000e6, userA);
        h.approveDeposit(DID, 1000e6, 450_000_000, 8);

        VaultLib.Deposit memory d = h.getDeposit(DID);
        assertTrue(d.approved);
        assertEq(d.approvedAmount, 1000e6);
        assertEq(d.priceSnapshot,  450_000_000);
        // 1000e6 * 1e8 / 450_000_000 = 2222222222
        assertEq(d.approvedAssetAmount, uint256(1000e6) * 1e8 / 450_000_000);
    }

    function test_approveDeposit_revertsNotFound() public {
        vm.expectRevert(VaultLib.DepositNotFound.selector);
        h.approveDeposit(DID, 1000e6, 450_000_000, 8);
    }

    function test_approveDeposit_revertsIfExternal() public {
        h.recordExternalDeposit(1000e6, userA, bytes32("tag"), userB, 0);
        bytes32[] memory p = h.getPendingIds();
        bytes32 did = p[0];
        vm.expectRevert(VaultLib.ExternalDepositRequiresPriceApproval.selector);
        h.approveDeposit(did, 1000e6, 450_000_000, 8);
    }

    function test_approveDeposit_revertsAlreadyApproved() public {
        h.recordDeposit(DID, 1000e6, userA);
        h.approveDeposit(DID, 1000e6, 450_000_000, 8);
        vm.expectRevert(VaultLib.DepositAlreadyApproved.selector);
        h.approveDeposit(DID, 1000e6, 450_000_000, 8);
    }

    function test_approveDeposit_revertsZeroApprovedAmount() public {
        h.recordDeposit(DID, 1000e6, userA);
        vm.expectRevert(VaultLib.InvalidApprovedAmount.selector);
        h.approveDeposit(DID, 0, 450_000_000, 8);
    }

    function test_approveDeposit_revertsAmountExceedsDeposit() public {
        h.recordDeposit(DID, 1000e6, userA);
        vm.expectRevert(VaultLib.InvalidApprovedAmount.selector);
        h.approveDeposit(DID, 2000e6, 450_000_000, 8); // 2000 > 1000
    }

    function test_approveDeposit_revertsZeroPrice() public {
        h.recordDeposit(DID, 1000e6, userA);
        vm.expectRevert(VaultLib.InvalidApprovedAmount.selector);
        h.approveDeposit(DID, 1000e6, 0, 8);
    }

    // ─── recordExternalDeposit ────────────────────────────────────────────────

    function test_recordExternalDeposit_storesData() public {
        bytes32 did = h.recordExternalDeposit(2000e6, userA, bytes32("mytag"), userB, 0);

        VaultLib.Deposit memory d = h.getDeposit(did);
        assertEq(d.amount,      2000e6);
        assertEq(d.beneficiary, userA);
        assertTrue(d.isExternal);
        assertEq(d.tag, bytes32("mytag"));
    }

    function test_recordExternalDeposit_revertsZeroBeneficiary() public {
        vm.expectRevert(VaultLib.InvalidBeneficiary.selector);
        h.recordExternalDeposit(1000e6, address(0), bytes32("tag"), userA, 0);
    }

    // ─── approveExternalDeposit error paths ──────────────────────────────────

    function test_approveExternalDeposit_revertsNotExternalDeposit() public {
        h.recordDeposit(DID, 1000e6, userA);
        vm.expectRevert(VaultLib.NotExternalDeposit.selector);
        h.approveExternalDeposit(DID, 1000e6, 450_000_000, 8);
    }

    function test_approveExternalDeposit_revertsNotFound() public {
        vm.expectRevert(VaultLib.DepositNotFound.selector);
        h.approveExternalDeposit(DID, 1000e6, 450_000_000, 8);
    }

    function test_approveExternalDeposit_revertsZeroPrice() public {
        bytes32 did = h.recordExternalDeposit(1000e6, userA, bytes32("t"), userB, 0);
        vm.expectRevert(VaultLib.InvalidApprovedAmount.selector);
        h.approveExternalDeposit(did, 1000e6, 0, 8);
    }

    function test_approveExternalDeposit_revertsInvalidAmount() public {
        bytes32 did = h.recordExternalDeposit(1000e6, userA, bytes32("t"), userB, 0);
        vm.expectRevert(VaultLib.InvalidApprovedAmount.selector);
        h.approveExternalDeposit(did, 9999e6, 450_000_000, 8); // > deposit amount
    }

    function test_approveExternalDeposit_success() public {
        bytes32 did = h.recordExternalDeposit(1000e6, userA, bytes32("t"), userB, 0);
        h.approveExternalDeposit(did, 900e6, 450_000_000, 8);

        VaultLib.Deposit memory d = h.getDeposit(did);
        assertTrue(d.approved);
        assertEq(d.approvedAmount, 900e6);
        assertEq(d.priceSnapshot, 450_000_000);
        assertEq(d.approvedAssetAmount, (900e6 * 1e8) / 450_000_000);
    }

    function test_recordExternalDeposit_nonceCollisionRehashes() public {
        vm.warp(1_700_000_000);
        bytes32 first = h.recordExternalDeposit(1000e6, userA, bytes32("same"), userB, 7);
        bytes32 second = h.recordExternalDeposit(1000e6, userA, bytes32("same"), userB, 7);

        assertTrue(first != second, "deposit id should rehash on collision");
        assertEq(h.getPendingIds().length, 2);
    }

    // ─── recordRedeemRequest ─────────────────────────────────────────────────

    function test_recordRedeemRequest_stores() public {
        h.recordRedeemRequest(RID, userA, 500e6);
        VaultLib.RedeemRequest memory r = h.getRedeem(RID);
        assertEq(r.user,   userA);
        assertEq(r.shares, 500e6);
        assertFalse(r.approved);
        assertFalse(r.claimed);
    }

    function test_recordRedeemRequest_revertsAlreadyExists() public {
        h.recordRedeemRequest(RID, userA, 500e6);
        vm.expectRevert(VaultLib.RedeemAlreadyExists.selector);
        h.recordRedeemRequest(RID, userA, 500e6);
    }

    // ─── removeFromArray ─────────────────────────────────────────────────────

    function test_removeFromArray_removesCorrectElement() public {
        bytes32 id1 = keccak256("a");
        bytes32 id2 = keccak256("b");
        bytes32 id3 = keccak256("c");

        h.recordDeposit(id1, 1, userA);
        h.recordDeposit(id2, 1, userB);
        h.recordDeposit(id3, 1, userA);

        assertEq(h.getPendingIds().length, 3);

        h.removeFromArray(id2);

        assertEq(h.getPendingIds().length, 2);
        // id2 should no longer be in the list
        bytes32[] memory arr = h.getPendingIds();
        for (uint256 i; i < arr.length; i++) {
            assertTrue(arr[i] != id2, "id2 should be removed");
        }
    }

    function test_removeFromArray_noopIfNotFound() public {
        h.recordDeposit(DID, 1, userA);
        h.removeFromArray(keccak256("nonexistent")); // should not revert
        assertEq(h.getPendingIds().length, 1);
    }

    // ─── removeUserEntry ─────────────────────────────────────────────────────

    function test_removeUserEntry_removesEntry() public {
        bytes32 id1 = keccak256("d1");
        bytes32 id2 = keccak256("d2");
        h.recordDeposit(id1, 1, userA);
        h.recordDeposit(id2, 1, userA);

        assertEq(h.getUserDeposits(userA).length, 2);

        h.removeUserEntry(userA, id1);

        assertEq(h.getUserDeposits(userA).length, 1);
        assertEq(h.getUserDeposits(userA)[0], id2);
    }

    function test_removeUserEntry_noopIfNotFound() public {
        h.recordDeposit(DID, 1, userA);
        h.removeUserEntry(userA, keccak256("nonexistent")); // should not revert
        assertEq(h.getUserDeposits(userA).length, 1);
    }
}
