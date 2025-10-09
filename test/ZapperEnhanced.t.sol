// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

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

// Mock Uniswap Router for comprehensive testing
contract MockUniswapRouterEnhanced {
    mapping(address => mapping(address => uint256)) public rates;
    bool public shouldRevert;
    uint256 public slippageSimulation;

    function setRate(address tokenA, address tokenB, uint256 rate) external {
        rates[tokenA][tokenB] = rate;
    }

    function setShouldRevert(bool _shouldRevert) external {
        shouldRevert = _shouldRevert;
    }

    function setSlippageSimulation(uint256 _slippage) external {
        slippageSimulation = _slippage;
    }

    function getAmountsOut(uint256 amountIn, address[] memory path) external view returns (uint256[] memory amounts) {
        if (shouldRevert) revert("Router: INSUFFICIENT_LIQUIDITY");

        amounts = new uint256[](path.length);
        amounts[0] = amountIn;

        for (uint256 i = 1; i < path.length; i++) {
            uint256 rate = rates[path[i - 1]][path[i]];
            if (rate == 0) rate = 1e18; // Default 1:1 rate
            amounts[i] = (amounts[i - 1] * rate) / 1e18;

            // Apply slippage simulation
            if (slippageSimulation > 0) {
                amounts[i] = (amounts[i] * (10000 - slippageSimulation)) / 10000;
            }
        }
    }

    function swapExactTokensForTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] memory path,
        address to,
        uint256 deadline
    ) external returns (uint256[] memory amounts) {
        if (shouldRevert) revert("Router: INSUFFICIENT_OUTPUT_AMOUNT");

        amounts = this.getAmountsOut(amountIn, path);
        require(amounts[amounts.length - 1] >= amountOutMin, "Router: INSUFFICIENT_OUTPUT_AMOUNT");

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
        if (shouldRevert) revert("Router: INSUFFICIENT_OUTPUT_AMOUNT");

        amounts = this.getAmountsOut(msg.value, path);
        require(amounts[amounts.length - 1] >= amountOutMin, "Router: INSUFFICIENT_OUTPUT_AMOUNT");

        IERC20(path[1]).transfer(to, amounts[1]);
    }

    function WETH() public pure returns (address) {
        return 0xfFf9976782d46CC05630D1f6eBAb18b2324d6B14;
    }
}

contract ZapperEnhancedTest is Test {
    Zapper public zapper;
    CUPToken public cupToken;
    xCUP public vault;
    IEpochManager public epochManager;
    CopperPriceConsumerMock public priceConsumer;
    MockUniswapRouterEnhanced public router;
    ERC20Mock public usdcToken;
    ERC20Mock public wethToken;
    ERC20Mock public daiToken;

    address public owner;
    address public curator;
    address public user1;
    address public user2;
    address public user3;
    address public unauthorized;

    uint256 constant EPOCH_DURATION = 30 days;
    uint256 constant INITIAL_COPPER_PRICE = 450000000; // $4.50 with 8 decimals
    uint256 constant INITIAL_SUPPLY = 1000000e6;

    event ZapAndDeposit(address indexed router, address indexed tokenIn, uint256 amount);
    event DepositApproved(bytes32 depositId, uint256 approvedAmount);
    event DepositDeclined(bytes32 depositId, address user, uint256 refundAmount);
    event DepositClaimed(bytes32 depositId, address user, uint256 shares);
    event DepositWithdrawn(bytes32 depositId, address user, uint256 amount);
    event ProportionalApproval(uint256 totalApproved, uint256 totalDeposited, uint256 proportion);
    event Withdraw(address indexed user, uint256 amount);

    function setUp() public {
        owner = address(this);
        curator = makeAddr("curator");
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

        // Deploy enhanced router
        router = new MockUniswapRouterEnhanced();

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
                    address(router),
                    address(priceConsumer),
                    address(epochManager)
                )
            )
        );
        zapper = Zapper(zapperProxy);

        // Setup roles
        zapper.grantRole(zapper.VAULT_CURATOR_ROLE(), curator);
        vault.grantRole(vault.REDEEMER_ROLE(), address(zapper));

        // Setup tokens and balances
        cupToken.grantRole(cupToken.MINTER_ROLE(), owner);
        cupToken.mint(address(zapper), INITIAL_SUPPLY);

        // Setup router rates
        router.setRate(address(daiToken), address(usdcToken), 1e18); // 1 DAI = 1 USDC
        router.setRate(address(wethToken), address(usdcToken), 2000e18); // 1 WETH = 2000 USDC
        router.setRate(address(usdcToken), address(wethToken), 5e14); // 1 USDC = 0.0005 WETH

        // Mint tokens to users
        usdcToken.mint(user1, INITIAL_SUPPLY);
        usdcToken.mint(user2, INITIAL_SUPPLY);
        usdcToken.mint(user3, INITIAL_SUPPLY);
        usdcToken.mint(address(zapper.silo()), INITIAL_SUPPLY);

        daiToken.mint(user1, INITIAL_SUPPLY * 1e12); // DAI has 18 decimals
        wethToken.mint(user1, 100e18); // 100 WETH

        // Give users ETH
        vm.deal(user1, 100 ether);
        vm.deal(user2, 100 ether);
        vm.deal(user3, 100 ether);
    }

    function testWithdrawAllDepositsMultipleUsers() public {
        // Create deposits from multiple users
        uint256 amount1 = 1000e6;
        uint256 amount2 = 2000e6;
        uint256 amount3 = 3000e6;

        // User1 creates multiple deposits
        vm.startPrank(user1);
        usdcToken.approve(address(zapper), amount1 * 3);
        zapper.zapAndDeposit(usdcToken, amount1, keccak256("deposit1"), 100);
        zapper.zapAndDeposit(usdcToken, amount1, keccak256("deposit2"), 100);
        zapper.zapAndDeposit(usdcToken, amount1, keccak256("deposit3"), 100);
        vm.stopPrank();

        // User2 creates deposits
        vm.startPrank(user2);
        usdcToken.approve(address(zapper), amount2);
        zapper.zapAndDeposit(usdcToken, amount2, keccak256("deposit4"), 100);
        vm.stopPrank();

        uint256 user1InitialBalance = usdcToken.balanceOf(user1);
        uint256 user2InitialBalance = usdcToken.balanceOf(user2);

        // User1 withdraws all deposits
        vm.prank(user1);
        uint256 totalRefunded1 = zapper.withdrawAllDeposits();

        // User2 withdraws all deposits
        vm.prank(user2);
        uint256 totalRefunded2 = zapper.withdrawAllDeposits();

        assertEq(totalRefunded1, amount1 * 3);
        assertEq(totalRefunded2, amount2);
        assertEq(usdcToken.balanceOf(user1), user1InitialBalance + totalRefunded1);
        assertEq(usdcToken.balanceOf(user2), user2InitialBalance + totalRefunded2);
    }

    function testWithdrawAllDepositsRevertNoDeposits() public {
        vm.prank(user1);
        vm.expectRevert("No deposits found");
        zapper.withdrawAllDeposits();
    }

    function testWithdrawAllDepositsRevertNoPendingDeposits() public {
        // Create and approve a deposit
        vm.startPrank(user1);
        usdcToken.approve(address(zapper), 1000e6);
        zapper.zapAndDeposit(usdcToken, 1000e6, keccak256("deposit1"), 100);
        vm.stopPrank();

        // Advance epoch and approve
        vm.warp(block.timestamp + EPOCH_DURATION);
        epochManager.nextEpoch();

        bytes32[] memory pendingIds = zapper.getPendingDepositIds();
        vm.prank(curator);
        zapper.approveDeposit(pendingIds[0], 1000e6);

        // Try to withdraw - should fail as deposit is approved
        vm.prank(user1);
        vm.expectRevert("No pending deposits to withdraw");
        zapper.withdrawAllDeposits();
    }

    function testApproveAllDeposits() public {
        // Create multiple deposits
        uint256[] memory amounts = new uint256[](3);
        amounts[0] = 1000e6;
        amounts[1] = 2000e6;
        amounts[2] = 3000e6;

        vm.startPrank(user1);
        usdcToken.approve(address(zapper), amounts[0] + amounts[1] + amounts[2]);
        zapper.zapAndDeposit(usdcToken, amounts[0], keccak256("deposit1"), 100);
        zapper.zapAndDeposit(usdcToken, amounts[1], keccak256("deposit2"), 100);
        zapper.zapAndDeposit(usdcToken, amounts[2], keccak256("deposit3"), 100);
        vm.stopPrank();

        // Advance epoch
        vm.warp(block.timestamp + EPOCH_DURATION);
        epochManager.nextEpoch();

        uint256 totalExpected = amounts[0] + amounts[1] + amounts[2];

        vm.expectEmit(false, false, false, true);
        emit ProportionalApproval(totalExpected, totalExpected, 1e18);

        vm.prank(curator);
        (uint256 totalApproved, uint256 depositsApproved) = zapper.approveAllDeposits();

        assertEq(totalApproved, totalExpected);
        assertEq(depositsApproved, 3);
    }

    function testApproveAllDepositsRevertNoDeposits() public {
        vm.warp(block.timestamp + EPOCH_DURATION);
        epochManager.nextEpoch();

        vm.prank(curator);
        vm.expectRevert("No pending deposits");
        zapper.approveAllDeposits();
    }

    function testClaimAllDeposits() public {
        // Create and approve multiple deposits
        uint256[] memory amounts = new uint256[](3);
        amounts[0] = 1000e6;
        amounts[1] = 2000e6;
        amounts[2] = 3000e6;

        vm.startPrank(user1);
        usdcToken.approve(address(zapper), amounts[0] + amounts[1] + amounts[2]);
        zapper.zapAndDeposit(usdcToken, amounts[0], keccak256("deposit1"), 100);
        zapper.zapAndDeposit(usdcToken, amounts[1], keccak256("deposit2"), 100);
        zapper.zapAndDeposit(usdcToken, amounts[2], keccak256("deposit3"), 100);
        vm.stopPrank();

        // Advance epoch and approve all
        vm.warp(block.timestamp + EPOCH_DURATION);
        epochManager.nextEpoch();

        vm.prank(curator);
        zapper.approveAllDeposits();

        // Claim all deposits
        vm.prank(user1);
        uint256 totalShares = zapper.claimAllDeposits();

        assertGt(totalShares, 0);
        assertEq(vault.balanceOf(user1), totalShares);
    }

    function testRedeemFunctionality() public {
        // Setup: create, approve, and claim deposit
        uint256 depositAmount = 10000e6;

        vm.startPrank(user1);
        usdcToken.approve(address(zapper), depositAmount);
        zapper.zapAndDeposit(usdcToken, depositAmount, keccak256("deposit1"), 100);
        vm.stopPrank();

        vm.warp(block.timestamp + EPOCH_DURATION);
        epochManager.nextEpoch();

        bytes32[] memory pendingIds = zapper.getPendingDepositIds();
        vm.prank(curator);
        zapper.approveDeposit(pendingIds[0], depositAmount);

        vm.prank(user1);
        uint256 shares = zapper.claimDeposit(pendingIds[0]);

        // Now test redemption
        uint256 initialUsdcBalance = usdcToken.balanceOf(user1);

        vm.startPrank(user1);
        vault.approve(address(zapper), shares);
        uint256 usdcReceived = zapper.redeem(shares);
        vm.stopPrank();

        assertGt(usdcReceived, 0);
        assertEq(usdcToken.balanceOf(user1), initialUsdcBalance + usdcReceived);
        assertEq(vault.balanceOf(user1), 0);
    }

    function testRedeemRevertInsufficientShares() public {
        vm.prank(user1);
        vm.expectRevert("Insufficient shares to redeem");
        zapper.redeem(1000e6);
    }

    function testRedeemRevertZeroShares() public {
        vm.prank(user1);
        vm.expectRevert("Shares to redeem must be greater than 0");
        zapper.redeem(0);
    }

    function testZapWithSlippageProtection() public {
        // Set high slippage on router
        router.setSlippageSimulation(500); // 5% slippage

        uint256 daiAmount = 1000e18; // 1000 DAI
        uint256 highSlippage = 100; // 1% max slippage - should fail

        vm.startPrank(user1);
        daiToken.approve(address(zapper), daiAmount);

        // This should revert due to slippage protection
        vm.expectRevert();
        zapper.zapAndDeposit(daiToken, daiAmount, keccak256("deposit1"), highSlippage);
        vm.stopPrank();

        // Reset slippage and try with higher tolerance
        router.setSlippageSimulation(0);

        vm.startPrank(user1);
        zapper.zapAndDeposit(daiToken, daiAmount, keccak256("deposit2"), 1000); // 10% tolerance
        vm.stopPrank();

        bytes32[] memory pendingIds = zapper.getPendingDepositIds();
        assertEq(pendingIds.length, 1);
    }

    function testZapWithRouterFailure() public {
        router.setShouldRevert(true);

        uint256 daiAmount = 1000e18;

        vm.startPrank(user1);
        daiToken.approve(address(zapper), daiAmount);

        vm.expectRevert();
        zapper.zapAndDeposit(daiToken, daiAmount, keccak256("deposit1"), 100);
        vm.stopPrank();

        // Reset router and verify it works
        router.setShouldRevert(false);

        vm.startPrank(user1);
        zapper.zapAndDeposit(daiToken, daiAmount, keccak256("deposit2"), 100);
        vm.stopPrank();

        bytes32[] memory pendingIds = zapper.getPendingDepositIds();
        assertEq(pendingIds.length, 1);
    }

    function testGetPendingDepositsDetailed() public {
        // Create deposits from different users
        vm.startPrank(user1);
        usdcToken.approve(address(zapper), 3000e6);
        zapper.zapAndDeposit(usdcToken, 1000e6, keccak256("user1_deposit1"), 100);
        zapper.zapAndDeposit(usdcToken, 2000e6, keccak256("user1_deposit2"), 100);
        vm.stopPrank();

        vm.startPrank(user2);
        usdcToken.approve(address(zapper), 1500e6);
        zapper.zapAndDeposit(usdcToken, 1500e6, keccak256("user2_deposit1"), 100);
        vm.stopPrank();

        Zapper.Deposit[] memory pendingDeposits = zapper.getPendingDeposits();
        assertEq(pendingDeposits.length, 3);

        uint256 totalPending = zapper.getTotalPendingAmount();
        assertEq(totalPending, 4500e6);

        // Verify user-specific deposits
        bytes32[] memory user1Ids = zapper.getUserDepositIds(user1);
        assertEq(user1Ids.length, 2);

        Zapper.Deposit[] memory user1Deposits = zapper.getUserDeposits(user1);
        assertEq(user1Deposits.length, 2);
        assertEq(user1Deposits[0].amount + user1Deposits[1].amount, 3000e6);
    }

    function testPartialApprovalAndClaim() public {
        uint256 depositAmount = 10000e6;
        uint256 approvedAmount = 6000e6; // Partial approval

        vm.startPrank(user1);
        usdcToken.approve(address(zapper), depositAmount);
        zapper.zapAndDeposit(usdcToken, depositAmount, keccak256("deposit1"), 100);
        vm.stopPrank();

        vm.warp(block.timestamp + EPOCH_DURATION);
        epochManager.nextEpoch();

        bytes32[] memory pendingIds = zapper.getPendingDepositIds();

        // Partially approve
        vm.prank(curator);
        zapper.approveDeposit(pendingIds[0], approvedAmount);

        // Claim the approved portion
        vm.prank(user1);
        uint256 shares = zapper.claimDeposit(pendingIds[0]);

        assertGt(shares, 0);

        // Verify remaining deposit
        Zapper.Deposit memory remainingDeposit = zapper.getDeposit(pendingIds[0]);
        assertEq(remainingDeposit.amount, depositAmount - approvedAmount);
        assertFalse(remainingDeposit.approved);
        assertEq(remainingDeposit.approvedAmount, 0);
    }

    function testReceiveFunctionETHDeposit() public {
        uint256 ethAmount = 1 ether;
        uint256 initialSiloBalance = usdcToken.balanceOf(zapper.silo());

        // Send ETH directly to contract
        vm.prank(user1);
        (bool success, ) = address(zapper).call{value: ethAmount}("");
        assertTrue(success);

        // Verify deposit was created
        bytes32[] memory pendingIds = zapper.getPendingDepositIds();
        assertEq(pendingIds.length, 1);

        // Verify USDC was received in silo
        assertGt(usdcToken.balanceOf(zapper.silo()), initialSiloBalance);
    }

    function testFallbackFunctionETHDeposit() public {
        uint256 ethAmount = 0.5 ether;
        uint256 initialSiloBalance = usdcToken.balanceOf(zapper.silo());

        // Send ETH with data to trigger fallback
        vm.prank(user1);
        (bool success, ) = address(zapper).call{value: ethAmount}("0x1234");
        assertTrue(success);

        // Verify deposit was created
        bytes32[] memory pendingIds = zapper.getPendingDepositIds();
        assertEq(pendingIds.length, 1);

        // Verify USDC was received in silo
        assertGt(usdcToken.balanceOf(zapper.silo()), initialSiloBalance);
    }

    function testReceiveFunctionRevertWhenPaused() public {
        zapper.pause();

        vm.prank(user1);
        vm.expectRevert();
        (bool success, ) = address(zapper).call{value: 1 ether}("");
    }

    function testReceiveFunctionRevertZeroETH() public {
        vm.prank(user1);
        vm.expectRevert("No ETH sent");
        (bool success, ) = address(zapper).call{value: 0}("");
    }

    function testOwnerWithdrawFromSilo() public {
        // Add some USDC to silo first
        uint256 withdrawAmount = 50000e6;

        vm.startPrank(user1);
        usdcToken.approve(address(zapper), 100000e6);
        zapper.zapAndDeposit(usdcToken, 100000e6, keccak256("deposit1"), 100);
        vm.stopPrank();

        uint256 ownerInitialBalance = usdcToken.balanceOf(owner);
        uint256 siloInitialBalance = usdcToken.balanceOf(zapper.silo());

        vm.expectEmit(true, false, false, true);
        emit Withdraw(owner, withdrawAmount);

        zapper.withdraw(withdrawAmount);

        assertEq(usdcToken.balanceOf(owner), ownerInitialBalance + withdrawAmount);
        assertEq(usdcToken.balanceOf(zapper.silo()), siloInitialBalance - withdrawAmount);
    }

    function testOwnerWithdrawRevertInsufficientBalance() public {
        uint256 withdrawAmount = 1000000e6; // More than available

        vm.expectRevert("Insufficient USDC balance");
        zapper.withdraw(withdrawAmount);
    }

    function testOwnerWithdrawRevertNotOwner() public {
        vm.prank(unauthorized);
        vm.expectRevert();
        zapper.withdraw(1000e6);
    }

    function testProportionalApprovalPrecision() public {
        // Test with amounts that might cause precision issues
        uint256[] memory amounts = new uint256[](3);
        amounts[0] = 1e6; // 1 USDC
        amounts[1] = 3e6; // 3 USDC
        amounts[2] = 7e6; // 7 USDC
        // Total: 11 USDC

        vm.startPrank(user1);
        usdcToken.approve(address(zapper), 11e6);
        zapper.zapAndDeposit(usdcToken, amounts[0], keccak256("deposit1"), 100);
        zapper.zapAndDeposit(usdcToken, amounts[1], keccak256("deposit2"), 100);
        zapper.zapAndDeposit(usdcToken, amounts[2], keccak256("deposit3"), 100);
        vm.stopPrank();

        vm.warp(block.timestamp + EPOCH_DURATION);
        epochManager.nextEpoch();

        uint256 targetAmount = 5e6; // Approve 5 USDC out of 11

        vm.prank(curator);
        zapper.approveDepositsProportionally(targetAmount);

        // Verify proportional distribution
        bytes32[] memory pendingIds = zapper.getPendingDepositIds();
        uint256 totalApproved = 0;

        for (uint256 i = 0; i < pendingIds.length; i++) {
            Zapper.Deposit memory deposit = zapper.getDeposit(pendingIds[i]);
            if (deposit.approved) {
                totalApproved += deposit.approvedAmount;
            }
        }

        // Should be close to target amount (allowing for rounding)
        assertApproxEqAbs(totalApproved, targetAmount, 3); // Allow 3 wei difference
    }

    function testEpochActiveModifier() public {
        // Test functions that require active epoch
        bytes32 depositId = keccak256("test_deposit");

        // These should work when epoch is active (initially)
        vm.warp(block.timestamp + EPOCH_DURATION);
        epochManager.nextEpoch();

        // These should fail when epoch is not active
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

        vm.prank(curator);
        vm.expectRevert("Epoch not active");
        zapper.approveAllDeposits();

        vm.prank(user1);
        vm.expectRevert("Epoch not active");
        zapper.claimDeposit(depositId);

        vm.prank(user1);
        vm.expectRevert("Epoch not active");
        zapper.claimAllDeposits();
    }

    function testComplexScenarioMultipleTokensAndUsers() public {
        // Complex scenario with multiple tokens and users

        // User1: USDC deposit
        vm.startPrank(user1);
        usdcToken.approve(address(zapper), 5000e6);
        zapper.zapAndDeposit(usdcToken, 5000e6, keccak256("user1_usdc"), 100);
        vm.stopPrank();

        // User2: DAI deposit
        vm.startPrank(user2);
        daiToken.approve(address(zapper), 3000e18);
        zapper.zapAndDeposit(daiToken, 3000e18, keccak256("user2_dai"), 100);
        vm.stopPrank();

        // User3: ETH deposit
        vm.prank(user3);
        zapper.zapAndDeposit{value: 2 ether}(IERC20(router.WETH()), 2 ether, keccak256("user3_eth"), 100);

        // Advance epoch
        vm.warp(block.timestamp + EPOCH_DURATION);
        epochManager.nextEpoch();

        // Approve 50% of all deposits
        uint256 totalPending = zapper.getTotalPendingAmount();
        vm.prank(curator);
        zapper.approveDepositsProportionally(totalPending / 2);

        // All users claim their approved deposits
        vm.prank(user1);
        uint256 shares1 = zapper.claimAllDeposits();

        vm.prank(user2);
        uint256 shares2 = zapper.claimAllDeposits();

        vm.prank(user3);
        uint256 shares3 = zapper.claimAllDeposits();

        // Verify all users received shares
        assertGt(shares1, 0);
        assertGt(shares2, 0);
        assertGt(shares3, 0);

        assertEq(vault.balanceOf(user1), shares1);
        assertEq(vault.balanceOf(user2), shares2);
        assertEq(vault.balanceOf(user3), shares3);

        // Users withdraw remaining deposits
        vm.prank(user1);
        zapper.withdrawAllDeposits();

        vm.prank(user2);
        zapper.withdrawAllDeposits();

        vm.prank(user3);
        zapper.withdrawAllDeposits();

        // Verify no pending deposits remain
        assertEq(zapper.getPendingDepositIds().length, 0);
    }
}
