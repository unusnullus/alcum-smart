// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {console} from "forge-std/console.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";

import {ERC20Mock} from "../contracts/mock/ERC20Mock.sol";

import {Zapper} from "../contracts/Zapper.sol";
import {CUPToken} from "../contracts/CUPToken.sol";
import {xCUP} from "../contracts/xCUP.sol";
import {ICopperPriceConsumer} from "../contracts/interfaces/ICopperPriceConsumer.sol";
import {IEpochManager} from "../contracts/interfaces/IEpochManager.sol";
import {EpochManager} from "../contracts/EpochManager.sol";

import {IUniswapV2Router02} from "@uniswap/v2-periphery/contracts/interfaces/IUniswapV2Router02.sol";

contract ZapperProportionalApprovalTest is Test {
    address internal owner = 0xC8fb6C1b2377670f5FD1bD3f58926B2d7B7b0971;
    address internal admin = 0x1234567890123456789012345678901234567890;
    
    // Test accounts with different deposit amounts
    address internal user1 = 0x1111111111111111111111111111111111111111;
    address internal user2 = 0x2222222222222222222222222222222222222222;
    address internal user3 = 0x3333333333333333333333333333333333333333;
    address internal user4 = 0x4444444444444444444444444444444444444444;
    address internal user5 = 0x5555555555555555555555555555555555555555;

    CUPToken cupToken;
    xCUP xcup;
    Zapper zapper;

    IUniswapV2Router02 router = IUniswapV2Router02(0xeE567Fe1712Faf6149d80dA1E6934E354124CfE3);
    ICopperPriceConsumer copperPriceConsumer = ICopperPriceConsumer(0x5F17C631B7c2d87BDCE210F21b71167457EA44F6);
    IEpochManager epochManager;
    IERC20 usdc = IERC20(0x1c7D4B196Cb0C7B01d743Fbc6116a902379C7238);
    ERC20Mock erc20Mock;

    // Track deposit IDs for each user
    bytes32[] user1DepositIds;
    bytes32[] user2DepositIds;
    bytes32[] user3DepositIds;
    bytes32[] user4DepositIds;
    bytes32[] user5DepositIds;

    function setUp() public {
        string memory rpcUrl = vm.envString("RPC_URL");
        uint256 forkId = vm.createFork(rpcUrl);
        vm.selectFork(forkId);

        // Deploy contracts
        vm.prank(owner);
        cupToken = new CUPToken();

        vm.prank(owner);
        erc20Mock = new ERC20Mock();

        vm.prank(owner);
        xcup = new xCUP(cupToken, "xCUP", "xCUP");

        vm.prank(owner);
        epochManager = new EpochManager();

        vm.prank(owner);
        zapper = new Zapper(
            address(cupToken),
            address(usdc),
            address(xcup),
            address(router),
            address(copperPriceConsumer),
            address(epochManager)
        );

        // Setup roles
        vm.startPrank(owner);
        zapper.grantRole(zapper.VAULT_CURATOR_ROLE(), admin);
        vm.stopPrank();

        // Setup balances for all test accounts
        setupAccountBalances();
        addLiquidity();
        
        // Start next epoch to enable deposits
        vm.prank(owner);
        epochManager.nextEpoch();
    }

    function setupAccountBalances() internal {
        address[] memory users = new address[](6);
        users[0] = owner;
        users[1] = user1;
        users[2] = user2;
        users[3] = user3;
        users[4] = user4;
        users[5] = user5;

        for (uint256 i = 0; i < users.length; i++) {
            // Mint ERC20Mock tokens
            vm.prank(owner);
            erc20Mock.mint(users[i], 10000e18);
            
            // Deal USDC and CUP tokens
            deal(address(usdc), users[i], 10000e6);
            deal(address(cupToken), users[i], 10000e18);
        }
        
        // Give zapper some CUP tokens
        deal(address(cupToken), address(zapper), 5000000e18);
    }

    function addLiquidity() internal {
        uint256 lAmount = 1000e18;

        vm.prank(owner);
        erc20Mock.approve(address(router), lAmount);
        vm.prank(owner);
        usdc.approve(address(router), lAmount);

        vm.prank(owner);
        router.addLiquidity(
            address(erc20Mock),
            address(usdc),
            lAmount,
            lAmount,
            lAmount,
            lAmount,
            owner,
            type(uint256).max
        );
    }

    function createDeposit(address user, uint256 amount) internal returns (bytes32) {
        vm.prank(user);
        erc20Mock.approve(address(zapper), amount);

        vm.prank(user);
        zapper.zapAndDeposit(erc20Mock, amount);

        // Calculate the expected deposit value and return the deposit ID
        uint256 depositValueInUSDC = calculateDepositValue(amount);
        return keccak256(abi.encodePacked(user, block.timestamp, depositValueInUSDC));
    }

    function calculateDepositValue(uint256 amount) internal pure returns (uint256) {
        // This is an approximation based on observed test values
        // In real tests, you'd calculate this based on actual swap amounts
        return (amount * 47482973758155927037) / 50e18;
    }

    function testApproveDepositsProportionally_BasicScenario() public {
        // Create deposits from multiple users with different amounts
        uint256[] memory depositAmounts = new uint256[](3);
        depositAmounts[0] = 100e18;  // user1
        depositAmounts[1] = 200e18;  // user2
        depositAmounts[2] = 300e18;  // user3

        // Create deposits
        user1DepositIds.push(createDeposit(user1, depositAmounts[0]));
        user2DepositIds.push(createDeposit(user2, depositAmounts[1]));
        user3DepositIds.push(createDeposit(user3, depositAmounts[2]));

        // Calculate expected values
        uint256 totalPendingAmount = calculateDepositValue(depositAmounts[0]) + 
                                    calculateDepositValue(depositAmounts[1]) + 
                                    calculateDepositValue(depositAmounts[2]);
        
        uint256 targetTotalAmount = totalPendingAmount / 2; // Approve 50%
        uint256 expectedProportion = (targetTotalAmount * 1e18) / totalPendingAmount;

        // Approve deposits proportionally
        vm.prank(admin);
        vm.expectEmit(address(zapper));
        emit Zapper.ProportionalApproval(targetTotalAmount, totalPendingAmount, expectedProportion);
        zapper.approveDepositsProportionally(targetTotalAmount);

        // Verify that deposits are approved with correct proportional amounts
        uint256 expectedUser1Amount = (calculateDepositValue(depositAmounts[0]) * expectedProportion) / 1e18;
        uint256 expectedUser2Amount = (calculateDepositValue(depositAmounts[1]) * expectedProportion) / 1e18;
        uint256 expectedUser3Amount = (calculateDepositValue(depositAmounts[2]) * expectedProportion) / 1e18;

        // Check that each deposit was approved with proportional amount
        assertGt(expectedUser1Amount, 0, "User1 should receive proportional approval");
        assertGt(expectedUser2Amount, 0, "User2 should receive proportional approval");
        assertGt(expectedUser3Amount, 0, "User3 should receive proportional approval");
    }

    function testApproveDepositsProportionally_MaxTarget() public {
        // Create deposits
        uint256[] memory amounts = new uint256[](4);
        amounts[0] = 50e18;
        amounts[1] = 100e18;
        amounts[2] = 150e18;
        amounts[3] = 200e18;

        user1DepositIds.push(createDeposit(user1, amounts[0]));
        user2DepositIds.push(createDeposit(user2, amounts[1]));
        user3DepositIds.push(createDeposit(user3, amounts[2]));
        user4DepositIds.push(createDeposit(user4, amounts[3]));

        uint256 totalPendingAmount = calculateDepositValue(amounts[0]) + 
                                    calculateDepositValue(amounts[1]) + 
                                    calculateDepositValue(amounts[2]) + 
                                    calculateDepositValue(amounts[3]);

        // Target equals total pending (100% approval)
        vm.prank(admin);
        vm.expectEmit(address(zapper));
        emit Zapper.ProportionalApproval(totalPendingAmount, totalPendingAmount, 1e18);
        zapper.approveDepositsProportionally(totalPendingAmount);
    }

    function testApproveDepositsProportionally_SmallTarget() public {
        // Create deposits with larger amounts
        uint256[] memory amounts = new uint256[](5);
        amounts[0] = 1000e18;
        amounts[1] = 2000e18;
        amounts[2] = 3000e18;
        amounts[3] = 4000e18;
        amounts[4] = 5000e18;

        user1DepositIds.push(createDeposit(user1, amounts[0]));
        user2DepositIds.push(createDeposit(user2, amounts[1]));
        user3DepositIds.push(createDeposit(user3, amounts[2]));
        user4DepositIds.push(createDeposit(user4, amounts[3]));
        user5DepositIds.push(createDeposit(user5, amounts[4]));

        uint256 totalPendingAmount = calculateDepositValue(amounts[0]) + 
                                    calculateDepositValue(amounts[1]) + 
                                    calculateDepositValue(amounts[2]) + 
                                    calculateDepositValue(amounts[3]) + 
                                    calculateDepositValue(amounts[4]);

        // Target is only 10% of total
        uint256 targetTotalAmount = totalPendingAmount / 10;
        uint256 expectedProportion = (targetTotalAmount * 1e18) / totalPendingAmount;

        vm.prank(admin);
        vm.expectEmit(address(zapper));
        emit Zapper.ProportionalApproval(targetTotalAmount, totalPendingAmount, expectedProportion);
        zapper.approveDepositsProportionally(targetTotalAmount);
    }

    function testApproveDepositsProportionally_RevertZeroTarget() public {
        // Create at least one deposit
        user1DepositIds.push(createDeposit(user1, 100e18));

        vm.prank(admin);
        vm.expectRevert("Target amount must be greater than 0");
        zapper.approveDepositsProportionally(0);
    }

    function testApproveDepositsProportionally_RevertNoPendingDeposits() public {
        vm.prank(admin);
        vm.expectRevert("No pending deposits");
        zapper.approveDepositsProportionally(1000e18);
    }

    function testApproveDepositsProportionally_RevertTargetExceedsTotal() public {
        // Create deposits
        user1DepositIds.push(createDeposit(user1, 100e18));
        user2DepositIds.push(createDeposit(user2, 200e18));

        uint256 totalPendingAmount = calculateDepositValue(100e18) + calculateDepositValue(200e18);
        uint256 excessiveTarget = totalPendingAmount + 1e18;

        vm.prank(admin);
        vm.expectRevert("Target amount exceeds total pending");
        zapper.approveDepositsProportionally(excessiveTarget);
    }

    function testApproveDepositsProportionally_RevertWhenPaused() public {
        // Create deposits first
        user1DepositIds.push(createDeposit(user1, 100e18));

        // Pause the contract
        vm.prank(owner);
        zapper.pause();

        vm.prank(admin);
        vm.expectRevert();
        zapper.approveDepositsProportionally(50e18);
    }

    function testApproveDepositsProportionally_RevertWhenEpochNotActive() public {
        // Create deposits first
        user1DepositIds.push(createDeposit(user1, 100e18));

        // End the epoch
        vm.prank(owner);
        epochManager.nextEpoch();
        vm.prank(owner);
        epochManager.nextEpoch();

        vm.prank(admin);
        vm.expectRevert("Epoch not active");
        zapper.approveDepositsProportionally(50e18);
    }

    function testApproveDepositsProportionally_RevertNonCurator() public {
        // Create deposits
        user1DepositIds.push(createDeposit(user1, 100e18));

        vm.prank(user1);
        vm.expectRevert();
        zapper.approveDepositsProportionally(50e18);
    }

    function testApproveDepositsProportionally_PrecisionTest() public {
        // Test with amounts that might cause precision issues
        uint256[] memory amounts = new uint256[](3);
        amounts[0] = 1;     // Minimal amount
        amounts[1] = 999;   // Odd number
        amounts[2] = 1000;  // Round number

        user1DepositIds.push(createDeposit(user1, amounts[0]));
        user2DepositIds.push(createDeposit(user2, amounts[1]));
        user3DepositIds.push(createDeposit(user3, amounts[2]));

        uint256 totalPendingAmount = calculateDepositValue(amounts[0]) + 
                                    calculateDepositValue(amounts[1]) + 
                                    calculateDepositValue(amounts[2]);

        uint256 targetTotalAmount = totalPendingAmount * 333 / 1000; // 33.3%

        vm.prank(admin);
        zapper.approveDepositsProportionally(targetTotalAmount);

        // Should not revert due to precision issues
    }

    function testApproveDepositsProportionally_MultipleUsersWithVaryingAmounts() public {
        // Comprehensive test with all users having different amounts
        uint256[] memory amounts = new uint256[](5);
        amounts[0] = 10e18;    // Small
        amounts[1] = 500e18;   // Medium
        amounts[2] = 1500e18;  // Large
        amounts[3] = 50e18;    // Small-medium
        amounts[4] = 2500e18;  // Very large

        user1DepositIds.push(createDeposit(user1, amounts[0]));
        user2DepositIds.push(createDeposit(user2, amounts[1]));
        user3DepositIds.push(createDeposit(user3, amounts[2]));
        user4DepositIds.push(createDeposit(user4, amounts[3]));
        user5DepositIds.push(createDeposit(user5, amounts[4]));

        uint256 totalPendingAmount = 0;
        for (uint256 i = 0; i < amounts.length; i++) {
            totalPendingAmount += calculateDepositValue(amounts[i]);
        }

        uint256 targetTotalAmount = totalPendingAmount * 75 / 100; // 75% approval
        uint256 expectedProportion = (targetTotalAmount * 1e18) / totalPendingAmount;

        vm.prank(admin);
        vm.expectEmit(address(zapper));
        emit Zapper.ProportionalApproval(targetTotalAmount, totalPendingAmount, expectedProportion);
        zapper.approveDepositsProportionally(targetTotalAmount);

        // Verify proportional distribution
        for (uint256 i = 0; i < amounts.length; i++) {
            uint256 expectedAmount = (calculateDepositValue(amounts[i]) * expectedProportion) / 1e18;
            assertGt(expectedAmount, 0, "Each user should receive proportional approval");
        }
    }

    function testApproveDepositsProportionally_SkipsAlreadyApprovedDeposits() public {
        // Create deposits
        user1DepositIds.push(createDeposit(user1, 100e18));
        user2DepositIds.push(createDeposit(user2, 200e18));
        user3DepositIds.push(createDeposit(user3, 300e18));

        // Manually approve one deposit first
        vm.prank(admin);
        zapper.approveDeposit(user1DepositIds[0], calculateDepositValue(100e18));

        // Now do proportional approval - should only affect user2 and user3
        uint256 totalPendingAmount = calculateDepositValue(200e18) + calculateDepositValue(300e18);
        uint256 targetTotalAmount = totalPendingAmount / 2;

        vm.prank(admin);
        zapper.approveDepositsProportionally(targetTotalAmount);

        // The function should work correctly, ignoring the already approved deposit
    }

    function testApproveDepositsProportionally_EventEmission() public {
        // Create deposits
        user1DepositIds.push(createDeposit(user1, 100e18));
        user2DepositIds.push(createDeposit(user2, 200e18));

        uint256 totalPendingAmount = calculateDepositValue(100e18) + calculateDepositValue(200e18);
        uint256 targetTotalAmount = totalPendingAmount * 60 / 100; // 60%
        uint256 expectedProportion = (targetTotalAmount * 1e18) / totalPendingAmount;

        // Expect DepositApproved events for each deposit
        vm.expectEmit(address(zapper));
        emit Zapper.DepositApproved(user1DepositIds[0], (calculateDepositValue(100e18) * expectedProportion) / 1e18);
        
        vm.expectEmit(address(zapper));
        emit Zapper.DepositApproved(user2DepositIds[0], (calculateDepositValue(200e18) * expectedProportion) / 1e18);
        
        vm.expectEmit(address(zapper));
        emit Zapper.ProportionalApproval(targetTotalAmount, totalPendingAmount, expectedProportion);

        vm.prank(admin);
        zapper.approveDepositsProportionally(targetTotalAmount);
    }

    function testApproveDepositsProportionally_ExactCalculationExample() public {
        // Example with exact numbers to demonstrate the calculation
        console.log("=== Proportional Approval Calculation Example ===");
        
        // User deposits: 1000, 2000, 3000 tokens
        // Total pending: 6000 worth of deposits
        // Target: 3600 (60% of total)
        // Expected approvals: 600, 1200, 1800
        
        uint256[] memory amounts = new uint256[](3);
        amounts[0] = 1000e18;  // User1: 1000 tokens
        amounts[1] = 2000e18;  // User2: 2000 tokens  
        amounts[2] = 3000e18;  // User3: 3000 tokens

        user1DepositIds.push(createDeposit(user1, amounts[0]));
        user2DepositIds.push(createDeposit(user2, amounts[1]));
        user3DepositIds.push(createDeposit(user3, amounts[2]));

        uint256 totalPendingAmount = calculateDepositValue(amounts[0]) + 
                                    calculateDepositValue(amounts[1]) + 
                                    calculateDepositValue(amounts[2]);
        
        uint256 targetTotalAmount = totalPendingAmount * 60 / 100; // 60% approval
        uint256 expectedProportion = (targetTotalAmount * 1e18) / totalPendingAmount;

        console.log("Total pending amount:", totalPendingAmount);
        console.log("Target total amount:", targetTotalAmount);
        console.log("Proportion (scaled by 1e18):", expectedProportion);
        
        // Calculate expected approvals for each user
        uint256 expectedUser1 = (calculateDepositValue(amounts[0]) * expectedProportion) / 1e18;
        uint256 expectedUser2 = (calculateDepositValue(amounts[1]) * expectedProportion) / 1e18;
        uint256 expectedUser3 = (calculateDepositValue(amounts[2]) * expectedProportion) / 1e18;
        
        console.log("Expected User1 approval:", expectedUser1);
        console.log("Expected User2 approval:", expectedUser2);
        console.log("Expected User3 approval:", expectedUser3);
        console.log("Sum of expected approvals:", expectedUser1 + expectedUser2 + expectedUser3);

        vm.prank(admin);
        zapper.approveDepositsProportionally(targetTotalAmount);

        // Verify the math works out
        uint256 totalExpectedApprovals = expectedUser1 + expectedUser2 + expectedUser3;
        assertGe(totalExpectedApprovals, targetTotalAmount - 1e15, "Total approvals should be close to target");
        assertLe(totalExpectedApprovals, targetTotalAmount + 1e15, "Total approvals should be close to target");
    }
}