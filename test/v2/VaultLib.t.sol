// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {VaultLib} from "../../contracts/v2/libraries/VaultLib.sol";

/// @dev Thin contract wrapper to expose VaultLib internal functions for unit testing.
contract VaultLibHarness {
    using VaultLib for *;

    mapping(bytes32 => VaultLib.Deposit)              public deposits;
    bytes32[]                                          public pendingIds;
    mapping(bytes32 => uint256)                        public pendingIndex;
    mapping(address => bytes32[])                      public userDeposits;
    mapping(address => mapping(bytes32 => uint256))    public userIndex;

    mapping(bytes32 => VaultLib.RedeemRequest)         public redeems;
    bytes32[]                                          public pendingRedeemIds;
    mapping(bytes32 => uint256)                        public pendingRedeemIndex;
    mapping(address => bytes32[])                      public userRedeems;
    mapping(address => mapping(bytes32 => uint256))    public userRedeemIndex;

    function recordDeposit(bytes32 depositId, uint256 amount, address user) external {
        VaultLib.recordDeposit(
            deposits,
            pendingIds,
            pendingIndex,
            userDeposits,
            userIndex,
            depositId,
            amount,
            user
        );
    }

    function approveDeposit(
        bytes32 depositId,
        uint256 approvedAmount,
        uint256 assetPrice,
        uint8 oracleDecimals,
        uint8 assetDecimals,
        uint8 settlementDecimals
    ) external {
        VaultLib.approveDeposit(
            deposits,
            depositId,
            approvedAmount,
            assetPrice,
            oracleDecimals,
            assetDecimals,
            settlementDecimals
        );
    }

    function recordRedeemRequest(bytes32 redeemId, address user, uint256 shares) external {
        VaultLib.recordRedeemRequest(
            redeems,
            pendingRedeemIds,
            pendingRedeemIndex,
            userRedeems,
            userRedeemIndex,
            redeemId,
            user,
            shares
        );
    }

    function removeFromArray(bytes32 id) external {
        VaultLib.removeFromArray(pendingIds, pendingIndex, id);
    }

    function removeUserEntry(address user, bytes32 id) external {
        VaultLib.removeUserEntry(userDeposits, userIndex, user, id);
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
        assertFalse(d.approved);
        assertEq(d.approvedShares, 0);
    }

    function test_recordDeposit_addsToPending() public {
        h.recordDeposit(DID, 1000e6, userA);
        assertEq(h.getPendingIds().length, 1);
        assertEq(h.getPendingIds()[0], DID);
        assertEq(h.pendingIndex(DID), 1);
    }

    function test_recordDeposit_addsToUserList() public {
        h.recordDeposit(DID, 1000e6, userA);
        bytes32[] memory uDeps = h.getUserDeposits(userA);
        assertEq(uDeps.length, 1);
        assertEq(uDeps[0], DID);
        assertEq(h.userIndex(userA, DID), 1);
    }

    function test_recordDeposit_revertsAlreadyExists() public {
        h.recordDeposit(DID, 1000e6, userA);
        vm.expectRevert(VaultLib.DepositAlreadyExists.selector);
        h.recordDeposit(DID, 500e6, userA);
    }

    // ─── approveDeposit ───────────────────────────────────────────────────────

    function test_approveDeposit_approvesCorrectly() public {
        h.recordDeposit(DID, 1000e6, userA);
        h.approveDeposit(DID, 1000e6, 450_000_000, 8, 6, 6);

        VaultLib.Deposit memory d = h.getDeposit(DID);
        assertTrue(d.approved);
        assertEq(d.approvedAmount, 1000e6);
        assertEq(d.priceSnapshot,  450_000_000);
        assertEq(d.approvedAssetAmount, uint256(1000e6) * 1e8 / 450_000_000);
    }

    function test_approveDeposit_scalesSettlementToAssetDecimals() public {
        // 1 DAI (18 dec) at $1/asset → 1 whole asset token (6 dec)
        h.recordDeposit(DID, 1e18, userA);
        h.approveDeposit(DID, 1e18, 100_000_000, 8, 6, 18);

        VaultLib.Deposit memory d = h.getDeposit(DID);
        assertEq(d.approvedAssetAmount, 1e6);
    }

    function test_assetToSettlementAmount_matchesInverse() public pure {
        uint256 assetAmount = 100e6;
        uint256 price = 450_000_000;
        uint256 settlement = VaultLib.assetToSettlementAmount(assetAmount, price, 6, 8, 18);
        uint256 roundTrip = VaultLib.settlementToAssetAmount(settlement, price, 6, 8, 18);
        assertEq(roundTrip, assetAmount);
    }

    function test_approveDeposit_revertsNotFound() public {
        vm.expectRevert(VaultLib.DepositNotFound.selector);
        h.approveDeposit(DID, 1000e6, 450_000_000, 8, 6, 6);
    }

    function test_approveDeposit_revertsAlreadyApproved() public {
        h.recordDeposit(DID, 1000e6, userA);
        h.approveDeposit(DID, 1000e6, 450_000_000, 8, 6, 6);
        vm.expectRevert(VaultLib.DepositAlreadyApproved.selector);
        h.approveDeposit(DID, 1000e6, 450_000_000, 8, 6, 6);
    }

    function test_approveDeposit_revertsPartialAmount() public {
        h.recordDeposit(DID, 1000e6, userA);
        vm.expectRevert(VaultLib.MustApproveFullDeposit.selector);
        h.approveDeposit(DID, 500e6, 450_000_000, 8, 6, 6);
    }

    function test_approveDeposit_revertsZeroApprovedAmount() public {
        h.recordDeposit(DID, 1000e6, userA);
        vm.expectRevert(VaultLib.MustApproveFullDeposit.selector);
        h.approveDeposit(DID, 0, 450_000_000, 8, 6, 6);
    }

    function test_approveDeposit_revertsAmountExceedsDeposit() public {
        h.recordDeposit(DID, 1000e6, userA);
        vm.expectRevert(VaultLib.MustApproveFullDeposit.selector);
        h.approveDeposit(DID, 2000e6, 450_000_000, 8, 6, 6);
    }

    function test_approveDeposit_revertsZeroPrice() public {
        h.recordDeposit(DID, 1000e6, userA);
        vm.expectRevert(VaultLib.InvalidApprovedAmount.selector);
        h.approveDeposit(DID, 1000e6, 0, 8, 6, 6);
    }

    function test_find031_approveDeposit_revertsZeroAssetAmount() public {
        // 1 wei USDC at $4.50 truncates: 1 * 1e8 / 450_000_000 == 0
        h.recordDeposit(DID, 1, userA);
        vm.expectRevert(VaultLib.InvalidApprovedAmount.selector);
        h.approveDeposit(DID, 1, 450_000_000, 8, 6, 6);
    }

    // ─── recordRedeemRequest ─────────────────────────────────────────────────

    function test_recordRedeemRequest_stores() public {
        h.recordRedeemRequest(RID, userA, 500e6);
        VaultLib.RedeemRequest memory r = h.getRedeem(RID);
        assertEq(r.user,   userA);
        assertEq(r.shares, 500e6);
        assertFalse(r.approved);
        assertFalse(r.claimed);
        assertEq(h.pendingRedeemIndex(RID), 1);
    }

    function test_recordRedeemRequest_revertsAlreadyExists() public {
        h.recordRedeemRequest(RID, userA, 500e6);
        vm.expectRevert(VaultLib.RedeemAlreadyExists.selector);
        h.recordRedeemRequest(RID, userA, 500e6);
    }

    // ─── removeFromArray (O(1) indexed) ──────────────────────────────────────

    function test_removeFromArray_removesCorrectElement() public {
        bytes32 id1 = keccak256("a");
        bytes32 id2 = keccak256("b");
        bytes32 id3 = keccak256("c");

        h.recordDeposit(id1, 1, userA);
        h.recordDeposit(id2, 1, userB);
        h.recordDeposit(id3, 1, userA);

        assertEq(h.getPendingIds().length, 3);
        assertEq(h.pendingIndex(id2), 2);

        h.removeFromArray(id2);

        assertEq(h.getPendingIds().length, 2);
        assertEq(h.pendingIndex(id2), 0);
        bytes32[] memory arr = h.getPendingIds();
        for (uint256 i; i < arr.length; i++) {
            assertTrue(arr[i] != id2, "id2 should be removed");
            assertEq(h.pendingIndex(arr[i]), i + 1);
        }
    }

    function test_removeFromArray_updatesMovedElementIndex() public {
        bytes32 id1 = keccak256("a");
        bytes32 id2 = keccak256("b");
        bytes32 id3 = keccak256("c");

        h.recordDeposit(id1, 1, userA);
        h.recordDeposit(id2, 1, userB);
        h.recordDeposit(id3, 1, userA);

        // Remove middle element — id3 swaps into index 2
        h.removeFromArray(id2);

        assertEq(h.getPendingIds()[0], id1);
        assertEq(h.getPendingIds()[1], id3);
        assertEq(h.pendingIndex(id1), 1);
        assertEq(h.pendingIndex(id3), 2);
    }

    function test_removeFromArray_noopIfNotFound() public {
        h.recordDeposit(DID, 1, userA);
        h.removeFromArray(keccak256("nonexistent"));
        assertEq(h.getPendingIds().length, 1);
        assertEq(h.pendingIndex(DID), 1);
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
        assertEq(h.userIndex(userA, id1), 0);
        assertEq(h.userIndex(userA, id2), 1);
    }

    function test_removeUserEntry_noopIfNotFound() public {
        h.recordDeposit(DID, 1, userA);
        h.removeUserEntry(userA, keccak256("nonexistent"));
        assertEq(h.getUserDeposits(userA).length, 1);
    }
}
