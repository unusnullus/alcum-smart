// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test, console} from "forge-std/Test.sol";
import {xCUP} from "../contracts/xCUP.sol";
import {CUPToken} from "../contracts/CUPToken.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ICopperPriceConsumer} from "../contracts/interfaces/ICopperPriceConsumer.sol";
import {IUniswapV2Router02} from "@uniswap/v2-periphery/contracts/interfaces/IUniswapV2Router02.sol";

// Mock contracts for testing
contract MockCopperPriceConsumer is ICopperPriceConsumer {
    uint256 public price = 450000000; // $4.50 with 8 decimals

    function requestCopperPrice() external pure returns (bytes32) {
        return bytes32(0);
    }

    function fulfill(bytes32, uint256) external pure {
        revert("Not implemented");
    }

    function getPriceAsDecimal() external view returns (uint256) {
        return price / 10 ** 8;
    }

    function updatePrice(uint256 _price) external {
        price = _price;
    }
}

contract MockUSDC {
    function decimals() external pure returns (uint8) {
        return 6;
    }
}

contract MockUniswapRouter is IUniswapV2Router02 {
    function WETH() external pure returns (address) {
        return address(0x1234567890123456789012345678901234567890);
    }

    function getAmountsOut(uint256 amountIn, address[] calldata path) external pure returns (uint256[] memory amounts) {
        amounts = new uint256[](2);
        amounts[0] = amountIn;
        amounts[1] = amountIn; // 1:1 for testing
    }

    function swapExactTokensForTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external pure returns (uint256[] memory amounts) {
        amounts = new uint256[](2);
        amounts[0] = amountIn;
        amounts[1] = amountOutMin;
    }

    function swapExactETHForTokens(uint256 amountOutMin, address[] calldata path, address to, uint256 deadline)
        external
        payable
        returns (uint256[] memory amounts)
    {
        amounts = new uint256[](2);
        amounts[0] = msg.value;
        amounts[1] = amountOutMin;
    }

    function addLiquidity(
        address tokenA,
        address tokenB,
        uint256 amountADesired,
        uint256 amountBDesired,
        uint256 amountAMin,
        uint256 amountBMin,
        address to,
        uint256 deadline
    ) external pure returns (uint256 amountA, uint256 amountB, uint256 liquidity) {
        return (amountADesired, amountBDesired, 1000);
    }

    function removeLiquidity(
        address tokenA,
        address tokenB,
        uint256 liquidity,
        uint256 amountAMin,
        uint256 amountBMin,
        address to,
        uint256 deadline
    ) external pure returns (uint256 amountA, uint256 amountB) {
        return (amountAMin, amountBMin);
    }

    function swapExactTokensForETH(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external pure returns (uint256[] memory amounts) {
        amounts = new uint256[](2);
        amounts[0] = amountIn;
        amounts[1] = amountOutMin;
    }

    function swapETHForExactTokens(uint256 amountOut, address[] calldata path, address to, uint256 deadline)
        external
        payable
        returns (uint256[] memory amounts)
    {
        amounts = new uint256[](2);
        amounts[0] = msg.value;
        amounts[1] = amountOut;
    }

    function getAmountIn(uint256 amountOut, uint256 reserveIn, uint256 reserveOut)
        external
        pure
        returns (uint256 amountIn)
    {
        return amountOut;
    }

    function getAmountOut(uint256 amountIn, uint256 reserveIn, uint256 reserveOut)
        external
        pure
        returns (uint256 amountOut)
    {
        return amountIn;
    }

    function removeLiquidityETH(
        address token,
        uint256 liquidity,
        uint256 amountTokenMin,
        uint256 amountETHMin,
        address to,
        uint256 deadline
    ) external pure returns (uint256 amountToken, uint256 amountETH) {
        return (amountTokenMin, amountETHMin);
    }

    function removeLiquidityETHSupportingFeeOnTransferTokens(
        address token,
        uint256 liquidity,
        uint256 amountTokenMin,
        uint256 amountETHMin,
        address to,
        uint256 deadline
    ) external pure returns (uint256 amountETH) {
        return amountETHMin;
    }

    function removeLiquidityETHWithPermit(
        address token,
        uint256 liquidity,
        uint256 amountTokenMin,
        uint256 amountETHMin,
        address to,
        uint256 deadline,
        bool approveMax,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) external pure returns (uint256 amountToken, uint256 amountETH) {
        return (amountTokenMin, amountETHMin);
    }

    function removeLiquidityETHWithPermitSupportingFeeOnTransferTokens(
        address token,
        uint256 liquidity,
        uint256 amountTokenMin,
        uint256 amountETHMin,
        address to,
        uint256 deadline,
        bool approveMax,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) external pure returns (uint256 amountETH) {
        return amountETHMin;
    }

    function swapExactTokensForTokensSupportingFeeOnTransferTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external pure {}

    function swapExactETHForTokensSupportingFeeOnTransferTokens(
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external payable {}

    function swapExactTokensForETHSupportingFeeOnTransferTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external pure {}

    function factory() external pure returns (address) {
        return address(0x456);
    }

    function addLiquidityETH(
        address token,
        uint256 amountTokenDesired,
        uint256 amountTokenMin,
        uint256 amountETHMin,
        address to,
        uint256 deadline
    ) external payable returns (uint256 amountToken, uint256 amountETH, uint256 liquidity) {
        return (amountTokenDesired, msg.value, 1000);
    }

    function getAmountsIn(uint256 amountOut, address[] calldata path) external pure returns (uint256[] memory amounts) {
        amounts = new uint256[](2);
        amounts[0] = amountOut;
        amounts[1] = amountOut;
    }

    function quote(uint256 amountA, uint256 reserveA, uint256 reserveB) external pure returns (uint256 amountB) {
        return amountA;
    }

    function removeLiquidityWithPermit(
        address tokenA,
        address tokenB,
        uint256 liquidity,
        uint256 amountAMin,
        uint256 amountBMin,
        address to,
        uint256 deadline,
        bool approveMax,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) external pure returns (uint256 amountA, uint256 amountB) {
        return (amountAMin, amountBMin);
    }

    function swapTokensForExactETH(
        uint256 amountOut,
        uint256 amountInMax,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external pure returns (uint256[] memory amounts) {
        amounts = new uint256[](2);
        amounts[0] = amountInMax;
        amounts[1] = amountOut;
    }

    function swapTokensForExactTokens(
        uint256 amountOut,
        uint256 amountInMax,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external pure returns (uint256[] memory amounts) {
        amounts = new uint256[](2);
        amounts[0] = amountInMax;
        amounts[1] = amountOut;
    }
}

contract xCUPTest is Test {
    xCUP public xcup;
    CUPToken public cupToken;
    MockCopperPriceConsumer public copperPriceConsumer;
    MockUniswapRouter public uniswapRouter;
    MockUSDC public usdc;
    address public owner;
    address public user;

    function setUp() public {
        owner = address(this);
        user = makeAddr("user");

        // Deploy dependencies
        CUPToken cupImpl = new CUPToken();
        bytes memory cupInitData = abi.encodeWithSelector(CUPToken.initialize.selector);
        ERC1967Proxy cupProxy = new ERC1967Proxy(address(cupImpl), cupInitData);
        cupToken = CUPToken(address(cupProxy));

        copperPriceConsumer = new MockCopperPriceConsumer();
        uniswapRouter = new MockUniswapRouter();
        usdc = new MockUSDC();

        // Deploy xCUP implementation
        xCUP implementation = new xCUP();

        // Deploy proxy
        bytes memory initData = abi.encodeWithSelector(
            xCUP.initialize.selector,
            IERC20(address(cupToken)),
            "xCUP Vault",
            "xCUP",
            address(copperPriceConsumer),
            address(uniswapRouter),
            address(usdc),
            address(0x1234567890123456789012345678901234567890) // Mock WETH
        );
        ERC1967Proxy proxy = new ERC1967Proxy(address(implementation), initData);

        xcup = xCUP(address(proxy));

        // Grant xCUP the minter role
        cupToken.grantRole(cupToken.MINTER_ROLE(), address(xcup));

        // Grant user the REDEEMER_ROLE for testing
        xcup.grantRole(xcup.REDEEMER_ROLE(), user);
    }

    function testInitialization() public {
        assertEq(xcup.name(), "xCUP Vault");
        assertEq(xcup.symbol(), "xCUP");
        assertEq(xcup.decimals(), 6);
        assertEq(address(xcup.asset()), address(cupToken));
        assertTrue(xcup.hasRole(xcup.DEFAULT_ADMIN_ROLE(), owner));
    }

    function testDeposit() public {
        uint256 amount = 1000 * 10 ** 6;

        // Mint CUP tokens to user
        cupToken.grantRole(cupToken.MINTER_ROLE(), address(this));
        cupToken.mint(user, amount);

        vm.startPrank(user);
        cupToken.approve(address(xcup), amount);
        uint256 shares = xcup.deposit(amount, user);
        vm.stopPrank();

        assertEq(xcup.balanceOf(user), shares);
        assertEq(xcup.totalSupply(), shares);
    }

    function testWithdraw() public {
        uint256 amount = 1000 * 10 ** 6;

        // First deposit
        cupToken.grantRole(cupToken.MINTER_ROLE(), address(this));
        cupToken.mint(user, amount);

        vm.startPrank(user);
        cupToken.approve(address(xcup), amount);
        uint256 shares = xcup.deposit(amount, user);

        // Then withdraw
        uint256 withdrawn = xcup.withdraw(amount, user, user);
        vm.stopPrank();

        assertEq(withdrawn, amount);
        assertEq(xcup.balanceOf(user), 0);
    }

    function testRedeem() public {
        uint256 amount = 1000 * 10 ** 6;

        // First deposit
        cupToken.grantRole(cupToken.MINTER_ROLE(), address(this));
        cupToken.mint(user, amount);

        vm.startPrank(user);
        cupToken.approve(address(xcup), amount);
        uint256 shares = xcup.deposit(amount, user);

        // Then redeem
        uint256 redeemed = xcup.redeem(shares, user, user);
        vm.stopPrank();

        assertEq(redeemed, amount);
        assertEq(xcup.balanceOf(user), 0);
    }

    function testPause() public {
        xcup.pause();
        assertTrue(xcup.paused());
    }

    function testUnpause() public {
        xcup.pause();
        xcup.unpause();
        assertFalse(xcup.paused());
    }

    function testGetCopperPrice() public {
        uint256 price = xcup.getCopperPrice();
        assertEq(price, 450000000); // $4.50 with 8 decimals
    }

    function testSetCopperPriceConsumer() public {
        MockCopperPriceConsumer newConsumer = new MockCopperPriceConsumer();
        xcup.setCopperPriceConsumer(address(newConsumer));
        // Can't test directly as it's private, but function should not revert
    }

    function testSetCopperPriceConsumerWithoutRole() public {
        vm.prank(user);
        vm.expectRevert();
        xcup.setCopperPriceConsumer(address(0));
    }

    function testSetUniswapRouter() public {
        address newRouter = makeAddr("newRouter");
        xcup.setUniswapRouter(newRouter);
        assertEq(address(xcup.uniswapRouter()), newRouter);
    }

    function testSetUniswapRouterWithoutRole() public {
        vm.prank(user);
        vm.expectRevert();
        xcup.setUniswapRouter(makeAddr("newRouter"));
    }

    function testSetUsdcToken() public {
        address newUsdc = makeAddr("newUsdc");
        xcup.setUsdcToken(newUsdc);
        assertEq(address(xcup.usdcToken()), newUsdc);
    }

    function testSetUsdcTokenWithoutRole() public {
        vm.prank(user);
        vm.expectRevert();
        xcup.setUsdcToken(makeAddr("newUsdc"));
    }

    function testSetWethToken() public {
        address newWeth = makeAddr("newWeth");
        xcup.setWethToken(newWeth);
        assertEq(address(xcup.wethToken()), newWeth);
    }

    function testSetWethTokenWithoutRole() public {
        vm.prank(user);
        vm.expectRevert();
        xcup.setWethToken(makeAddr("newWeth"));
    }

    function testGetXcupPriceInToken() public {
        uint256 xcupAmount = 1000 * 10 ** 6;
        uint256 price = xcup.getXcupPriceInToken(address(usdc), xcupAmount);
        assertTrue(price > 0);
    }

    function testGetTokenToXcupExchangeRate() public {
        uint256 tokenAmount = 1000 * 10 ** 6;
        uint256 rate = xcup.getTokenToXcupExchangeRate(address(usdc), tokenAmount);
        assertTrue(rate > 0);
    }

    function testDecimals() public {
        assertEq(xcup.decimals(), 6);
    }

    function testWithdrawWithoutRole() public {
        uint256 amount = 1000 * 10 ** 6;
        vm.prank(user);
        vm.expectRevert();
        xcup.withdraw(amount, user, user);
    }

    function testRedeemWithoutRole() public {
        uint256 shares = 1000 * 10 ** 6;
        vm.prank(user);
        vm.expectRevert();
        xcup.redeem(shares, user, user);
    }

    function testSetCopperPriceConsumerInvalidAddress() public {
        vm.expectRevert(xCUP.InvalidAddress.selector);
        xcup.setCopperPriceConsumer(address(0));
    }

    function testSetUniswapRouterInvalidAddress() public {
        vm.expectRevert("Invalid Uniswap router");
        xcup.setUniswapRouter(address(0));
    }

    function testSetUsdcTokenInvalidAddress() public {
        vm.expectRevert("Invalid USDC token");
        xcup.setUsdcToken(address(0));
    }

    function testSetWethTokenInvalidAddress() public {
        vm.expectRevert("Invalid WETH token");
        xcup.setWethToken(address(0));
    }

    function testGetXcupPriceInTokenWithZeroAmount() public {
        vm.expectRevert(xCUP.InvalidAmount.selector);
        xcup.getXcupPriceInToken(address(usdc), 0);
    }

    function testGetTokenToXcupExchangeRateWithZeroAmount() public {
        vm.expectRevert("Amount must be > 0");
        xcup.getTokenToXcupExchangeRate(address(usdc), 0);
    }

    function testDepositWithMaxAmount() public {
        uint256 amount = type(uint256).max;
        vm.expectRevert(); // Should revert due to insufficient balance
        xcup.deposit(amount, user);
    }

    function testRedeemWithMaxShares() public {
        uint256 shares = type(uint256).max;
        vm.expectRevert(); // Should revert due to insufficient shares
        xcup.redeem(shares, user, user);
    }

    function testWithdrawWithMaxAmount() public {
        uint256 amount = type(uint256).max;
        vm.expectRevert(); // Should revert due to insufficient balance
        xcup.withdraw(amount, user, user);
    }

    function testPauseWhenAlreadyPaused() public {
        xcup.pause();
        vm.expectRevert(); // Should revert when already paused
        xcup.pause();
    }

    function testUnpauseWhenNotPaused() public {
        vm.expectRevert(); // Should revert when not paused
        xcup.unpause();
    }

    // Test initialization error cases for better branch coverage
    function testInitializeWithZeroUnderlying() public {
        xCUP xcupImpl = new xCUP();
        bytes memory xcupInitData = abi.encodeWithSelector(
            xCUP.initialize.selector,
            IERC20(address(0)), // Zero underlying
            "xCUP Vault",
            "xCUP",
            address(copperPriceConsumer),
            address(uniswapRouter),
            address(usdc),
            address(0x1234567890123456789012345678901234567890)
        );

        vm.expectRevert(xCUP.InvalidAddress.selector);
        new ERC1967Proxy(address(xcupImpl), xcupInitData);
    }

    function testInitializeWithZeroCopperPriceConsumer() public {
        xCUP xcupImpl = new xCUP();
        bytes memory xcupInitData = abi.encodeWithSelector(
            xCUP.initialize.selector,
            IERC20(address(cupToken)),
            "xCUP Vault",
            "xCUP",
            address(0), // Zero copper price consumer
            address(uniswapRouter),
            address(usdc),
            address(0x1234567890123456789012345678901234567890)
        );

        vm.expectRevert(xCUP.InvalidAddress.selector);
        new ERC1967Proxy(address(xcupImpl), xcupInitData);
    }

    function testInitializeWithZeroUniswapRouter() public {
        xCUP xcupImpl = new xCUP();
        bytes memory xcupInitData = abi.encodeWithSelector(
            xCUP.initialize.selector,
            IERC20(address(cupToken)),
            "xCUP Vault",
            "xCUP",
            address(copperPriceConsumer),
            address(0), // Zero uniswap router
            address(usdc),
            address(0x1234567890123456789012345678901234567890)
        );

        vm.expectRevert(xCUP.InvalidAddress.selector);
        new ERC1967Proxy(address(xcupImpl), xcupInitData);
    }

    function testInitializeWithZeroUsdcToken() public {
        xCUP xcupImpl = new xCUP();
        bytes memory xcupInitData = abi.encodeWithSelector(
            xCUP.initialize.selector,
            IERC20(address(cupToken)),
            "xCUP Vault",
            "xCUP",
            address(copperPriceConsumer),
            address(uniswapRouter),
            address(0), // Zero USDC token
            address(0x1234567890123456789012345678901234567890)
        );

        vm.expectRevert(xCUP.InvalidAddress.selector);
        new ERC1967Proxy(address(xcupImpl), xcupInitData);
    }

    function testInitializeWithZeroWethToken() public {
        xCUP xcupImpl = new xCUP();
        bytes memory xcupInitData = abi.encodeWithSelector(
            xCUP.initialize.selector,
            IERC20(address(cupToken)),
            "xCUP Vault",
            "xCUP",
            address(copperPriceConsumer),
            address(uniswapRouter),
            address(usdc),
            address(0) // Zero WETH token
        );

        vm.expectRevert(xCUP.InvalidAddress.selector);
        new ERC1967Proxy(address(xcupImpl), xcupInitData);
    }
}
