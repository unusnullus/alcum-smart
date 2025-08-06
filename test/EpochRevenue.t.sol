// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {console} from "forge-std/console.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";

import {ERC20Mock} from "../contracts/mock/ERC20Mock.sol";
import {CUPToken} from "../contracts/CUPToken.sol";
import {xCUP} from "../contracts/xCUP.sol";
import {SettlementEngine} from "../contracts/SettlementEngine.sol";
import {EpochManager} from "../contracts/EpochManager.sol";

contract EpochRevenueTest is Test {
    address internal owner = 0xC8fb6C1b2377670f5FD1bD3f58926B2d7B7b0971;
    address internal treasury = 0x1234567890123456789012345678901234567890;
    address internal user1 = 0x1111111111111111111111111111111111111111;
    address internal user2 = 0x2222222222222222222222222222222222222222;

    CUPToken cupToken;
    xCUP xcup;
    SettlementEngine settlementEngine;
    EpochManager epochManager;

    function setUp() public {
        // Deploy contracts
        vm.prank(owner);
        cupToken = new CUPToken();

        vm.prank(owner);
        epochManager = new EpochManager();

        vm.prank(owner);
        xcup = new xCUP(cupToken, "xCUP", "xCUP");

        vm.prank(owner);
        settlementEngine = new SettlementEngine(
            address(xcup),
            treasury,
            address(epochManager)
        );

        // Setup xCUP with settlement engine
        vm.prank(owner);
        xcup.setSettlementEngine(address(settlementEngine));

        // Setup initial balances
        deal(address(cupToken), owner, 1000000e6);
        deal(address(cupToken), address(xcup), 500000e6);

        // Setup users with some CUP tokens
        deal(address(cupToken), user1, 10000e6);
        deal(address(cupToken), user2, 15000e6);
    }

    function testEpochRevenueCalculation() public {
        // User1 deposits CUP tokens
        vm.startPrank(user1);
        cupToken.approve(address(xcup), 5000e6);
        xcup.deposit(5000e6, user1);
        vm.stopPrank();

        // User2 deposits CUP tokens
        vm.startPrank(user2);
        cupToken.approve(address(xcup), 7500e6);
        xcup.deposit(7500e6, user2);
        vm.stopPrank();

        // Record epoch 1 revenue
        vm.prank(owner);
        settlementEngine.recordEpochRevenue(
            1, // epochId
            100000e6, // totalRevenue (100,000 CUP)
            15000e6,  // processingCosts
            5000e6,   // logisticsCosts
            3000e6,   // tradingCosts
            20000e6,  // cupPurchased
            25000e6,  // cupSold
            5000,     // averagePurchasePrice (5.00)
            6000      // averageSalePrice (6.00)
        );

        // Settle epoch 1
        vm.prank(owner);
        settlementEngine.settleEpochRevenue(1);

        // Distribute revenue to vault
        vm.prank(owner);
        settlementEngine.distributeRevenueToVault(1);

        // Check ROI calculation
        uint256 roi = settlementEngine.calculateEpochROI(1);
        console.log("Epoch 1 ROI (basis points):", roi);

        // Users claim revenue
        vm.prank(user1);
        uint256 user1Revenue = xcup.claimRevenue(1);
        console.log("User1 claimed revenue:", user1Revenue);

        vm.prank(user2);
        uint256 user2Revenue = xcup.claimRevenue(1);
        console.log("User2 claimed revenue:", user2Revenue);

        // Verify revenue distribution
        assertGt(user1Revenue, 0, "User1 should receive revenue");
        assertGt(user2Revenue, 0, "User2 should receive revenue");
        
        // User2 should receive more revenue due to more shares
        assertGt(user2Revenue, user1Revenue, "User2 should receive more revenue");
    }

    function testMultipleEpochs() public {
        // Setup initial deposits
        vm.startPrank(user1);
        cupToken.approve(address(xcup), 10000e6);
        xcup.deposit(10000e6, user1);
        vm.stopPrank();

        // Epoch 1 - Good performance
        vm.prank(owner);
        settlementEngine.recordEpochRevenue(
            1, // epochId
            120000e6, // totalRevenue
            20000e6,  // processingCosts
            8000e6,   // logisticsCosts
            4000e6,   // tradingCosts
            25000e6,  // cupPurchased
            30000e6,  // cupSold
            5000,     // averagePurchasePrice
            6500      // averageSalePrice
        );

        vm.prank(owner);
        settlementEngine.settleEpochRevenue(1);

        vm.prank(owner);
        settlementEngine.distributeRevenueToVault(1);

        // Advance to epoch 2
        vm.prank(owner);
        settlementEngine.advanceEpoch();

        // Epoch 2 - Even better performance
        vm.prank(owner);
        settlementEngine.recordEpochRevenue(
            2, // epochId
            150000e6, // totalRevenue
            25000e6,  // processingCosts
            10000e6,  // logisticsCosts
            5000e6,   // tradingCosts
            30000e6,  // cupPurchased
            35000e6,  // cupSold
            5200,     // averagePurchasePrice
            7000      // averageSalePrice
        );

        vm.prank(owner);
        settlementEngine.settleEpochRevenue(2);

        vm.prank(owner);
        settlementEngine.distributeRevenueToVault(2);

        // User claims revenue from both epochs
        vm.prank(user1);
        uint256 epoch1Revenue = xcup.claimRevenue(1);
        uint256 epoch2Revenue = xcup.claimRevenue(2);

        console.log("Epoch 1 revenue:", epoch1Revenue);
        console.log("Epoch 2 revenue:", epoch2Revenue);

        // Epoch 2 should have higher revenue due to better performance
        assertGt(epoch2Revenue, epoch1Revenue, "Epoch 2 should have higher revenue");
    }

    function testRevenuePerShareCalculation() public {
        // User deposits
        vm.startPrank(user1);
        cupToken.approve(address(xcup), 10000e6);
        xcup.deposit(10000e6, user1);
        vm.stopPrank();

        // Record revenue
        vm.prank(owner);
        settlementEngine.recordEpochRevenue(
            1, // epochId
            50000e6, // totalRevenue
            10000e6, // processingCosts
            5000e6,  // logisticsCosts
            2000e6,  // tradingCosts
            15000e6, // cupPurchased
            18000e6, // cupSold
            4800,    // averagePurchasePrice
            5800     // averageSalePrice
        );

        vm.prank(owner);
        settlementEngine.settleEpochRevenue(1);

        vm.prank(owner);
        settlementEngine.distributeRevenueToVault(1);

        // Check revenue per share
        uint256 revenuePerShare = xcup.epochRevenuePerShare(1);
        console.log("Revenue per share:", revenuePerShare);

        // User claims revenue
        vm.prank(user1);
        uint256 claimedRevenue = xcup.claimRevenue(1);
        console.log("Claimed revenue:", claimedRevenue);

        // Verify the calculation
        uint256 userShares = xcup.balanceOf(user1);
        uint256 expectedRevenue = userShares * revenuePerShare;
        assertEq(claimedRevenue, expectedRevenue, "Revenue calculation should be correct");
    }

    function testGetClaimableRevenue() public {
        // User deposits
        vm.startPrank(user1);
        cupToken.approve(address(xcup), 10000e6);
        xcup.deposit(10000e6, user1);
        vm.stopPrank();

        // Setup multiple epochs
        for (uint256 i = 1; i <= 3; i++) {
            vm.prank(owner);
            settlementEngine.recordEpochRevenue(
                i, // epochId
                50000e6, // totalRevenue
                10000e6, // processingCosts
                5000e6,  // logisticsCosts
                2000e6,  // tradingCosts
                15000e6, // cupPurchased
                18000e6, // cupSold
                4800,    // averagePurchasePrice
                5800     // averageSalePrice
            );

            vm.prank(owner);
            settlementEngine.settleEpochRevenue(i);

            vm.prank(owner);
            settlementEngine.distributeRevenueToVault(i);

            if (i < 3) {
                vm.prank(owner);
                settlementEngine.advanceEpoch();
            }
        }

        // Check claimable revenue for each epoch
        for (uint256 i = 1; i <= 3; i++) {
            uint256 claimable = xcup.getClaimableRevenue(user1, i);
            console.log("Epoch", i, "claimable revenue:", claimable);
            assertGt(claimable, 0, "Should have claimable revenue for each epoch");
        }

        // Check total claimable revenue
        uint256 totalClaimable = xcup.getTotalClaimableRevenue(user1);
        console.log("Total claimable revenue:", totalClaimable);
        assertGt(totalClaimable, 0, "Should have total claimable revenue");
    }
} 