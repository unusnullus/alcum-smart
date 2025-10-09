// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";

import {Upgrades} from "openzeppelin-foundry-upgrades/Upgrades.sol";

import {xCUP} from "../contracts/xCUP.sol";
import {CUPToken} from "../contracts/CUPToken.sol";
import {CopperPriceConsumerMock} from "../contracts/mock/CopperPriceConsumerMock.sol";
import {ERC20Mock} from "../contracts/mock/ERC20Mock.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

// Mock Uniswap Router for testing
contract MockUniswapRouter {
    mapping(address => mapping(address => uint256)) internal rates;

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
}

contract xCUPTest is Test {
    xCUP public xcup;
    CUPToken public cupToken;
    CopperPriceConsumerMock public priceConsumer;
    MockUniswapRouter public router;
    ERC20Mock public usdcToken;
    ERC20Mock public wethToken;

    address internal owner;
    address internal redeemer;
    address public user1;
    address public user2;
    address public unauthorized;

    uint256 constant INITIAL_COPPER_PRICE = 450000000; // $4.50 with 8 decimals
    uint256 constant INITIAL_CUP_SUPPLY = 1000000e6; // 1M CUP tokens

    event Deposit(address indexed sender, address indexed owner, uint256 assets, uint256 shares);
    event Withdraw(
        address indexed sender,
        address indexed receiver,
        address indexed owner,
        uint256 assets,
        uint256 shares
    );
    event CopperPriceConsumerUpdated(address indexed previous, address indexed current);
    event UniswapRouterUpdated(address indexed previous, address indexed current);
    event UsdcTokenUpdated(address indexed previous, address indexed current);
    event WethTokenUpdated(address indexed previous, address indexed current);

    function setUp() public {
        owner = address(this);
        redeemer = makeAddr("redeemer");
        user1 = makeAddr("user1");
        user2 = makeAddr("user2");
        unauthorized = makeAddr("unauthorized");

        // Deploy CUP token using upgradeable pattern
        address cupTokenProxy = Upgrades.deployTransparentProxy(
            "CUPToken.sol:CUPToken",
            owner,
            abi.encodeCall(CUPToken.initialize, ())
        );
        cupToken = CUPToken(cupTokenProxy);

        // Deploy mock tokens
        usdcToken = new ERC20Mock("USDC", "USDC", 6);
        wethToken = new ERC20Mock("WETH", "WETH", 18);

        // Deploy mock price consumer
        priceConsumer = new CopperPriceConsumerMock();
        priceConsumer.setPrice(INITIAL_COPPER_PRICE);

        // Deploy mock router
        router = new MockUniswapRouter();

        // Deploy xCUP using upgradeable pattern
        address xcupProxy = Upgrades.deployTransparentProxy(
            "xCUP.sol:xCUP",
            owner,
            abi.encodeCall(xCUP.initialize, (IERC20(address(cupToken)), "xCUP Vault", "xCUP"))
        );
        xcup = xCUP(xcupProxy);

        // Setup roles
        xcup.grantRole(xcup.REDEEMER_ROLE(), redeemer);

        // Mint CUP tokens
        cupToken.grantRole(cupToken.MINTER_ROLE(), owner);
        cupToken.mint(user1, INITIAL_CUP_SUPPLY);
        cupToken.mint(user2, INITIAL_CUP_SUPPLY);
        cupToken.mint(address(this), INITIAL_CUP_SUPPLY);

        // Setup router rates (1 USDC = 1 USDC, 1 ETH = 2000 USDC)
        router.setRate(address(usdcToken), address(usdcToken), 1e18);
        router.setRate(address(wethToken), address(usdcToken), 2000e18);
        router.setRate(address(usdcToken), address(wethToken), 5e14); // 1/2000
    }

    function testInitialState() public {
        assertEq(xcup.name(), "xCUP Vault");
        assertEq(xcup.symbol(), "xCUP");
        assertEq(xcup.decimals(), 6);
        assertEq(xcup.asset(), address(cupToken));
        assertEq(xcup.totalSupply(), 0);
        assertEq(xcup.totalAssets(), 0);
        assertEq(xcup.owner(), owner);
        assertFalse(xcup.paused());
        assertFalse(xcup.v2Initialized());
    }

    function testInitializeV2() public {
        vm.expectEmit(true, true, true, true);
        emit xCUP.V2Initialized(
            address(priceConsumer),
            address(router),
            address(usdcToken),
            address(wethToken),
            block.timestamp
        );

        xcup.initializeV2(address(priceConsumer), address(router), address(usdcToken), address(wethToken));

        assertTrue(xcup.v2Initialized());
        assertEq(address(xcup.copperPriceConsumer()), address(priceConsumer));
        assertEq(address(xcup.uniswapRouter()), address(router));
        assertEq(address(xcup.usdcToken()), address(usdcToken));
        assertEq(xcup.wethToken(), address(wethToken));
    }

    function testInitializeV2RevertAlreadyInitialized() public {
        xcup.initializeV2(address(priceConsumer), address(router), address(usdcToken), address(wethToken));

        vm.expectRevert("V2 already initialized");
        xcup.initializeV2(address(priceConsumer), address(router), address(usdcToken), address(wethToken));
    }

    function testInitializeV2RevertInvalidAddresses() public {
        vm.expectRevert("Invalid copper price consumer");
        xcup.initializeV2(address(0), address(router), address(usdcToken), address(wethToken));

        vm.expectRevert("Invalid Uniswap router");
        xcup.initializeV2(address(priceConsumer), address(0), address(usdcToken), address(wethToken));

        vm.expectRevert("Invalid USDC token");
        xcup.initializeV2(address(priceConsumer), address(router), address(0), address(wethToken));

        vm.expectRevert("Invalid WETH token");
        xcup.initializeV2(address(priceConsumer), address(router), address(usdcToken), address(0));
    }

    function testInitializeV2RevertNotOwner() public {
        vm.prank(unauthorized);
        vm.expectRevert();
        xcup.initializeV2(address(priceConsumer), address(router), address(usdcToken), address(wethToken));
    }

    function testDeposit() public {
        uint256 depositAmount = 1000e6; // 1000 CUP

        vm.startPrank(user1);
        cupToken.approve(address(xcup), depositAmount);

        vm.expectEmit(true, true, false, true);
        emit Deposit(user1, user1, depositAmount, depositAmount);

        uint256 shares = xcup.deposit(depositAmount, user1);
        vm.stopPrank();

        assertEq(shares, depositAmount); // 1:1 ratio initially
        assertEq(xcup.balanceOf(user1), depositAmount);
        assertEq(xcup.totalSupply(), depositAmount);
        assertEq(xcup.totalAssets(), depositAmount);
    }

    function testMint() public {
        uint256 shareAmount = 1000e6; // 1000 shares

        vm.startPrank(user1);
        cupToken.approve(address(xcup), shareAmount);

        uint256 assets = xcup.mint(shareAmount, user1);
        vm.stopPrank();

        assertEq(assets, shareAmount); // 1:1 ratio initially
        assertEq(xcup.balanceOf(user1), shareAmount);
        assertEq(xcup.totalSupply(), shareAmount);
        assertEq(xcup.totalAssets(), shareAmount);
    }

    function testWithdrawOnlyRedeemer() public {
        // Setup: deposit first
        uint256 depositAmount = 1000e6;
        vm.startPrank(user1);
        cupToken.approve(address(xcup), depositAmount);
        xcup.deposit(depositAmount, user1);
        vm.stopPrank();

        // Only redeemer should be able to withdraw
        vm.prank(user1);
        vm.expectRevert();
        xcup.withdraw(depositAmount, user1, user1);

        // Redeemer should be able to withdraw
        vm.prank(redeemer);
        uint256 shares = xcup.withdraw(depositAmount, user1, user1);

        assertEq(shares, depositAmount);
        assertEq(xcup.balanceOf(user1), 0);
        assertEq(cupToken.balanceOf(user1), INITIAL_CUP_SUPPLY); // Back to original
    }

    function testRedeemOnlyRedeemer() public {
        // Setup: deposit first
        uint256 depositAmount = 1000e6;
        vm.startPrank(user1);
        cupToken.approve(address(xcup), depositAmount);
        xcup.deposit(depositAmount, user1);
        vm.stopPrank();

        // Only redeemer should be able to redeem
        vm.prank(user1);
        vm.expectRevert();
        xcup.redeem(depositAmount, user1, user1);

        // Redeemer should be able to redeem
        vm.prank(redeemer);
        uint256 assets = xcup.redeem(depositAmount, user1, user1);

        assertEq(assets, depositAmount);
        assertEq(xcup.balanceOf(user1), 0);
        assertEq(cupToken.balanceOf(user1), INITIAL_CUP_SUPPLY); // Back to original
    }

    function testPauseAndUnpause() public {
        xcup.pause();
        assertTrue(xcup.paused());

        xcup.unpause();
        assertFalse(xcup.paused());
    }

    function testPauseRevertNotOwner() public {
        vm.prank(unauthorized);
        vm.expectRevert();
        xcup.pause();
    }

    function testUnpauseRevertNotOwner() public {
        xcup.pause();

        vm.prank(unauthorized);
        vm.expectRevert();
        xcup.unpause();
    }

    function testGetCopperPrice() public {
        xcup.initializeV2(address(priceConsumer), address(router), address(usdcToken), address(wethToken));

        uint256 price = xcup.getCopperPrice();
        assertEq(price, INITIAL_COPPER_PRICE);

        // Update price and test again
        uint256 newPrice = 500000000; // $5.00
        priceConsumer.setPrice(newPrice);
        assertEq(xcup.getCopperPrice(), newPrice);
    }

    function testSetCopperPriceConsumer() public {
        xcup.initializeV2(address(priceConsumer), address(router), address(usdcToken), address(wethToken));

        CopperPriceConsumerMock newPriceConsumer = new CopperPriceConsumerMock();
        newPriceConsumer.setPrice(500000000);

        vm.expectEmit(true, true, false, false);
        emit CopperPriceConsumerUpdated(address(priceConsumer), address(newPriceConsumer));

        xcup.setCopperPriceConsumer(address(newPriceConsumer));

        assertEq(address(xcup.copperPriceConsumer()), address(newPriceConsumer));
        assertEq(xcup.getCopperPrice(), 500000000);
    }

    function testSetCopperPriceConsumerRevertInvalidAddress() public {
        vm.expectRevert("Invalid copper price consumer");
        xcup.setCopperPriceConsumer(address(0));
    }

    function testSetCopperPriceConsumerRevertNotOwner() public {
        vm.prank(unauthorized);
        vm.expectRevert();
        xcup.setCopperPriceConsumer(address(priceConsumer));
    }

    function testGetXcupPriceInToken() public {
        xcup.initializeV2(address(priceConsumer), address(router), address(usdcToken), address(wethToken));

        uint256 xcupAmount = 1000e6; // 1000 xCUP

        // Test with USDC
        uint256 usdcPrice = xcup.getXcupPriceInToken(address(usdcToken), xcupAmount);
        assertGt(usdcPrice, 0);

        // Test with WETH (should use router)
        uint256 wethPrice = xcup.getXcupPriceInToken(address(wethToken), xcupAmount);
        assertGt(wethPrice, 0);

        // Test with ETH (address(0) should use WETH)
        uint256 ethPrice = xcup.getXcupPriceInToken(address(0), xcupAmount);
        assertEq(ethPrice, wethPrice);
    }

    function testGetXcupPriceInTokenRevertNotInitialized() public {
        vm.expectRevert("Copper price consumer not initialized");
        xcup.getXcupPriceInToken(address(usdcToken), 1000e6);
    }

    function testGetXcupPriceInTokenRevertZeroAmount() public {
        xcup.initializeV2(address(priceConsumer), address(router), address(usdcToken), address(wethToken));

        vm.expectRevert("Amount must be > 0");
        xcup.getXcupPriceInToken(address(usdcToken), 0);
    }

    function testGetTokenToXcupExchangeRate() public {
        xcup.initializeV2(address(priceConsumer), address(router), address(usdcToken), address(wethToken));

        uint256 tokenAmount = 1000e6; // 1000 USDC

        // Test with USDC
        uint256 xcupFromUsdc = xcup.getTokenToXcupExchangeRate(address(usdcToken), tokenAmount);
        assertGt(xcupFromUsdc, 0);

        // Test with WETH
        uint256 wethAmount = 1e18; // 1 WETH
        uint256 xcupFromWeth = xcup.getTokenToXcupExchangeRate(address(wethToken), wethAmount);
        assertGt(xcupFromWeth, 0);

        // Test with ETH (address(0))
        uint256 xcupFromEth = xcup.getTokenToXcupExchangeRate(address(0), wethAmount);
        assertEq(xcupFromEth, xcupFromWeth);
    }

    function testGetTokenToXcupExchangeRateRevertNotInitialized() public {
        vm.expectRevert("Copper price consumer not initialized");
        xcup.getTokenToXcupExchangeRate(address(usdcToken), 1000e6);
    }

    function testGetTokenToXcupExchangeRateRevertZeroAmount() public {
        xcup.initializeV2(address(priceConsumer), address(router), address(usdcToken), address(wethToken));

        vm.expectRevert("Amount must be > 0");
        xcup.getTokenToXcupExchangeRate(address(usdcToken), 0);
    }

    function testSetUniswapRouter() public {
        xcup.initializeV2(address(priceConsumer), address(router), address(usdcToken), address(wethToken));

        MockUniswapRouter newRouter = new MockUniswapRouter();

        vm.expectEmit(true, true, false, false);
        emit UniswapRouterUpdated(address(router), address(newRouter));

        xcup.setUniswapRouter(address(newRouter));

        assertEq(address(xcup.uniswapRouter()), address(newRouter));
    }

    function testSetUniswapRouterRevertInvalidAddress() public {
        vm.expectRevert("Invalid Uniswap router");
        xcup.setUniswapRouter(address(0));
    }

    function testSetUsdcToken() public {
        xcup.initializeV2(address(priceConsumer), address(router), address(usdcToken), address(wethToken));

        ERC20Mock newUsdc = new ERC20Mock("New USDC", "USDC2", 6);

        vm.expectEmit(true, true, false, false);
        emit UsdcTokenUpdated(address(usdcToken), address(newUsdc));

        xcup.setUsdcToken(address(newUsdc));

        assertEq(address(xcup.usdcToken()), address(newUsdc));
    }

    function testSetUsdcTokenRevertInvalidAddress() public {
        vm.expectRevert("Invalid USDC token");
        xcup.setUsdcToken(address(0));
    }

    function testSetWethToken() public {
        xcup.initializeV2(address(priceConsumer), address(router), address(usdcToken), address(wethToken));

        ERC20Mock newWeth = new ERC20Mock("New WETH", "WETH2", 18);

        vm.expectEmit(true, true, false, false);
        emit WethTokenUpdated(address(wethToken), address(newWeth));

        xcup.setWethToken(address(newWeth));

        assertEq(xcup.wethToken(), address(newWeth));
    }

    function testSetWethTokenRevertInvalidAddress() public {
        vm.expectRevert("Invalid WETH token");
        xcup.setWethToken(address(0));
    }

    function testConvertToShares() public {
        // Initially 1:1 ratio
        assertEq(xcup.convertToShares(1000e6), 1000e6);

        // After some deposits, ratio might change
        vm.startPrank(user1);
        cupToken.approve(address(xcup), 1000e6);
        xcup.deposit(1000e6, user1);
        vm.stopPrank();

        // Should still be 1:1 for now
        assertEq(xcup.convertToShares(1000e6), 1000e6);
    }

    function testConvertToAssets() public {
        // Initially 1:1 ratio
        assertEq(xcup.convertToAssets(1000e6), 1000e6);

        // After some deposits
        vm.startPrank(user1);
        cupToken.approve(address(xcup), 1000e6);
        xcup.deposit(1000e6, user1);
        vm.stopPrank();

        // Should still be 1:1 for now
        assertEq(xcup.convertToAssets(1000e6), 1000e6);
    }

    function testPreviewDeposit() public {
        uint256 assets = 1000e6;
        uint256 expectedShares = xcup.previewDeposit(assets);

        vm.startPrank(user1);
        cupToken.approve(address(xcup), assets);
        uint256 actualShares = xcup.deposit(assets, user1);
        vm.stopPrank();

        assertEq(actualShares, expectedShares);
    }

    function testPreviewMint() public {
        uint256 shares = 1000e6;
        uint256 expectedAssets = xcup.previewMint(shares);

        vm.startPrank(user1);
        cupToken.approve(address(xcup), expectedAssets);
        uint256 actualAssets = xcup.mint(shares, user1);
        vm.stopPrank();

        assertEq(actualAssets, expectedAssets);
    }

    function testMaxDeposit() public {
        // Should return max uint256 when not paused
        assertEq(xcup.maxDeposit(user1), type(uint256).max);

        // Should return 0 when paused
        xcup.pause();
        assertEq(xcup.maxDeposit(user1), 0);
    }

    function testMaxMint() public {
        // Should return max uint256 when not paused
        assertEq(xcup.maxMint(user1), type(uint256).max);

        // Should return 0 when paused
        xcup.pause();
        assertEq(xcup.maxMint(user1), 0);
    }

    function testMultipleUsersDeposit() public {
        uint256 depositAmount1 = 1000e6;
        uint256 depositAmount2 = 2000e6;

        // User1 deposits
        vm.startPrank(user1);
        cupToken.approve(address(xcup), depositAmount1);
        uint256 shares1 = xcup.deposit(depositAmount1, user1);
        vm.stopPrank();

        // User2 deposits
        vm.startPrank(user2);
        cupToken.approve(address(xcup), depositAmount2);
        uint256 shares2 = xcup.deposit(depositAmount2, user2);
        vm.stopPrank();

        assertEq(xcup.balanceOf(user1), shares1);
        assertEq(xcup.balanceOf(user2), shares2);
        assertEq(xcup.totalSupply(), shares1 + shares2);
        assertEq(xcup.totalAssets(), depositAmount1 + depositAmount2);
    }

    function testRoleManagement() public {
        address newRedeemer = makeAddr("newRedeemer");

        // Grant role
        xcup.grantRole(xcup.REDEEMER_ROLE(), newRedeemer);
        assertTrue(xcup.hasRole(xcup.REDEEMER_ROLE(), newRedeemer));

        // Revoke role
        xcup.revokeRole(xcup.REDEEMER_ROLE(), newRedeemer);
        assertFalse(xcup.hasRole(xcup.REDEEMER_ROLE(), newRedeemer));
    }

    function testInitializeOnlyOnce() public {
        // Try to initialize again - should revert
        vm.expectRevert();
        xcup.initialize(IERC20(address(cupToken)), "xCUP Vault", "xCUP");
    }

    function testAssetFunction() public {
        assertEq(xcup.asset(), address(cupToken));
    }

    function testDecimalsFunction() public {
        assertEq(xcup.decimals(), 6);
    }

    function testPriceCalculationEdgeCases() public {
        xcup.initializeV2(address(priceConsumer), address(router), address(usdcToken), address(wethToken));

        // Test with zero copper price
        priceConsumer.setPrice(0);
        vm.expectRevert("Invalid copper price");
        xcup.getXcupPriceInToken(address(usdcToken), 1000e6);

        // Reset price
        priceConsumer.setPrice(INITIAL_COPPER_PRICE);

        // Test with very small amount
        uint256 smallAmount = 1; // 1 wei
        uint256 price = xcup.getXcupPriceInToken(address(usdcToken), smallAmount);
        // Should not revert and return some value
        assertGe(price, 0);
    }
}
