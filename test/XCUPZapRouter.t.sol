// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {Upgrades} from "openzeppelin-foundry-upgrades/Upgrades.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC20Mock} from "../contracts/mock/ERC20Mock.sol";

import {XCUPZapRouter} from "../contracts/XCUPZapRouter.sol";
import {IUniswapRouterV2} from "../contracts/interfaces/IUniswapRouterV2.sol";
import {IXCUPRatePool} from "../contracts/interfaces/IXCUPRatePool.sol";

// Mock Uniswap Router
contract MockUniswapRouter is IUniswapRouterV2 {
    mapping(address => mapping(address => uint256)) public rates;
    bool public shouldRevert;
    address public constant WETH_ADDRESS = 0xfFf9976782d46CC05630D1f6eBAb18b2324d6B14;

    function setRate(address tokenA, address tokenB, uint256 rate) external {
        rates[tokenA][tokenB] = rate;
    }

    function setShouldRevert(bool _shouldRevert) external {
        shouldRevert = _shouldRevert;
    }

    function _calculateAmountsOut(
        uint256 amountIn,
        address[] memory path
    ) internal view returns (uint256[] memory amounts) {
        amounts = new uint256[](path.length);
        amounts[0] = amountIn;

        for (uint256 i = 1; i < path.length; i++) {
            uint256 rate = rates[path[i - 1]][path[i]];
            if (rate == 0) rate = 1e18; // Default 1:1 rate
            amounts[i] = (amounts[i - 1] * rate) / 1e18;
        }
    }

    function getAmountsOut(uint256 amountIn, address[] memory path) external view returns (uint256[] memory amounts) {
        if (shouldRevert) revert("Router: INSUFFICIENT_LIQUIDITY");
        return _calculateAmountsOut(amountIn, path);
    }

    function swapExactTokensForTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 /* deadline */
    ) external returns (uint256[] memory amounts) {
        if (shouldRevert) revert("Router: INSUFFICIENT_OUTPUT_AMOUNT");

        amounts = _calculateAmountsOut(amountIn, path);
        require(amounts[amounts.length - 1] >= amountOutMin, "Router: INSUFFICIENT_OUTPUT_AMOUNT");

        // Transfer tokens
        IERC20(path[0]).transferFrom(msg.sender, address(this), amountIn);
        IERC20(path[path.length - 1]).transfer(to, amounts[amounts.length - 1]);
    }

    function swapExactTokensForTokensSupportingFeeOnTransferTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 /* deadline */
    ) external {
        uint256[] memory amounts = _calculateAmountsOut(amountIn, path);
        require(amounts[amounts.length - 1] >= amountOutMin, "Router: INSUFFICIENT_OUTPUT_AMOUNT");

        // Transfer tokens
        IERC20(path[0]).transferFrom(msg.sender, address(this), amountIn);
        IERC20(path[path.length - 1]).transfer(to, amounts[amounts.length - 1]);
    }

    function swapExactETHForTokens(
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external payable returns (uint256[] memory amounts) {
        revert("Not implemented");
    }

    function swapTokensForExactTokens(
        uint256 amountOut,
        uint256 amountInMax,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external returns (uint256[] memory amounts) {
        revert("Not implemented");
    }

    function addLiquidity(
        address tokenA,
        address tokenB,
        uint amountADesired,
        uint amountBDesired,
        uint amountAMin,
        uint amountBMin,
        address to,
        uint deadline
    ) external returns (uint amountA, uint amountB, uint liquidity) {
        revert("Not implemented");
    }

    function getAmountsIn(uint amountOut, address[] memory path) external view returns (uint[] memory amounts) {
        if (shouldRevert) revert("Router: INSUFFICIENT_LIQUIDITY");
        // Reverse calculation: work backwards from output
        amounts = new uint256[](path.length);
        amounts[path.length - 1] = amountOut;

        for (uint256 i = path.length - 1; i > 0; i--) {
            uint256 rate = rates[path[i - 1]][path[i]];
            if (rate == 0) rate = 1e18; // Default 1:1 rate
            // Reverse: if output is X and rate is R, input is X * 1e18 / R
            amounts[i - 1] = (amounts[i] * 1e18) / rate;
        }
    }

    function WETH() external pure returns (address) {
        return WETH_ADDRESS;
    }
}

// Mock XCUP Pool (simplified version for testing)
contract MockXCUPPool is IXCUPRatePool {
    IERC20 public xcup;
    IERC20 public usdc;
    uint16 public swapFee = 50; // 0.5%

    mapping(address => uint256) public reserves;

    constructor(address _xcup, address _usdc) {
        xcup = IERC20(_xcup);
        usdc = IERC20(_usdc);
    }

    function setReserves(uint256 xcupReserve, uint256 usdcReserve) external {
        reserves[address(xcup)] = xcupReserve;
        reserves[address(usdc)] = usdcReserve;
    }

    function getReserves() external view returns (uint256 reserveXCUP, uint256 reserveUSDC) {
        reserveXCUP = reserves[address(xcup)];
        reserveUSDC = reserves[address(usdc)];
    }

    function swapExactXCUPToUSDC(uint256 xcupAmountIn, uint256 minUSDCOut) external {
        require(xcupAmountIn > 0, "Zero amount");

        (uint256 rX, uint256 rU) = this.getReserves();
        require(rX > 0 && rU > 0, "Empty reserves");

        // Simple constant product formula for testing
        uint256 amountInWithFee = (xcupAmountIn * (10000 - swapFee)) / 10000;
        uint256 usdcOut = (amountInWithFee * rU) / (rX + amountInWithFee);

        require(usdcOut >= minUSDCOut && usdcOut > 0, "Slippage");

        // Transfer tokens
        xcup.transferFrom(msg.sender, address(this), xcupAmountIn);
        usdc.transfer(msg.sender, usdcOut);

        // Update reserves
        reserves[address(xcup)] += xcupAmountIn;
        reserves[address(usdc)] -= usdcOut;
    }
}

contract XCUPZapRouterTest is Test {
    XCUPZapRouter public zapRouter;
    MockUniswapRouter public uniswapRouter;
    MockXCUPPool public xcupPool;
    ERC20Mock public xcup;
    ERC20Mock public usdc;
    ERC20Mock public tokenOut;
    ERC20Mock public weth;

    address public owner = address(0x1);
    address public user = address(0x2);

    uint256 constant ONE_XCUP = 1e6; // 6 decimals
    uint256 constant ONE_USDC = 1e6; // 6 decimals
    uint256 constant ONE_TOKEN = 1e18; // 18 decimals

    event ZapExecuted(address indexed user, address indexed tokenOut, uint256 xcupAmountIn, uint256 tokenAmountOut);
    event ConfigUpdated(address indexed uniswapRouter, address indexed xcupPool, address indexed xcup, address usdc);
    event SlippageToleranceUpdated(uint256 oldTolerance, uint256 newTolerance);

    function setUp() public {
        vm.startPrank(owner);

        // Deploy mock tokens
        xcup = new ERC20Mock("xCUP", "XCUP", 6);
        usdc = new ERC20Mock("USDC", "USDC", 6);
        tokenOut = new ERC20Mock("TokenOut", "TOUT", 18);
        weth = new ERC20Mock("WETH", "WETH", 18);

        // Deploy mock router
        uniswapRouter = new MockUniswapRouter();

        // Deploy mock pool
        xcupPool = new MockXCUPPool(address(xcup), address(usdc));

        // Set up pool reserves (1000 XCUP : 1000 USDC = 1:1)
        xcup.mint(address(xcupPool), 1000 * ONE_XCUP);
        usdc.mint(address(xcupPool), 1000 * ONE_USDC);
        xcupPool.setReserves(1000 * ONE_XCUP, 1000 * ONE_USDC);

        // Deploy zap router
        address zapRouterProxy = Upgrades.deployTransparentProxy(
            "XCUPZapRouter.sol:XCUPZapRouter",
            owner,
            abi.encodeCall(
                XCUPZapRouter.initialize,
                (address(uniswapRouter), address(xcupPool), address(xcup), address(usdc))
            )
        );
        zapRouter = XCUPZapRouter(zapRouterProxy);

        // Set up Uniswap rates
        // USDC -> TokenOut: 1 USDC = 1 TokenOut (1e6 -> 1e18, so rate = 1e18)
        uniswapRouter.setRate(address(usdc), address(tokenOut), 1e18);
        // USDC -> WETH: 1 USDC = 0.0005 WETH (1e6 -> 0.0005e18, so rate = 5e14)
        uniswapRouter.setRate(address(usdc), address(uniswapRouter.WETH()), 5e14);

        // Mint tokens for user
        xcup.mint(user, 1000 * ONE_XCUP);
        vm.stopPrank();

        // User approves zap router
        vm.prank(user);
        xcup.approve(address(zapRouter), type(uint256).max);
    }

    function test_Initialize() public {
        assertEq(address(zapRouter.uniswapRouter()), address(uniswapRouter));
        assertEq(address(zapRouter.xcupPool()), address(xcupPool));
        assertEq(address(zapRouter.xcup()), address(xcup));
        assertEq(address(zapRouter.usdc()), address(usdc));
        assertEq(zapRouter.slippageTolerance(), 50); // 0.5%
    }

    function test_ZapXCUPToToken_Success() public {
        uint256 xcupAmount = 100 * ONE_XCUP;
        uint256 expectedUSDC = (xcupAmount * 9950) / 10000; // After 0.5% fee
        expectedUSDC = (expectedUSDC * 1000 * ONE_USDC) / (1000 * ONE_XCUP + expectedUSDC);
        uint256 expectedTokenOut = (expectedUSDC * 1e18) / 1e6; // USDC to TokenOut rate

        address[] memory path = new address[](2);
        path[0] = address(usdc);
        path[1] = address(tokenOut);

        uint256 userBalanceBefore = tokenOut.balanceOf(user);
        uint256 deadline = block.timestamp + 300;

        vm.prank(user);
        uint256 amountOut = zapRouter.zapXCUPToToken(
            xcupAmount,
            address(tokenOut),
            0, // minAmountOut
            path,
            deadline
        );

        uint256 userBalanceAfter = tokenOut.balanceOf(user);
        assertEq(userBalanceAfter - userBalanceBefore, amountOut);
        assertGt(amountOut, 0);
    }

    function test_ZapXCUPToToken_WithMinAmountOut() public {
        uint256 xcupAmount = 100 * ONE_XCUP;

        address[] memory path = new address[](2);
        path[0] = address(usdc);
        path[1] = address(tokenOut);

        // Get expected output
        (uint256 usdcAmount, uint256 tokenAmount) = zapRouter.getAmountsOut(xcupAmount, path);
        uint256 minAmountOut = (tokenAmount * 90) / 100; // 90% of expected

        uint256 deadline = block.timestamp + 300;

        vm.prank(user);
        uint256 amountOut = zapRouter.zapXCUPToToken(xcupAmount, address(tokenOut), minAmountOut, path, deadline);

        assertGe(amountOut, minAmountOut);
    }

    function test_ZapXCUPToToken_RevertInvalidPath() public {
        uint256 xcupAmount = 100 * ONE_XCUP;

        address[] memory path = new address[](2);
        path[0] = address(tokenOut); // Wrong: should start with USDC
        path[1] = address(usdc);

        uint256 deadline = block.timestamp + 300;

        vm.prank(user);
        vm.expectRevert(XCUPZapRouter.InvalidPath.selector);
        zapRouter.zapXCUPToToken(xcupAmount, address(tokenOut), 0, path, deadline);
    }

    function test_ZapXCUPToToken_RevertPathNotEndsWithTokenOut() public {
        uint256 xcupAmount = 100 * ONE_XCUP;

        address[] memory path = new address[](2);
        path[0] = address(usdc);
        path[1] = address(usdc); // Wrong: should end with tokenOut

        uint256 deadline = block.timestamp + 300;

        vm.prank(user);
        vm.expectRevert(XCUPZapRouter.InvalidPath.selector);
        zapRouter.zapXCUPToToken(xcupAmount, address(tokenOut), 0, path, deadline);
    }

    function test_ZapXCUPToETH_Success() public {
        uint256 xcupAmount = 100 * ONE_XCUP;
        uint256 deadline = block.timestamp + 300;

        uint256 userBalanceBefore = weth.balanceOf(user);

        // Mint WETH to router for swap
        weth.mint(address(uniswapRouter), 1000 * ONE_TOKEN);

        vm.prank(user);
        uint256 amountOut = zapRouter.zapXCUPToETH(
            xcupAmount,
            0, // minAmountOut
            deadline
        );

        uint256 userBalanceAfter = weth.balanceOf(user);
        assertEq(userBalanceAfter - userBalanceBefore, amountOut);
        assertGt(amountOut, 0);
    }

    function test_GetAmountsOut() public {
        uint256 xcupAmount = 100 * ONE_XCUP;

        (uint256 usdcAmount, uint256 tokenAmount) = zapRouter.getAmountsOut(xcupAmount, address(tokenOut));

        assertGt(usdcAmount, 0);
        assertGt(tokenAmount, 0);
    }

    function test_GetAmountsOutForToken() public {
        uint256 tokenAmount = 1000 * ONE_TOKEN;

        // Set rate for token -> USDC swap
        uniswapRouter.setRate(address(tokenOut), address(usdc), 1e18); // 1:1 rate

        (uint256 usdcAmount, uint256 xcupAmount) = zapRouter.getAmountsOutForToken(address(tokenOut), tokenAmount);

        assertGt(usdcAmount, 0);
        assertGt(xcupAmount, 0);
    }

    function test_GetAmountsOutForToken_ETH() public {
        uint256 ethAmount = 1 ether;

        // Set rate for WETH -> USDC swap
        uniswapRouter.setRate(uniswapRouter.WETH(), address(usdc), 2000 * 1e12); // 1 ETH = 2000 USDC

        (uint256 usdcAmount, uint256 xcupAmount) = zapRouter.getAmountsOutForToken(
            address(0), // ETH
            ethAmount
        );

        assertGt(usdcAmount, 0);
        assertGt(xcupAmount, 0);
    }

    function test_GetAmountsOutForToken_ZeroAmount() public {
        (uint256 usdcAmount, uint256 xcupAmount) = zapRouter.getAmountsOutForToken(address(tokenOut), 0);

        assertEq(usdcAmount, 0);
        assertEq(xcupAmount, 0);
    }

    function test_SetSlippageTolerance() public {
        vm.prank(owner);
        zapRouter.setSlippageTolerance(100); // 1%

        assertEq(zapRouter.slippageTolerance(), 100);
    }

    function test_SetSlippageTolerance_RevertTooHigh() public {
        vm.prank(owner);
        vm.expectRevert(XCUPZapRouter.SlippageTooHigh.selector);
        zapRouter.setSlippageTolerance(1001); // > 10%
    }

    function test_SetConfig() public {
        MockUniswapRouter newRouter = new MockUniswapRouter();
        MockXCUPPool newPool = new MockXCUPPool(address(xcup), address(usdc));
        ERC20Mock newXcup = new ERC20Mock("NewXCUP", "NXCUP", 6);
        ERC20Mock newUsdc = new ERC20Mock("NewUSDC", "NUSDC", 6);

        vm.prank(owner);
        zapRouter.setConfig(address(newRouter), address(newPool), address(newXcup), address(newUsdc));

        assertEq(address(zapRouter.uniswapRouter()), address(newRouter));
        assertEq(address(zapRouter.xcupPool()), address(newPool));
        assertEq(address(zapRouter.xcup()), address(newXcup));
        assertEq(address(zapRouter.usdc()), address(newUsdc));
    }

    function test_EmergencyWithdraw() public {
        // Send some tokens to router
        usdc.mint(address(zapRouter), 100 * ONE_USDC);
        tokenOut.mint(address(zapRouter), 100 * ONE_TOKEN);

        uint256 ownerUsdcBefore = usdc.balanceOf(owner);
        uint256 ownerTokenBefore = tokenOut.balanceOf(owner);

        vm.prank(owner);
        zapRouter.emergencyWithdraw(usdc);

        vm.prank(owner);
        zapRouter.emergencyWithdraw(tokenOut);

        assertEq(usdc.balanceOf(owner), ownerUsdcBefore + 100 * ONE_USDC);
        assertEq(tokenOut.balanceOf(owner), ownerTokenBefore + 100 * ONE_TOKEN);
    }

    function test_ZapXCUPToToken_MultiHopPath() public {
        ERC20Mock intermediateToken = new ERC20Mock("Intermediate", "INT", 18);
        intermediateToken.mint(address(uniswapRouter), 1000 * ONE_TOKEN);

        // Set rates: USDC -> Intermediate -> TokenOut
        uniswapRouter.setRate(address(usdc), address(intermediateToken), 1e18);
        uniswapRouter.setRate(address(intermediateToken), address(tokenOut), 1e18);

        uint256 xcupAmount = 100 * ONE_XCUP;

        address[] memory path = new address[](3);
        path[0] = address(usdc);
        path[1] = address(intermediateToken);
        path[2] = address(tokenOut);

        uint256 deadline = block.timestamp + 300;

        vm.prank(user);
        uint256 amountOut = zapRouter.zapXCUPToToken(xcupAmount, address(tokenOut), 0, path, deadline);

        assertGt(amountOut, 0);
        assertEq(tokenOut.balanceOf(user), amountOut);
    }

    function test_ZapXCUPToToken_RevertZeroAmount() public {
        address[] memory path = new address[](2);
        path[0] = address(usdc);
        path[1] = address(tokenOut);

        uint256 deadline = block.timestamp + 300;

        vm.prank(user);
        vm.expectRevert(XCUPZapRouter.InvalidAmount.selector);
        zapRouter.zapXCUPToToken(0, address(tokenOut), 0, path, deadline);
    }

    function test_ZapXCUPToToken_RevertShortPath() public {
        uint256 xcupAmount = 100 * ONE_XCUP;

        address[] memory path = new address[](1);
        path[0] = address(usdc);

        uint256 deadline = block.timestamp + 300;

        vm.prank(user);
        vm.expectRevert(XCUPZapRouter.InvalidPath.selector);
        zapRouter.zapXCUPToToken(xcupAmount, address(tokenOut), 0, path, deadline);
    }
}
