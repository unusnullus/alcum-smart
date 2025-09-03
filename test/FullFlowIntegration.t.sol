// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import "forge-std/Test.sol";
import {console} from "forge-std/console.sol";

import {Upgrades, Options} from "openzeppelin-foundry-upgrades/Upgrades.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {CUPToken} from "../contracts/CUPToken.sol";
import {xCUP} from "../contracts/xCUP.sol";
import {Zapper} from "../contracts/Zapper.sol";
import {EpochManager, IEpochManager} from "../contracts/EpochManager.sol";
import {SettlementEngine} from "../contracts/SettlementEngine.sol";
import {CopperPriceConsumerMock} from "../contracts/mock/CopperPriceConsumerMock.sol";
import {ERC20Mock} from "../contracts/mock/ERC20Mock.sol";

// Mock Uniswap Router for testing
contract MockUniswapRouter {
    mapping(address => mapping(address => uint256)) public rates;

    constructor() {}

    function setRate(address tokenA, address tokenB, uint256 rate) external {
        rates[tokenA][tokenB] = rate;
    }

    function getAmountsOut(uint256 amountIn, address[] memory path) external view returns (uint256[] memory amounts) {
        amounts = new uint256[](path.length);
        amounts[0] = amountIn;

        for (uint256 i = 1; i < path.length; i++) {
            uint256 rate = rates[path[i - 1]][path[i]];
            if (rate == 0) rate = 1e18; // Default 1:1 rate
            amounts[i] = (amounts[i - 1] * rate) / 1e18;
        }
    }

    function swapExactTokensForTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] memory path,
        address to,
        uint256 deadline
    ) external returns (uint256[] memory amounts) {
        amounts = this.getAmountsOut(amountIn, path);

        // Transfer tokens
        IERC20(path[0]).transferFrom(msg.sender, address(this), amountIn);
        IERC20(path[1]).transfer(to, amounts[1]);
    }

    function swapExactETHForTokens(
        uint256 amountOutMin,
        address[] memory path,
        address to,
        uint256 deadline
    ) external payable returns (uint256[] memory amounts) {
        amounts = this.getAmountsOut(msg.value, path);
        IERC20(path[1]).transfer(to, amounts[1]);
    }

    function WETH() public pure returns (address) {
        return 0xfFf9976782d46CC05630D1f6eBAb18b2324d6B14;
    }
}

contract FullFlowIntegrationTest is Test {
    // Core contracts
    CUPToken public cupToken;
    xCUP public xcupVault;
    Zapper public zapper;
    IEpochManager public epochManager;
    SettlementEngine public settlementEngine;

    // Mock contracts
    CopperPriceConsumerMock public priceConsumer;
    ERC20Mock public usdcToken;
    ERC20Mock public wethToken;
    MockUniswapRouter public router;

    // Test actors
    address public owner;
    address public curator;
    address public treasury;
    address public user1;
    address public user2;
    address public user3;

    // Test constants
    uint256 constant INITIAL_COPPER_PRICE = 5e8; // $5 with 8 decimals
    uint256 constant INITIAL_CUP_SUPPLY = 100_000_000e6; // 100M CUP tokens
    uint256 constant EPOCH_DURATION = 30 days;

    function setUp() public {
        string memory rpcUrl = vm.envString("RPC_URL");
        uint256 forkId = vm.createFork(rpcUrl);
        vm.selectFork(forkId);

        // Set up test actors
        owner = makeAddr("owner");
        curator = makeAddr("curator");
        treasury = makeAddr("treasury");
        user1 = makeAddr("user1");
        user2 = makeAddr("user2");
        user3 = makeAddr("user3");

        vm.startPrank(owner);

        // Deploy mock tokens
        usdcToken = new ERC20Mock("USDC", "USDC", 6);
        wethToken = new ERC20Mock("WETH", "WETH", 18);

        // Deploy mock router
        router = new MockUniswapRouter();

        router.setRate(router.WETH(), address(usdcToken), 1e6); // ETH rate

        // Deploy price consumer
        priceConsumer = new CopperPriceConsumerMock();

        // Deploy CUP token
        cupToken = new CUPToken();

        // Deploy xCUP vault
        address xcupProxy = Upgrades.deployTransparentProxy(
            "xCUP.sol:xCUP",
            owner,
            abi.encodeCall(xCUP.initialize, (IERC20(address(cupToken)), "xCUP", "xCUP"))
        );
        xcupVault = xCUP(xcupProxy);

        // Deploy EpochManager
        address epochManagerProxy = Upgrades.deployTransparentProxy(
            "EpochManager.sol:EpochManager",
            owner,
            abi.encodeCall(EpochManager.initialize, (2592000))
        );
        epochManager = IEpochManager(epochManagerProxy);

        // Deploy SettlementEngine
        address settlementEngineProxy = Upgrades.deployTransparentProxy(
            "SettlementEngine.sol:SettlementEngine",
            owner,
            abi.encodeCall(
                SettlementEngine.initialize,
                (address(xcupVault), treasury, address(epochManager), address(priceConsumer), address(usdcToken), 600)
            )
        );
        settlementEngine = SettlementEngine(settlementEngineProxy);

        // Deploy Zapper
        address zapperProxy = Upgrades.deployTransparentProxy(
            "Zapper.sol:Zapper",
            owner,
            abi.encodeCall(
                Zapper.initialize,
                (
                    address(cupToken),
                    address(usdcToken),
                    address(xcupVault),
                    address(router),
                    address(priceConsumer),
                    address(epochManager)
                )
            )
        );
        zapper = Zapper(zapperProxy);

        // Set up roles and permissions
        cupToken.grantRole(cupToken.MINTER_ROLE(), address(settlementEngine));
        cupToken.grantRole(cupToken.MINTER_ROLE(), address(zapper));
        cupToken.grantRole(cupToken.MINTER_ROLE(), owner);

        zapper.grantRole(zapper.VAULT_CURATOR_ROLE(), curator);

        xcupVault.grantRole(xcupVault.REDEEMER_ROLE(), address(zapper));

        // Fund mock tokens to router for swaps
        usdcToken.mint(address(router), 1_000_000_000_000e6);
        wethToken.mint(address(router), 1_000_000e18);

        // Fund zapper with CUP tokens for conversions
        cupToken.mint(address(zapper), 1_000_000_000_000_000e6);

        // Fund test users
        _fundUsers();

        vm.stopPrank();
    }

    function _fundUsers() internal {
        // Fund users with various tokens
        uint256 userFunding = 10_000e6; // 10k USDC

        usdcToken.mint(user1, userFunding);
        usdcToken.mint(user2, userFunding);
        usdcToken.mint(user3, userFunding);

        wethToken.mint(user1, 5e18); // 5 ETH
        wethToken.mint(user2, 5e18);

        // Fund zapper with CUP tokens for conversions
        cupToken.mint(address(zapper), 1_000_000e6);

        // Fund settlement engine for revenue distribution
        cupToken.mint(address(settlementEngine), 500_000e6);
    }

    // ================================================================
    // FULL FLOW TESTS
    // ================================================================

    function test_FullFlow_BasicInvestmentCycle() public {
        console.log("=== STARTING FULL FLOW TEST ===");

        // Phase 1: Users make investments
        _testUserInvestments();

        console.log("Silo balance after user investments", usdcToken.balanceOf(zapper.silo()));

        // Phase 2: Start epoch (required for deposits)
        _testStartEpoch();

        // Phase 3: Curator approves deposits
        _testCuratorApprovals();

        // Phase 4: Users claim their xCUP shares
        _testUserClaims();

        // Phase 5: Advance epoch for business operations
        _testAdvanceEpoch();

        // Phase 6: Business operations (copper processing)
        _testBusinessOperations();

        // Phase 7: Revenue settlement and distribution
        _testRevenueDistribution();

        // Phase 8: Users redeem with profit
        _testUserRedemptions();

        console.log("Silo balance after user redemptions", usdcToken.balanceOf(zapper.silo()));

        console.log("=== FULL FLOW TEST COMPLETED ===");
    }

    function _testUserInvestments() internal {
        console.log("\n--- Phase 1: User Investments ---");

        // User1: Direct USDC deposit
        vm.startPrank(user1);
        usdcToken.approve(address(zapper), 1000e6);
        bytes32 depositId1 = zapper.zapAndDeposit(IERC20(address(usdcToken)), 1000e6);
        console.log("User1 deposited 1000 USDC, depositId:", vm.toString(abi.encode(depositId1)));
        vm.stopPrank();

        // User2: ETH deposit (requires swap)
        vm.startPrank(user2);
        vm.deal(user2, 1 ether);
        bytes32 depositId2 = zapper.zapAndDeposit{value: 1 ether}(
            IERC20(0xfFf9976782d46CC05630D1f6eBAb18b2324d6B14),
            1 ether
        );
        console.log("User2 deposited 1 ETH, depositId:", vm.toString(abi.encode(depositId2)));
        vm.stopPrank();

        // User3: Smaller USDC deposit
        vm.startPrank(user3);
        usdcToken.approve(address(zapper), 500e6);
        bytes32 depositId3 = zapper.zapAndDeposit(IERC20(address(usdcToken)), 500e6);
        console.log("User3 deposited 500 USDC, depositId:", vm.toString(abi.encode(depositId3)));
        vm.stopPrank();

        uint256 totalPending = zapper.getTotalPendingAmount();
        console.log("Total pending amount:", totalPending);
        assertTrue(totalPending > 0, "Should have pending deposits");
    }

    function _testStartEpoch() internal {
        console.log("\n--- Phase 2: Start Epoch ---");

        vm.startPrank(owner);

        // Start the first epoch
        epochManager.nextEpoch();

        uint256 currentEpoch = epochManager.currentEpochId();
        uint256 timeLeft = epochManager.timeLeftInEpoch();

        console.log("Current epoch:", currentEpoch);
        console.log("Time left in epoch:", timeLeft);

        assertTrue(timeLeft > 0, "Epoch should be active");

        vm.stopPrank();
    }

    function _testCuratorApprovals() internal {
        console.log("\n--- Phase 3: Curator Approvals ---");

        vm.startPrank(curator);

        // Get pending deposit IDs
        bytes32[] memory pendingIds = zapper.getPendingDepositIds();

        // Approve all deposits proportionally (approve 80% of total)
        uint256 totalPending = zapper.getTotalPendingAmount();
        uint256 targetAmount = (totalPending * 80) / 100;

        console.log("Approving");

        zapper.approveDepositsProportionally(targetAmount);

        vm.stopPrank();

        // Verify approvals
        for (uint256 i = 0; i < pendingIds.length; i++) {
            Zapper.Deposit memory deposit = zapper.getDeposit(pendingIds[i]);
            assertTrue(deposit.approved, "Deposit should be approved");
            assertTrue(deposit.approvedAmount > 0, "Should have approved amount");
            console.log("Deposit", i, "approved for:", deposit.approvedAmount);
        }
    }

    function _testUserClaims() internal {
        console.log("\n--- Phase 4: User Claims ---");

        bytes32[] memory pendingIds = zapper.getPendingDepositIds();

        // User1 claims
        vm.startPrank(user1);
        uint256 shares1 = zapper.claimDeposit(pendingIds[0]);
        console.log("User1 received", shares1, "xCUP shares");
        assertTrue(shares1 > 0, "User1 should receive shares");
        vm.stopPrank();

        // User2 claims
        vm.startPrank(user2);
        uint256 shares2 = zapper.claimDeposit(pendingIds[1]);
        console.log("User2 received", shares2, "xCUP shares");
        assertTrue(shares2 > 0, "User2 should receive shares");
        vm.stopPrank();

        // User3 claims
        vm.startPrank(user3);
        uint256 shares3 = zapper.claimDeposit(pendingIds[2]);
        console.log("User3 received", shares3, "xCUP shares");
        assertTrue(shares3 > 0, "User3 should receive shares");
        vm.stopPrank();

        // Verify total supply increased
        uint256 totalSupply = xcupVault.totalSupply();
        console.log("Total xCUP supply:", totalSupply);
        assertTrue(totalSupply > 0, "Vault should have total supply");

        // Verify individual balances
        assertEq(xcupVault.balanceOf(user1), shares1, "User1 balance should match");
        assertEq(xcupVault.balanceOf(user2), shares2, "User2 balance should match");
        assertEq(xcupVault.balanceOf(user3), shares3, "User3 balance should match");
    }

    function _testAdvanceEpoch() internal {
        console.log("\n--- Phase 5: Advance Epoch ---");

        vm.startPrank(owner);

        // Warp time to end of current epoch
        uint256 epochDuration = epochManager.epochDuration();
        vm.warp(block.timestamp + epochDuration + 1);

        // Advance to next epoch
        // epochManager.nextEpoch();

        // uint256 currentEpoch = epochManager.currentEpochId();
        // uint256 timeLeft = epochManager.timeLeftInEpoch();

        // console.log("Advanced to epoch:", currentEpoch);
        // console.log("Time left in new epoch:", timeLeft);

        // assertTrue(timeLeft > 0, "New epoch should be active");

        vm.stopPrank();
    }

    function _testBusinessOperations() internal {
        console.log("\n--- Phase 6: Business Operations ---");

        vm.startPrank(owner);

        // Update NAV with current business state
        SettlementEngine.NAVComponents memory nav = SettlementEngine.NAVComponents({
            cupInWarehouse: 5_000_000, // 5 tons of refined copper
            copperSpotPrice: 500, // $0.50 per unit
            cupInTransit: 1_000_000, // 1 ton being processed
            retainedEarnings: 0, // No previous earnings
            stablecoinBalance: 2_000_000, // $2000 cash
            liabilities: 500_000 // $500 obligations
        });

        settlementEngine.updateNAV(nav);
        console.log("NAV updated with business assets");

        // Record epoch revenue (simulating completed copper trading cycle)
        uint256 epochId = 1;
        settlementEngine.recordEpochRevenue(
            epochId,
            300_000_000, // $300 net revenue after all costs in USDC
            1_200_000, // 1.2 tons raw copper purchased
            1_200_000, // 1.2 tons refined copper sold
            250, // $0.25 average purchase price
            500 // $0.50 average sale price
        );

        console.log("Recorded epoch revenue: $300 profit from copper operations");

        // Verify revenue recording
        SettlementEngine.EpochRevenue memory revenue = settlementEngine.getEpochRevenue(epochId);
        assertEq(revenue.netRevenue, 300_000_000, "Net revenue should be recorded");
        assertEq(revenue.cupPurchased, 1_200_000, "Copper purchased should be recorded");
        assertEq(revenue.cupSold, 1_200_000, "Copper sold should be recorded");
        assertFalse(revenue.isSettled, "Revenue should not be settled yet");

        vm.stopPrank();
    }

    function _testRevenueDistribution() internal {
        console.log("\n--- Phase 7: Revenue Distribution ---");

        vm.startPrank(owner);

        uint256 epochId = 1;

        // Get initial share price
        (, , uint256 initialPricePerShare) = settlementEngine.getNAVSummary();
        console.log("Initial price per share:", initialPricePerShare);

        // Settle the epoch
        settlementEngine.settleEpochRevenue(epochId);
        console.log("Epoch settled");

        // Verify epoch is settled
        SettlementEngine.EpochRevenue memory revenue = settlementEngine.getEpochRevenue(epochId);
        assertTrue(revenue.isSettled, "Epoch should be settled");

        // Approve USDC to be burned to mint CUP tokens
        usdcToken.mint(address(owner), revenue.netRevenue);
        usdcToken.approve(address(settlementEngine), revenue.netRevenue);

        // Distribute revenue to vault (this increases share value)
        settlementEngine.distributeRevenueToVault(epochId);
        console.log("Revenue distributed to vault");

        // Verify revenue was distributed
        revenue = settlementEngine.getEpochRevenue(epochId);
        assertEq(revenue.netRevenue, 0, "Revenue should be zeroed after distribution");

        // Check fee collection
        uint256 systemFee = settlementEngine.getEpochFees(epochId);
        uint256 originalRevenue = revenue.originalNetRevenue;
        uint256 expectedSystemFee = (originalRevenue * 600) / 10000; // 6% fee
        assertEq(systemFee, expectedSystemFee, "System fee should be correctly calculated");
        console.log("System fee collected:", systemFee);
        console.log("Expected system fee (6%):", expectedSystemFee);

        // Verify net revenue after fees
        uint256 netRevenueAfterFees = originalRevenue - systemFee;
        console.log("Original revenue:", originalRevenue);
        console.log("Net revenue after fees:", netRevenueAfterFees);
        console.log("Fee percentage:", (systemFee * 10000) / originalRevenue, "basis points");

        // Check that treasury received the fees
        uint256 treasuryBalance = usdcToken.balanceOf(treasury);
        console.log("Treasury USDC balance after distribution:", treasuryBalance);
        assertTrue(treasuryBalance >= systemFee, "Treasury should have received the system fee");

        // Check that vault's total assets increased
        uint256 vaultAssets = xcupVault.totalAssets();
        console.log("Vault total assets after distribution:", vaultAssets);

        // Calculate analytics
        uint256 roi = settlementEngine.calculateEpochROI(epochId);
        uint256 efficiency = settlementEngine.getCopperProcessingEfficiency(epochId);
        uint256 margin = settlementEngine.getProfitMargin(epochId);

        console.log("ROI (basis points):", roi);
        console.log("Processing efficiency (basis points):", efficiency);
        console.log("Profit margin (basis points):", margin);

        assertTrue(roi > 0, "ROI should be positive");
        assertEq(efficiency, 10000, "Efficiency should be 100% (1.2/1.2)");
        assertTrue(margin > 0, "Profit margin should be positive");

        vm.stopPrank();
    }

    function _testUserRedemptions() internal {
        console.log("\n--- Phase 8: User Redemptions ---");

        // Check share values before redemption
        uint256 user1Shares = xcupVault.balanceOf(user1);
        uint256 user2Shares = xcupVault.balanceOf(user2);
        uint256 user3Shares = xcupVault.balanceOf(user3);

        console.log("User1 shares before redemption:", user1Shares);
        console.log("User2 shares before redemption:", user2Shares);
        console.log("User3 shares before redemption:", user3Shares);

        // User1 redeems half their shares
        vm.startPrank(user1);
        uint256 redeemAmount1 = user1Shares / 2;
        xcupVault.approve(address(zapper), redeemAmount1);

        uint256 usdcBefore1 = usdcToken.balanceOf(user1);
        uint256 usdcReceived1 = zapper.redeem(redeemAmount1);
        uint256 usdcAfter1 = usdcToken.balanceOf(user1);

        console.log("User1 USDC before redemption:", usdcBefore1);
        console.log("User1 USDC after redemption:", usdcAfter1);
        console.log("User1 USDC received:", usdcReceived1);

        assertTrue(usdcAfter1 > usdcBefore1, "User1 should receive USDC");
        vm.stopPrank();

        // User2 redeems all shares
        vm.startPrank(user2);
        xcupVault.approve(address(zapper), user2Shares);

        uint256 usdcBefore2 = usdcToken.balanceOf(user2);
        uint256 usdcReceived2 = zapper.redeem(user2Shares);
        uint256 usdcAfter2 = usdcToken.balanceOf(user2);

        console.log("User2 USDC before redemption:", usdcBefore2);
        console.log("User2 USDC after redemption:", usdcAfter2);
        console.log("User2 USDC received:", usdcReceived2);

        assertTrue(usdcAfter2 > usdcBefore2, "User2 should receive USDC");

        // Verify User2 has no more shares
        assertEq(xcupVault.balanceOf(user2), 0, "User2 should have no shares left");
        vm.stopPrank();

        // User3 keeps their shares for next epoch
        console.log("User3 keeps", xcupVault.balanceOf(user3), "shares for next epoch");
    }

    // ================================================================
    // ADDITIONAL TEST SCENARIOS
    // ================================================================

    function test_MultipleEpochFlow() public {
        console.log("=== TESTING MULTIPLE EPOCH FLOW ===");

        // Start epoch
        _testStartEpoch();

        // Set up initial investment
        _quickInvestment(user1, 1000e6);

        // First epoch
        _runEpochCycle(1, 200_000, 1_000_000, 1_000_000);

        // Advance to next epoch
        vm.startPrank(owner);
        vm.warp(block.timestamp + EPOCH_DURATION + 1);
        epochManager.nextEpoch();
        settlementEngine.advanceEpoch();
        vm.stopPrank();

        // Second epoch with higher profits
        _runEpochCycle(2, 400_000, 1_500_000, 1_500_000);

        // Verify cumulative effects
        (, , uint256 finalPricePerShare) = settlementEngine.getNAVSummary();
        console.log("Final price per share after 2 epochs:", finalPricePerShare);

        // Mint enough USDC to Silo to cover the redemption
        usdcToken.mint(zapper.silo(), 22559);

        // User should have significant gains
        vm.startPrank(user1);
        xcupVault.approve(address(zapper), xcupVault.balanceOf(user1));
        uint256 finalUSDC = zapper.redeem(xcupVault.balanceOf(user1));
        console.log("User1 final redemption:", finalUSDC);
        assertTrue(finalUSDC > 1000e6, "User should have profit after 2 epochs");
        vm.stopPrank();
    }

    function test_LargeScaleOperations() public {
        console.log("=== TESTING LARGE SCALE OPERATIONS ===");

        // Start epoch
        _testStartEpoch();

        usdcToken.mint(user2, 25_000e6);

        // Multiple large investors
        _quickInvestment(user1, 10_000e6); // $10k
        _quickInvestment(user2, 25_000e6); // $25k
        _quickInvestment(user3, 5_000e6); // $5k

        // Large scale copper operations
        vm.startPrank(owner);
        settlementEngine.recordEpochRevenue(
            1,
            12_000_000, // $12k profit
            50_000_000, // 50 tons purchased
            48_000_000, // 48 tons sold (96% efficiency)
            300, // $0.30 purchase
            650 // $0.65 sale
        );

        // Approve USDC to be burned to mint CUP tokens
        usdcToken.mint(address(owner), 12_000_000);
        usdcToken.approve(address(settlementEngine), 12_000_000);

        settlementEngine.settleEpochRevenue(1);
        settlementEngine.distributeRevenueToVault(1);
        vm.stopPrank();

        // Verify proportional distribution
        uint256 totalShares = xcupVault.totalSupply();
        uint256 user1Portion = (xcupVault.balanceOf(user1) * 100) / totalShares;
        uint256 user2Portion = (xcupVault.balanceOf(user2) * 100) / totalShares;
        uint256 user3Portion = (xcupVault.balanceOf(user3) * 100) / totalShares;

        console.log("User1 owns", user1Portion, "% of shares");
        console.log("User2 owns", user2Portion, "% of shares");
        console.log("User3 owns", user3Portion, "% of shares");

        // User2 should have largest portion (invested most)
        assertTrue(user2Portion > user1Portion, "User2 should have more than User1");
        assertTrue(user2Portion > user3Portion, "User2 should have more than User3");
        assertTrue(user1Portion > user3Portion, "User1 should have more than User3");
    }

    function test_EdgeCaseScenarios() public {
        console.log("=== TESTING EDGE CASES ===");

        _testStartEpoch();

        _quickInvestment(user1, 1000e6);

        // Test zero profit epoch
        vm.startPrank(owner);
        vm.expectRevert("Net revenue must be positive");
        settlementEngine.recordEpochRevenue(1, 0, 1000, 1000, 100, 100);
        vm.stopPrank();

        // Test processing loss (sold less than purchased)
        vm.startPrank(owner);
        settlementEngine.recordEpochRevenue(
            1,
            50_000, // Still profit overall
            1_200_000, // 1.2 tons purchased
            1_000_000, // Only 1 ton sold (processing loss)
            250,
            300
        );

        uint256 efficiency = settlementEngine.getCopperProcessingEfficiency(1);
        console.log("Processing efficiency with loss:", efficiency);
        assertTrue(efficiency < 10000, "Efficiency should be less than 100%");

        settlementEngine.settleEpochRevenue(1);

        usdcToken.mint(address(owner), 50_000);
        usdcToken.approve(address(settlementEngine), 50_000);
        settlementEngine.distributeRevenueToVault(1);
        vm.stopPrank();

        // Mint enough USDC to Silo to cover the redemption
        usdcToken.mint(zapper.silo(), 1879);

        // User should still profit despite processing loss
        vm.startPrank(user1);
        xcupVault.approve(address(zapper), xcupVault.balanceOf(user1));
        uint256 finalAmount = zapper.redeem(xcupVault.balanceOf(user1));
        assertTrue(finalAmount > 0, "User should still receive something");
        vm.stopPrank();
    }

    // ================================================================
    // COMPLEX MULTI-USER MULTI-EPOCH SCENARIO
    // ================================================================

    function test_ComplexMultiUserMultiEpochScenario() public {
        console.log("=== COMPLEX MULTI-USER MULTI-EPOCH SCENARIO ===");

        // Phase 1: Setup and Initial Investments
        _setupComplexScenario();

        // Phase 2: First Epoch Operations
        _firstEpochOperations();

        // Phase 3: Second Epoch Operations
        _secondEpochOperations();

        console.log("=== COMPLEX SCENARIO COMPLETED ===");
    }

    function _setupComplexScenario() internal {
        console.log("\n--- Phase 1: Setup and Initial Investments ---");

        // Start epoch
        _testStartEpoch();

        // User1: Invest with USDC
        vm.startPrank(user1);
        usdcToken.approve(address(zapper), 2000e6);
        bytes32 depositId1 = zapper.zapAndDeposit(IERC20(address(usdcToken)), 2000e6);
        console.log("User1 invested 2000 USDC, depositId:", uint256(depositId1));
        vm.stopPrank();

        // User2: Invest with ETH
        vm.startPrank(user2);
        vm.deal(user2, 2 ether);
        bytes32 depositId2 = zapper.zapAndDeposit{value: 2 ether}(
            IERC20(0xfFf9976782d46CC05630D1f6eBAb18b2324d6B14),
            2 ether
        );
        console.log("User2 invested 2 ETH, depositId:", uint256(depositId2));
        vm.stopPrank();

        // User3: Invest with USDC
        vm.startPrank(user3);
        usdcToken.approve(address(zapper), 1500e6);
        bytes32 depositId3 = zapper.zapAndDeposit(IERC20(address(usdcToken)), 1500e6);
        console.log("User3 invested 1500 USDC, depositId:", uint256(depositId3));
        vm.stopPrank();

        // Verify total pending amount
        uint256 totalPendingBeforeWithdrawal = zapper.getTotalPendingAmount();
        console.log("Total pending amount before withdrawal:", totalPendingBeforeWithdrawal);
        assertTrue(totalPendingBeforeWithdrawal > 0, "Should have pending deposits");

        // User2 withdraws their deposit
        console.log("\n--- User2 Withdraws Deposit ---");
        vm.startPrank(user2);
        uint256 user2BalanceBefore = usdcToken.balanceOf(user2);
        zapper.withdrawDeposit(depositId2);
        uint256 user2BalanceAfter = usdcToken.balanceOf(user2);
        console.log("User2 withdrew deposit, received:", user2BalanceAfter - user2BalanceBefore, "USDC");
        assertTrue(user2BalanceAfter > user2BalanceBefore, "User2 should receive refund");
        vm.stopPrank();

        // Verify withdrawal removed from pending
        uint256 totalPendingAfterWithdrawal = zapper.getTotalPendingAmount();
        console.log("Total pending amount after withdrawal:", totalPendingAfterWithdrawal);
        assertTrue(totalPendingAfterWithdrawal < totalPendingBeforeWithdrawal, "Pending amount should be reduced");
    }

    function _firstEpochOperations() internal {
        console.log("\n--- Phase 2: First Epoch Operations ---");

        // Admin approves 90% of remaining deposits
        vm.startPrank(curator);
        uint256 totalPending = zapper.getTotalPendingAmount();
        uint256 targetAmount = (totalPending * 90) / 100; // 90% approval
        console.log("Approving 90% of remaining deposits:", targetAmount);
        zapper.approveDepositsProportionally(targetAmount);
        vm.stopPrank();

        // Get remaining deposit IDs (User1 and User3)
        bytes32[] memory pendingIds = zapper.getPendingDepositIds();
        console.log("Remaining deposit IDs after approval:", pendingIds.length);

        // User1 claims their deposit
        vm.startPrank(user1);
        uint256 shares1 = zapper.claimDeposit(pendingIds[0]);
        console.log("User1 received", shares1, "xCUP shares");
        assertTrue(shares1 > 0, "User1 should receive shares");
        vm.stopPrank();

        // User3 claims their deposit
        vm.startPrank(user3);
        uint256 shares3 = zapper.claimDeposit(pendingIds[1]);
        console.log("User3 received", shares3, "xCUP shares");
        assertTrue(shares3 > 0, "User3 should receive shares");
        vm.stopPrank();

        // Verify vault state
        uint256 totalSupply = xcupVault.totalSupply();
        console.log("Total xCUP supply after claims:", totalSupply);
        assertTrue(totalSupply > 0, "Vault should have total supply");

        // Business operations and revenue distribution
        console.log("\n--- First Epoch Revenue Distribution ---");
        vm.startPrank(owner);

        // Record epoch revenue
        settlementEngine.recordEpochRevenue(
            1,
            500_000_000, // $500k profit
            10_000_000, // 10 tons purchased
            9_500_000, // 9.5 tons sold (95% efficiency)
            300, // $0.30 purchase
            600 // $0.60 sale
        );

        // Settle and distribute revenue
        settlementEngine.settleEpochRevenue(1);

        // Mint USDC for revenue distribution
        usdcToken.mint(address(owner), 500_000_000);
        usdcToken.approve(address(settlementEngine), 500_000_000);
        settlementEngine.distributeRevenueToVault(1);

        console.log("First epoch revenue distributed: $500k");
        vm.stopPrank();

        // User1 redeems USDC via zapper
        console.log("\n--- User1 Redeems USDC via Zapper ---");
        vm.startPrank(user1);
        uint256 user1Shares = xcupVault.balanceOf(user1);
        uint256 user1USDCBefore = usdcToken.balanceOf(user1);

        xcupVault.approve(address(zapper), user1Shares);
        uint256 usdcReceived1 = zapper.redeem(user1Shares);
        uint256 user1USDCAfter = usdcToken.balanceOf(user1);

        console.log("User1 redeemed", user1Shares, "shares for USDC", usdcReceived1);
        console.log("User1 USDC balance change:", user1USDCAfter - user1USDCBefore);
        assertTrue(usdcReceived1 > 0, "User1 should receive USDC");
        assertEq(xcupVault.balanceOf(user1), 0, "User1 should have no shares left");
        vm.stopPrank();

        // User2 doesn't do anything (already withdrew)
        console.log("User2 already withdrew, no action needed");

        console.log("Vault total supply after first epoch:", xcupVault.totalSupply());
    }

    function _secondEpochOperations() internal {
        console.log("\n--- Phase 3: Second Epoch Operations ---");

        // Advance to next epoch
        vm.startPrank(owner);
        vm.warp(block.timestamp + EPOCH_DURATION + 1);
        epochManager.nextEpoch();
        console.log("Advanced to epoch:", epochManager.currentEpochId());
        vm.stopPrank();

        // User1 invests again (fresh investment)
        console.log("\n--- User1 Makes Fresh Investment ---");
        vm.startPrank(user1);
        usdcToken.approve(address(zapper), 3000e6);
        bytes32 newDepositId1 = zapper.zapAndDeposit(IERC20(address(usdcToken)), 3000e6);
        console.log("User1 invested 3000 USDC in new epoch, depositId:", uint256(newDepositId1));
        vm.stopPrank();

        // User2 invests again (after previous withdrawal)
        console.log("\n--- User2 Makes New Investment ---");
        vm.startPrank(user2);
        usdcToken.approve(address(zapper), 2500e6);
        bytes32 newDepositId2 = zapper.zapAndDeposit(IERC20(address(usdcToken)), 2500e6);
        console.log("User2 invested 2500 USDC in new epoch, depositId:", uint256(newDepositId2));
        vm.stopPrank();

        // User3 invests again (after previous redemption)
        console.log("\n--- User3 Makes New Investment ---");
        vm.startPrank(user3);
        usdcToken.approve(address(zapper), 1800e6);
        bytes32 newDepositId3 = zapper.zapAndDeposit(IERC20(address(usdcToken)), 1800e6);
        console.log("User3 invested 1800 USDC in new epoch, depositId:", uint256(newDepositId3));
        vm.stopPrank();

        // Admin approves all deposits
        vm.startPrank(curator);
        uint256 totalPending = zapper.getTotalPendingAmount();
        console.log("Approving all deposits:", totalPending);
        zapper.approveDepositsProportionally(totalPending);
        vm.stopPrank();

        // All users claim their deposits
        bytes32[] memory pendingIds = zapper.getPendingDepositIds();
        console.log("Pending IDs in second epoch:", pendingIds.length);

        vm.startPrank(user1);
        uint256 shares1 = zapper.claimDeposit(pendingIds[0]);
        console.log("User1 received", shares1, "xCUP shares in second epoch");
        vm.stopPrank();

        vm.startPrank(user2);
        uint256 shares2 = zapper.claimDeposit(pendingIds[3]);
        console.log("User2 received", shares2, "xCUP shares in second epoch");
        vm.stopPrank();

        vm.startPrank(user3);
        uint256 shares3 = zapper.claimDeposit(pendingIds[4]);
        console.log("User3 received", shares3, "xCUP shares in second epoch");
        vm.stopPrank();

        // Second epoch revenue distribution
        console.log("\n--- Second Epoch Revenue Distribution ---");
        vm.startPrank(owner);

        // Record higher revenue for second epoch
        settlementEngine.recordEpochRevenue(
            2,
            800_000_000, // $800k profit (higher than first epoch)
            15_000_000, // 15 tons purchased
            14_250_000, // 14.25 tons sold (95% efficiency)
            350, // $0.35 purchase
            700 // $0.70 sale
        );

        // Settle and distribute revenue
        settlementEngine.settleEpochRevenue(2);

        // Mint USDC for revenue distribution
        usdcToken.mint(address(owner), 800_000_000);
        usdcToken.approve(address(settlementEngine), 800_000_000);
        settlementEngine.distributeRevenueToVault(2);

        console.log("Second epoch revenue distributed: $800k");
        vm.stopPrank();

        // Both users redeem via zapper
        console.log("\n--- Both Users Redeem via Zapper ---");

        // User1 redeems via zapper
        vm.startPrank(user1);
        uint256 user1Shares = xcupVault.balanceOf(user1);
        uint256 user1USDCBefore = usdcToken.balanceOf(user1);

        xcupVault.approve(address(zapper), user1Shares);
        uint256 usdcReceived1 = zapper.redeem(user1Shares);
        uint256 user1USDCAfter = usdcToken.balanceOf(user1);

        console.log("User1 redeemed", user1Shares, "shares for USDC", usdcReceived1);
        console.log("User1 total USDC received:", user1USDCAfter - user1USDCBefore);
        assertTrue(usdcReceived1 > 0, "User1 should receive USDC");
        vm.stopPrank();

        // User2 redeems via zapper
        vm.startPrank(user2);
        uint256 user2Shares = xcupVault.balanceOf(user2);
        uint256 user2USDCBefore = usdcToken.balanceOf(user2);

        xcupVault.approve(address(zapper), user2Shares);
        uint256 usdcReceived2 = zapper.redeem(user2Shares);
        uint256 user2USDCAfter = usdcToken.balanceOf(user2);

        console.log("User2 redeemed", user2Shares, "shares for USDC", usdcReceived2);
        console.log("User2 total USDC received:", user2USDCAfter - user2USDCBefore);
        assertTrue(usdcReceived2 > 0, "User2 should receive USDC");
        vm.stopPrank();

        // User3 keeps shares for next epoch
        uint256 user3Shares = xcupVault.balanceOf(user3);
        console.log("User3 keeps", user3Shares, "shares for next epoch");

        // Verify final state
        uint256 finalTotalSupply = xcupVault.totalSupply();
        console.log("Final vault total supply:", finalTotalSupply);
        assertEq(finalTotalSupply, user3Shares, "Only User3 should have shares");

        // Calculate and verify profits
        uint256 user1TotalInvestment = 2000e6 + 3000e6; // First + second epoch
        uint256 user2TotalInvestment = 2500e6; // Only second epoch (withdrew first)
        uint256 user3TotalInvestment = 1500e6 + 1800e6; // First + second epoch

        console.log("\n--- Investment Summary ---");
        console.log("User1 total investment:", user1TotalInvestment);
        console.log("User1 total redemption:", user1USDCAfter);
        console.log("User1 profit:", user1USDCAfter - user1TotalInvestment);

        console.log("User2 total investment:", user2TotalInvestment);
        console.log("User2 total redemption:", user2USDCAfter);
        console.log("User2 profit:", user2USDCAfter - user2TotalInvestment);

        console.log("User3 total investment:", user3TotalInvestment);
        console.log("User3 current shares value:", user3Shares);

        // Verify all users made profit or have valuable shares
        assertTrue(user1USDCAfter > user1TotalInvestment, "User1 should have profit");
        assertTrue(user2USDCAfter > user2TotalInvestment, "User2 should have profit");
        assertTrue(user3Shares > 0, "User3 should have valuable shares");
    }

    // ================================================================
    // HELPER FUNCTIONS
    // ================================================================

    function _quickInvestment(address user, uint256 amount) internal {
        vm.startPrank(user);
        usdcToken.approve(address(zapper), amount);
        bytes32 depositId = zapper.zapAndDeposit(IERC20(address(usdcToken)), amount);
        vm.stopPrank();

        vm.prank(curator);
        zapper.approveDeposit(depositId, amount);

        vm.prank(user);
        zapper.claimDeposit(depositId);

        console.log("Quick investment:", amount, "USDC for", vm.toString(user));
    }

    function _runEpochCycle(uint256 epochId, uint256 netRevenue, uint256 cupPurchased, uint256 cupSold) internal {
        vm.startPrank(owner);

        settlementEngine.recordEpochRevenue(
            epochId,
            netRevenue,
            cupPurchased,
            cupSold,
            250, // Purchase price
            500 // Sale price
        );

        settlementEngine.settleEpochRevenue(epochId);

        // Approve USDC to be burned to mint CUP tokens
        usdcToken.mint(address(owner), netRevenue);
        usdcToken.approve(address(settlementEngine), netRevenue);

        settlementEngine.distributeRevenueToVault(epochId);

        console.log("Completed epoch", epochId);
        console.log("Net revenue:", netRevenue);

        vm.stopPrank();
    }

    // ================================================================
    // INTEGRATION VERIFICATION TESTS
    // ================================================================

    function test_ContractIntegration() public view {
        // Verify all contracts are properly connected
        assertEq(address(xcupVault.asset()), address(cupToken), "xCUP should use CUP as asset");

        assertTrue(
            cupToken.hasRole(cupToken.MINTER_ROLE(), address(settlementEngine)),
            "Settlement engine should have minter role"
        );

        assertTrue(zapper.hasRole(zapper.VAULT_CURATOR_ROLE(), curator), "Curator should have curator role");

        console.log("All contract integrations verified");
    }

    function test_EventEmissions() public {
        // Start epoch
        _testStartEpoch();

        _quickInvestment(user1, 1000e6);

        vm.startPrank(owner);

        // Test NAV update events
        vm.expectEmit(address(settlementEngine));
        emit SettlementEngine.NAVUpdated(500000, 100000000000000); // Will be calculated values

        settlementEngine.updateNAV(
            SettlementEngine.NAVComponents({
                cupInWarehouse: 1000,
                copperSpotPrice: 500,
                cupInTransit: 0,
                retainedEarnings: 0,
                stablecoinBalance: 0,
                liabilities: 0
            })
        );

        // Test revenue recording events
        vm.expectEmit(address(settlementEngine));
        emit SettlementEngine.EpochRevenueRecorded(1, 100_000, 1000);

        vm.expectEmit(address(settlementEngine));
        emit SettlementEngine.CopperOperationCompleted(1, 1000, 1000, 100_000);

        settlementEngine.recordEpochRevenue(1, 100_000, 1000, 1000, 100, 200);

        vm.stopPrank();

        console.log("All events properly emitted");
    }
}
