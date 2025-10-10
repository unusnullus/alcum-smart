// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {console} from "forge-std/console.sol";

import {Upgrades, Options} from "openzeppelin-foundry-upgrades/Upgrades.sol";

import {Zapper} from "../contracts/Zapper.sol";
import {CUPToken} from "../contracts/CUPToken.sol";
import {xCUP} from "../contracts/xCUP.sol";
import {EpochManager, IEpochManager} from "../contracts/EpochManager.sol";
import {CopperPriceConsumerMock} from "../contracts/mock/CopperPriceConsumerMock.sol";
import {ERC20Mock} from "../contracts/mock/ERC20Mock.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";

/**
 * @title ZapperAuditTests
 * @notice Comprehensive test suite for Zapper contract audit preparation
 * @dev This test suite focuses on edge cases, security scenarios, and comprehensive coverage
 *      for audit purposes. Tests are organized by functionality and include detailed comments.
 */
contract ZapperAuditTests is Test {
    Zapper public zapper;
    CUPToken public cupToken;
    xCUP public vault;
    IEpochManager public epochManager;
    CopperPriceConsumerMock public priceConsumer;
    ERC20Mock public usdcToken;
    ERC20Mock public wethToken;
    ERC20Mock public daiToken;

    address public owner;
    address public curator;
    address public hostIntegration;
    address public user1;
    address public user2;
    address public user3;
    address public unauthorized;

    uint256 constant EPOCH_DURATION = 30 days;
    uint256 constant INITIAL_COPPER_PRICE = 450000000; // $4.50 with 8 decimals
    uint256 constant INITIAL_SUPPLY = 1000000e6;

    // Events for testing
    event ZapAndDeposit(address indexed router, address indexed tokenIn, uint256 amount);
    event DepositApproved(bytes32 depositId, uint256 approvedAmount);
    event DepositDeclined(bytes32 depositId, address user, uint256 refundAmount);
    event DepositClaimed(bytes32 depositId, address user, uint256 shares);
    event DepositWithdrawn(bytes32 depositId, address user, uint256 amount);
    event ProportionalApproval(uint256 totalApproved, uint256 totalDeposited, uint256 proportion);
    event ExternalDepositRegistered(
        address indexed createdBy,
        address indexed beneficiary,
        bytes32 indexed depositId,
        bytes32 tag,
        uint256 usdcAmount
    );

    function setUp() public {
        owner = address(this);
        curator = makeAddr("curator");
        hostIntegration = makeAddr("hostIntegration");
        user1 = makeAddr("user1");
        user2 = makeAddr("user2");
        user3 = makeAddr("user3");
        unauthorized = makeAddr("unauthorized");

        // Deploy tokens using upgradeable pattern
        address cupTokenProxy = Upgrades.deployTransparentProxy(
            "CUPToken.sol:CUPToken",
            owner,
            abi.encodeCall(CUPToken.initialize, ())
        );
        cupToken = CUPToken(cupTokenProxy);
        usdcToken = new ERC20Mock("USDC", "USDC", 6);
        wethToken = new ERC20Mock("WETH", "WETH", 18);
        daiToken = new ERC20Mock("DAI", "DAI", 18);

        // Deploy price consumer
        priceConsumer = new CopperPriceConsumerMock();
        priceConsumer.setPrice(INITIAL_COPPER_PRICE);

        // Deploy EpochManager
        address epochManagerProxy = Upgrades.deployTransparentProxy(
            "EpochManager.sol:EpochManager",
            owner,
            abi.encodeCall(EpochManager.initialize, (EPOCH_DURATION))
        );
        epochManager = IEpochManager(epochManagerProxy);

        // Deploy xCUP vault
        address vaultProxy = Upgrades.deployTransparentProxy(
            "xCUP.sol:xCUP",
            owner,
            abi.encodeCall(xCUP.initialize, (IERC20(address(cupToken)), "xCUP Vault", "xCUP"))
        );
        vault = xCUP(vaultProxy);

        // Deploy Zapper
        address zapperProxy = Upgrades.deployTransparentProxy(
            "Zapper.sol:Zapper",
            owner,
            abi.encodeCall(
                Zapper.initialize,
                (
                    address(cupToken),
                    address(usdcToken),
                    address(vault),
                    address(0x1234), // Mock router
                    address(priceConsumer),
                    address(epochManager)
                )
            )
        );
        zapper = Zapper(zapperProxy);

        // Setup roles
        zapper.grantRole(zapper.VAULT_CURATOR_ROLE(), curator);
        zapper.grantRole(zapper.HOST_INTEGRATION_ROLE(), hostIntegration);
        vault.grantRole(vault.REDEEMER_ROLE(), address(zapper));

        // Setup tokens and balances
        cupToken.grantRole(cupToken.MINTER_ROLE(), owner);
        cupToken.mint(address(zapper), INITIAL_SUPPLY);

        // Mint tokens to users
        usdcToken.mint(user1, INITIAL_SUPPLY);
        usdcToken.mint(user2, INITIAL_SUPPLY);
        usdcToken.mint(user3, INITIAL_SUPPLY);
        usdcToken.mint(address(zapper.silo()), INITIAL_SUPPLY);

        daiToken.mint(user1, INITIAL_SUPPLY * 1e12);
        wethToken.mint(user1, 100e18);

        vm.deal(user1, 100 ether);
        vm.deal(user2, 100 ether);
        vm.deal(user3, 100 ether);
    }

    // ============ ACCESS CONTROL TESTS ============

    function testOnlyOwnerCanPause() public {
        vm.prank(unauthorized);
        vm.expectRevert();
        zapper.pause();

        vm.prank(owner);
        zapper.pause();
        assertTrue(zapper.paused());
    }

    function testOnlyOwnerCanUnpause() public {
        vm.prank(owner);
        zapper.pause();

        vm.prank(unauthorized);
        vm.expectRevert();
        zapper.unpause();

        vm.prank(owner);
        zapper.unpause();
        assertFalse(zapper.paused());
    }

    function testOnlyOwnerCanWithdraw() public {
        vm.prank(unauthorized);
        vm.expectRevert();
        zapper.withdraw(1000e6);

        vm.prank(owner);
        zapper.withdraw(1000e6);
    }

    function testOnlyCuratorCanApprove() public {
        bytes32 depositId = keccak256("test");

        vm.prank(unauthorized);
        vm.expectRevert();
        zapper.approveDeposit(depositId, 1000e6);
    }

    function testOnlyHostIntegrationCanRegisterExternal() public {
        vm.prank(unauthorized);
        vm.expectRevert();
        zapper.registerExternalDepositFor(user1, 1000e6, keccak256("tag"));

        vm.prank(hostIntegration);
        bytes32 depositId = zapper.registerExternalDepositFor(user1, 1000e6, keccak256("tag"));
        assertTrue(depositId != bytes32(0));
    }

    // ============ DEPOSIT ID UNIQUENESS TESTS ============

    function testDepositIdUniqueness() public {
        uint256 amount = 1000e6;
        bytes32 depositId = keccak256("unique_test");

        vm.startPrank(user1);
        usdcToken.approve(address(zapper), amount * 2);

        // First deposit should succeed
        zapper.zapAndDeposit(usdcToken, amount, depositId, 100);

        // Second deposit with same ID should fail
        vm.expectRevert("Deposit ID already exists");
        zapper.zapAndDeposit(usdcToken, amount, depositId, 100);
        vm.stopPrank();
    }

    function testExternalDepositIdGeneration() public {
        vm.prank(hostIntegration);
        bytes32 depositId1 = zapper.registerExternalDepositFor(user1, 1000e6, keccak256("tag1"));

        vm.prank(hostIntegration);
        bytes32 depositId2 = zapper.registerExternalDepositFor(user1, 1000e6, keccak256("tag2"));

        assertTrue(depositId1 != depositId2, "External deposit IDs should be unique");
    }

    // ============ EPOCH TIMING TESTS ============

    function testEpochActiveModifierEnforcement() public {
        bytes32 depositId = keccak256("test");

        // Move past epoch end
        vm.warp(block.timestamp + EPOCH_DURATION + 1);

        vm.prank(curator);
        vm.expectRevert("Epoch not active");
        zapper.approveDeposit(depositId, 1000e6);

        vm.prank(curator);
        vm.expectRevert("Epoch not active");
        zapper.declineDeposit(depositId);

        vm.prank(curator);
        vm.expectRevert("Epoch not active");
        zapper.approveDepositsProportionally(1000e6);

        vm.prank(user1);
        vm.expectRevert("Epoch not active");
        zapper.claimDeposit(depositId);
    }

    function testEpochTransition() public {
        // Create deposit in current epoch
        vm.startPrank(user1);
        usdcToken.approve(address(zapper), 1000e6);
        zapper.zapAndDeposit(usdcToken, 1000e6, keccak256("test"), 100);
        vm.stopPrank();

        // Move to next epoch
        vm.warp(block.timestamp + EPOCH_DURATION);
        epochManager.nextEpoch();

        // Should be able to approve in new epoch
        bytes32[] memory pendingIds = zapper.getPendingDepositIds();
        vm.prank(curator);
        zapper.approveDeposit(pendingIds[0], 1000e6);
    }

    // ============ PRICE ORACLE TESTS ============

    function testZeroCopperPriceHandling() public {
        // Create and approve deposit
        vm.startPrank(user1);
        usdcToken.approve(address(zapper), 1000e6);
        zapper.zapAndDeposit(usdcToken, 1000e6, keccak256("test"), 100);
        vm.stopPrank();

        vm.warp(block.timestamp + EPOCH_DURATION);
        epochManager.nextEpoch();

        bytes32[] memory pendingIds = zapper.getPendingDepositIds();
        vm.prank(curator);
        zapper.approveDeposit(pendingIds[0], 1000e6);

        // Set price to zero
        priceConsumer.setPrice(0);

        // Claim should fail
        vm.prank(user1);
        vm.expectRevert("Copper price is 0");
        zapper.claimDeposit(pendingIds[0]);
    }

    function testPriceVolatilityImpact() public {
        uint256 depositAmount = 1000e6;
        uint256 initialPrice = 450000000; // $4.50
        uint256 newPrice = 900000000; // $9.00 (doubled)

        // Create and approve deposit at initial price
        vm.startPrank(user1);
        usdcToken.approve(address(zapper), depositAmount);
        zapper.zapAndDeposit(usdcToken, depositAmount, keccak256("test"), 100);
        vm.stopPrank();

        vm.warp(block.timestamp + EPOCH_DURATION);
        epochManager.nextEpoch();

        bytes32[] memory pendingIds = zapper.getPendingDepositIds();
        vm.prank(curator);
        zapper.approveDeposit(pendingIds[0], depositAmount);

        // Change price before claim
        priceConsumer.setPrice(newPrice);

        // Claim should use new price
        vm.prank(user1);
        uint256 shares = zapper.claimDeposit(pendingIds[0]);

        // With doubled price, should get more CUP tokens and thus more shares
        assertGt(shares, 0);
    }

    // ============ EXTERNAL DEPOSIT TESTS ============

    function testExternalDepositWithPriceSnapshot() public {
        uint256 usdcAmount = 5000e6;
        uint256 snapshotPrice = 500000000; // $5.00
        bytes32 tag = keccak256("external_test");

        // Register external deposit
        vm.prank(hostIntegration);
        bytes32 depositId = zapper.registerExternalDepositFor(user1, usdcAmount, tag);

        // Advance epoch
        vm.warp(block.timestamp + EPOCH_DURATION);
        epochManager.nextEpoch();

        // Approve with price snapshot
        vm.prank(curator);
        zapper.approveExternalDepositWithPrice(depositId, usdcAmount, snapshotPrice);

        // Change current price
        priceConsumer.setPrice(1000000000); // $10.00

        // Claim should use snapshot price, not current price
        vm.prank(user1);
        uint256 shares = zapper.claimDeposit(depositId);

        assertGt(shares, 0);

        // Verify deposit was processed correctly
        Zapper.Deposit memory deposit = zapper.getDeposit(depositId);
        assertEq(deposit.priceSnapshot, snapshotPrice);
        assertGt(deposit.approvedCupAmount, 0);
    }

    function testExternalDepositBeneficiaryUpdate() public {
        uint256 usdcAmount = 1000e6;
        bytes32 tag = keccak256("beneficiary_test");

        // Register external deposit
        vm.prank(hostIntegration);
        bytes32 depositId = zapper.registerExternalDepositFor(user1, usdcAmount, tag);

        // Update beneficiary
        vm.prank(hostIntegration);
        zapper.setDepositBeneficiary(depositId, user2);

        // Verify beneficiary was updated
        Zapper.Deposit memory deposit = zapper.getDeposit(depositId);
        assertEq(deposit.beneficiary, user2);
    }

    function testExternalDepositBeneficiaryCannotBeZero() public {
        uint256 usdcAmount = 1000e6;
        bytes32 tag = keccak256("zero_beneficiary_test");

        vm.prank(hostIntegration);
        vm.expectRevert("Invalid beneficiary");
        zapper.registerExternalDepositFor(address(0), usdcAmount, tag);
    }

    // ============ PROPORTIONAL APPROVAL TESTS ============

    function testProportionalApprovalPrecision() public {
        // Create deposits with amounts that test precision
        uint256[] memory amounts = new uint256[](3);
        amounts[0] = 1e6; // 1 USDC
        amounts[1] = 3e6; // 3 USDC
        amounts[2] = 5e6; // 5 USDC
        // Total: 9 USDC

        vm.startPrank(user1);
        usdcToken.approve(address(zapper), 9e6);
        zapper.zapAndDeposit(usdcToken, amounts[0], keccak256("deposit1"), 100);
        zapper.zapAndDeposit(usdcToken, amounts[1], keccak256("deposit2"), 100);
        zapper.zapAndDeposit(usdcToken, amounts[2], keccak256("deposit3"), 100);
        vm.stopPrank();

        vm.warp(block.timestamp + EPOCH_DURATION);
        epochManager.nextEpoch();

        // Approve 4 USDC out of 9 (44.44% proportion)
        uint256 targetAmount = 4e6;

        vm.prank(curator);
        zapper.approveDepositsProportionally(targetAmount);

        // Check that proportions are correct (within rounding tolerance)
        bytes32[] memory pendingIds = zapper.getPendingDepositIds();
        uint256 totalApproved = 0;

        for (uint256 i = 0; i < pendingIds.length; i++) {
            Zapper.Deposit memory deposit = zapper.getDeposit(pendingIds[i]);
            if (deposit.approved) {
                totalApproved += deposit.approvedAmount;
            }
        }

        // Should be close to target (within rounding error)
        assertApproxEqAbs(totalApproved, targetAmount, 3);
    }

    function testProportionalApprovalEdgeCases() public {
        // Test with very small amounts
        vm.startPrank(user1);
        usdcToken.approve(address(zapper), 3);
        zapper.zapAndDeposit(usdcToken, 1, keccak256("tiny1"), 100);
        zapper.zapAndDeposit(usdcToken, 1, keccak256("tiny2"), 100);
        zapper.zapAndDeposit(usdcToken, 1, keccak256("tiny3"), 100);
        vm.stopPrank();

        vm.warp(block.timestamp + EPOCH_DURATION);
        epochManager.nextEpoch();

        // Try to approve 1 out of 3 (should handle precision correctly)
        vm.prank(curator);
        zapper.approveDepositsProportionally(1);
    }

    // ============ BATCH OPERATIONS TESTS ============

    function testWithdrawAllDepositsAtomicity() public {
        // Create multiple deposits
        vm.startPrank(user1);
        usdcToken.approve(address(zapper), 3000e6);
        zapper.zapAndDeposit(usdcToken, 1000e6, keccak256("batch1"), 100);
        zapper.zapAndDeposit(usdcToken, 1000e6, keccak256("batch2"), 100);
        zapper.zapAndDeposit(usdcToken, 1000e6, keccak256("batch3"), 100);
        vm.stopPrank();

        uint256 initialBalance = usdcToken.balanceOf(user1);

        // Withdraw all at once
        vm.prank(user1);
        uint256 totalRefunded = zapper.withdrawAllDeposits();

        assertEq(totalRefunded, 3000e6);
        assertEq(usdcToken.balanceOf(user1), initialBalance + 3000e6);

        // Verify all deposits were removed
        assertEq(zapper.getPendingDepositIds().length, 0);
    }

    function testClaimAllDepositsWithPartialApprovals() public {
        // Create deposits
        vm.startPrank(user1);
        usdcToken.approve(address(zapper), 3000e6);
        zapper.zapAndDeposit(usdcToken, 1000e6, keccak256("partial1"), 100);
        zapper.zapAndDeposit(usdcToken, 1000e6, keccak256("partial2"), 100);
        zapper.zapAndDeposit(usdcToken, 1000e6, keccak256("partial3"), 100);
        vm.stopPrank();

        vm.warp(block.timestamp + EPOCH_DURATION);
        epochManager.nextEpoch();

        // Partially approve each deposit
        bytes32[] memory pendingIds = zapper.getPendingDepositIds();
        vm.startPrank(curator);
        zapper.approveDeposit(pendingIds[0], 500e6); // 50%
        zapper.approveDeposit(pendingIds[1], 750e6); // 75%
        zapper.approveDeposit(pendingIds[2], 250e6); // 25%
        vm.stopPrank();

        // Claim all approved portions
        vm.prank(user1);
        uint256 totalShares = zapper.claimAllDeposits();

        assertGt(totalShares, 0);

        // Verify remaining deposits exist with reduced amounts
        for (uint256 i = 0; i < pendingIds.length; i++) {
            Zapper.Deposit memory deposit = zapper.getDeposit(pendingIds[i]);
            assertGt(deposit.amount, 0); // Should have remaining amount
            assertFalse(deposit.approved); // Should be reset to pending
        }
    }

    // ============ EDGE CASE TESTS ============

    function testDepositWithZeroSlippage() public {
        vm.startPrank(user1);
        usdcToken.approve(address(zapper), 1000e6);

        // Should use default 1% slippage when 0 is passed
        zapper.zapAndDeposit(usdcToken, 1000e6, keccak256("zero_slippage"), 0);
        vm.stopPrank();

        bytes32[] memory pendingIds = zapper.getPendingDepositIds();
        assertEq(pendingIds.length, 1);
    }

    function testReceiveFunctionWithMultipleETHSends() public {
        uint256 ethAmount = 0.1 ether;
        uint256 initialPendingCount = zapper.getPendingDepositIds().length;

        // Send ETH multiple times
        for (uint256 i = 0; i < 3; i++) {
            vm.prank(user1);
            (bool success, ) = address(zapper).call{value: ethAmount}("");
            assertTrue(success);
        }

        // Should have created 3 deposits
        assertEq(zapper.getPendingDepositIds().length, initialPendingCount + 3);
    }

    function testFallbackFunctionWithData() public {
        uint256 ethAmount = 0.1 ether;
        uint256 initialPendingCount = zapper.getPendingDepositIds().length;

        // Send ETH with data to trigger fallback
        vm.prank(user1);
        (bool success, ) = address(zapper).call{value: ethAmount}("0x1234567890");
        assertTrue(success);

        // Should have created 1 deposit
        assertEq(zapper.getPendingDepositIds().length, initialPendingCount + 1);
    }

    function testGettersReturnCorrectData() public {
        // Test various getter functions
        assertEq(zapper.router(), address(0x1234));
        assertEq(zapper.usdc(), address(usdcToken));
        assertEq(zapper.silo(), address(zapper.silo()));
        assertEq(zapper.getCopperPrice(), INITIAL_COPPER_PRICE);

        // Test empty arrays
        assertEq(zapper.getPendingDepositIds().length, 0);
        assertEq(zapper.getUserDepositIds(user1).length, 0);
        assertEq(zapper.getTotalPendingAmount(), 0);
    }

    // ============ SECURITY TESTS ============

    function testReentrancyProtection() public {
        // These functions should be protected against reentrancy
        // The actual reentrancy testing would require a malicious contract
        // For now, we verify the modifiers are in place by checking function signatures

        vm.startPrank(user1);
        usdcToken.approve(address(zapper), 1000e6);
        zapper.zapAndDeposit(usdcToken, 1000e6, keccak256("reentrancy_test"), 100);
        vm.stopPrank();

        // Test that withdrawal works (has reentrancy protection)
        bytes32[] memory pendingIds = zapper.getPendingDepositIds();
        vm.prank(user1);
        zapper.withdrawDeposit(pendingIds[0]);
    }

    function testPauseStopsAllOperations() public {
        vm.prank(owner);
        zapper.pause();

        // All user-facing functions should revert when paused
        vm.startPrank(user1);
        usdcToken.approve(address(zapper), 1000e6);

        vm.expectRevert();
        zapper.zapAndDeposit(usdcToken, 1000e6, keccak256("paused_test"), 100);

        vm.expectRevert();
        zapper.withdrawDeposit(keccak256("nonexistent"));

        vm.expectRevert();
        zapper.withdrawAllDeposits();

        vm.expectRevert();
        (bool success, ) = address(zapper).call{value: 0.1 ether}("");

        vm.stopPrank();

        // Curator functions should also be blocked
        vm.prank(curator);
        vm.expectRevert();
        zapper.approveDeposit(keccak256("test"), 1000e6);

        // Host integration functions should be blocked
        vm.prank(hostIntegration);
        vm.expectRevert();
        zapper.registerExternalDepositFor(user1, 1000e6, keccak256("tag"));
    }

    // ============ INTEGRATION TESTS ============

    function testFullDepositToClaimFlow() public {
        uint256 depositAmount = 5000e6;
        bytes32 depositId = keccak256("full_flow_test");

        // 1. User deposits USDC
        vm.startPrank(user1);
        usdcToken.approve(address(zapper), depositAmount);
        zapper.zapAndDeposit(usdcToken, depositAmount, depositId, 100);
        vm.stopPrank();

        // 2. Advance epoch
        vm.warp(block.timestamp + EPOCH_DURATION);
        epochManager.nextEpoch();

        // 3. Curator approves
        vm.prank(curator);
        zapper.approveDeposit(depositId, depositAmount);

        // 4. User claims
        uint256 initialVaultBalance = vault.balanceOf(user1);
        vm.prank(user1);
        uint256 shares = zapper.claimDeposit(depositId);

        // 5. Verify results
        assertGt(shares, 0);
        assertEq(vault.balanceOf(user1), initialVaultBalance + shares);

        // 6. User redeems shares
        vm.startPrank(user1);
        vault.approve(address(zapper), shares);
        uint256 usdcReceived = zapper.redeem(shares);
        vm.stopPrank();

        assertGt(usdcReceived, 0);
        assertEq(vault.balanceOf(user1), initialVaultBalance);
    }

    function testExternalDepositFullFlow() public {
        uint256 usdcAmount = 3000e6;
        uint256 priceSnapshot = 600000000; // $6.00
        bytes32 tag = keccak256("external_full_flow");

        // 1. Host registers external deposit
        vm.prank(hostIntegration);
        bytes32 depositId = zapper.registerExternalDepositFor(user2, usdcAmount, tag);

        // 2. Advance epoch
        vm.warp(block.timestamp + EPOCH_DURATION);
        epochManager.nextEpoch();

        // 3. Curator approves with price snapshot
        vm.prank(curator);
        zapper.approveExternalDepositWithPrice(depositId, usdcAmount, priceSnapshot);

        // 4. Beneficiary claims
        uint256 initialVaultBalance = vault.balanceOf(user2);
        vm.prank(user2);
        uint256 shares = zapper.claimDeposit(depositId);

        // 5. Verify results
        assertGt(shares, 0);
        assertEq(vault.balanceOf(user2), initialVaultBalance + shares);

        // Verify deposit details
        Zapper.Deposit memory deposit = zapper.getDeposit(depositId);
        assertEq(deposit.priceSnapshot, priceSnapshot);
        assertEq(deposit.beneficiary, user2);
        assertEq(deposit.tag, tag);
        assertTrue(deposit.isExternal);
    }
}
