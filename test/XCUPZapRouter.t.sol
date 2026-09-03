// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC20Mock} from "../contracts/mock/ERC20Mock.sol";

import {XCUPZapRouter} from "../contracts/XCUPZapRouter.sol";
import {IUniswapRouterV2} from "../contracts/interfaces/IUniswapRouterV2.sol";
import {IXCUPRatePool} from "../contracts/interfaces/IXCUPRatePool.sol";

// Mock Uniswap Router
contract MockUniswapRouter is IUniswapRouterV2 {
    mapping(address => mapping(address => uint256)) public rates;
    bool public shouldRevert;
    address public WETH_ADDRESS; // Made non-constant so we can set it in tests

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

    function setWETHAddress(address _weth) external {
        WETH_ADDRESS = _weth;
    }

    function WETH() external pure returns (address) {
        // This will be mocked in tests using vm.mockCall
        return address(0);
    }
}

// Mock WETH with withdraw functionality
contract MockWETH is ERC20Mock {
    constructor() ERC20Mock("WETH", "WETH", 18) {}

    function deposit() external payable {
        _mint(msg.sender, msg.value);
    }

    function withdraw(uint256 amount) external {
        require(balanceOf(msg.sender) >= amount, "Insufficient balance");
        _burn(msg.sender, amount);
        (bool success, ) = payable(msg.sender).call{value: amount}("");
        require(success, "ETH transfer failed");
    }

    receive() external payable {
        _mint(msg.sender, msg.value);
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

    function swapExactUSDCToXCUP(uint256 usdcAmountIn, uint256 minXCUPOut) external {
        require(usdcAmountIn > 0, "Zero amount");

        (uint256 rX, uint256 rU) = this.getReserves();
        require(rX > 0 && rU > 0, "Empty reserves");

        // Simple constant product formula for testing
        uint256 amountInWithFee = (usdcAmountIn * (10000 - swapFee)) / 10000;
        uint256 xcupOut = (amountInWithFee * rX) / (rU + amountInWithFee);

        require(xcupOut >= minXCUPOut && xcupOut > 0, "Slippage");

        // Transfer tokens
        usdc.transferFrom(msg.sender, address(this), usdcAmountIn);
        xcup.transfer(msg.sender, xcupOut);

        // Update reserves
        reserves[address(usdc)] += usdcAmountIn;
        reserves[address(xcup)] -= xcupOut;
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
        weth = new MockWETH();

        // Deploy mock router
        uniswapRouter = new MockUniswapRouter();

        // Mock WETH() to return our mock WETH address
        vm.mockCall(
            address(uniswapRouter),
            abi.encodeWithSelector(IUniswapRouterV2.WETH.selector),
            abi.encode(address(weth))
        );

        // Deploy mock pool
        xcupPool = new MockXCUPPool(address(xcup), address(usdc));

        // Set up pool reserves (1000 XCUP : 1000 USDC = 1:1)
        xcup.mint(address(xcupPool), 1000 * ONE_XCUP);
        usdc.mint(address(xcupPool), 1000 * ONE_USDC);
        xcupPool.setReserves(1000 * ONE_XCUP, 1000 * ONE_USDC);

        // Deploy zap router
        XCUPZapRouter impl = new XCUPZapRouter();
        bytes memory initData = abi.encodeWithSelector(
            XCUPZapRouter.initialize.selector,
            address(uniswapRouter),
            address(xcupPool),
            address(xcup),
            address(usdc)
        );
        ERC1967Proxy proxy = new ERC1967Proxy(address(impl), initData);
        zapRouter = XCUPZapRouter(payable(address(proxy)));

        // Set up Uniswap rates
        // USDC -> TokenOut: 1 USDC = 1 TokenOut (1e6 -> 1e18, so rate = 1e18)
        uniswapRouter.setRate(address(usdc), address(tokenOut), 1e18);
        // USDC -> WETH: 1 USDC = 0.0005 WETH (1e6 -> 0.0005e18, so rate = 5e14)
        uniswapRouter.setRate(address(usdc), address(weth), 5e14);

        // Mint tokens for user
        xcup.mint(user, 1000 * ONE_XCUP);

        // Mint tokens to router for swaps (router needs output tokens)
        tokenOut.mint(address(uniswapRouter), 10000 * ONE_TOKEN);
        weth.mint(address(uniswapRouter), 10000 * ONE_TOKEN);
        usdc.mint(address(uniswapRouter), 10000 * ONE_USDC);

        vm.stopPrank();

        // XCUPZapRouter calls IXCUPPriceView methods on the xcup address.
        // xcup is ERC20Mock in tests → we mock both price-view calls.
        // Partial-match: only the selector is provided, Foundry matches any call with that selector.
        vm.mockCall(
            address(xcup),
            abi.encodeWithSelector(bytes4(keccak256("getXcupPriceInToken(address,uint256)"))),
            abi.encode(uint256(100 * ONE_USDC))
        );
        vm.mockCall(
            address(xcup),
            abi.encodeWithSelector(bytes4(keccak256("getTokenToXcupExchangeRate(address,uint256)"))),
            abi.encode(uint256(100 * ONE_XCUP))
        );

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

        // Mint tokens to router for swap output
        tokenOut.mint(address(uniswapRouter), 1000 * ONE_TOKEN);

        uint256 userBalanceBefore = tokenOut.balanceOf(user);
        uint256 deadline = block.timestamp + 300;

        vm.prank(user);
        uint256 amountOut = zapRouter.zapXCUPToToken(
            xcupAmount,
            address(tokenOut),
            0, // minAmountOut
            deadline
        );

        uint256 userBalanceAfter = tokenOut.balanceOf(user);
        assertEq(userBalanceAfter - userBalanceBefore, amountOut);
        assertGt(amountOut, 0);
    }

    function test_ZapXCUPToToken_WithMinAmountOut() public {
        uint256 xcupAmount = 100 * ONE_XCUP;

        // Mint tokens to router for swap output
        tokenOut.mint(address(uniswapRouter), 1000 * ONE_TOKEN);

        // Get expected output
        (uint256 usdcAmount, uint256 tokenAmount) = zapRouter.getAmountsOut(xcupAmount, address(tokenOut));
        uint256 minAmountOut = (tokenAmount * 90) / 100; // 90% of expected

        uint256 deadline = block.timestamp + 300;

        vm.prank(user);
        uint256 amountOut = zapRouter.zapXCUPToToken(xcupAmount, address(tokenOut), minAmountOut, deadline);

        assertGe(amountOut, minAmountOut);
    }

    function test_ZapXCUPToToken_RevertInvalidPath() public {
        // Path validation removed - test with invalid token instead
        uint256 xcupAmount = 100 * ONE_XCUP;
        uint256 deadline = block.timestamp + 300;

        vm.prank(user);
        vm.expectRevert(); // Should revert for invalid token
        zapRouter.zapXCUPToToken(xcupAmount, address(0xDEAD), 0, deadline);
    }

    function test_ZapXCUPToToken_RevertInvalidToken() public {
        uint256 xcupAmount = 100 * ONE_XCUP;
        uint256 deadline = block.timestamp + 300;

        vm.prank(user);
        vm.expectRevert(); // Should revert for invalid token
        zapRouter.zapXCUPToToken(xcupAmount, address(0xDEAD), 0, deadline);
    }

    function test_ZapXCUPToETH_Success() public {
        uint256 xcupAmount = 100 * ONE_XCUP;
        uint256 deadline = block.timestamp + 300;

        uint256 userBalanceBefore = user.balance;

        // WETH is already minted to router in setUp
        // Fund WETH contract with ETH for withdraw
        vm.deal(address(weth), 1000 ether);

        vm.prank(user);
        uint256 amountOut = zapRouter.zapXCUPToToken(
            xcupAmount,
            address(0), // ETH
            0, // minAmountOut
            deadline
        );

        uint256 userBalanceAfter = user.balance;
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
        tokenOut.mint(address(uniswapRouter), 1000 * ONE_TOKEN);

        // Set rates: USDC -> Intermediate -> TokenOut
        uniswapRouter.setRate(address(usdc), address(intermediateToken), 1e18);
        uniswapRouter.setRate(address(intermediateToken), address(tokenOut), 1e18);

        uint256 xcupAmount = 100 * ONE_XCUP;
        uint256 deadline = block.timestamp + 300;

        vm.prank(user);
        uint256 amountOut = zapRouter.zapXCUPToToken(xcupAmount, address(tokenOut), 0, deadline);

        assertGt(amountOut, 0);
        assertEq(tokenOut.balanceOf(user), amountOut);
    }

    function test_ZapXCUPToToken_RevertZeroAmount() public {
        uint256 deadline = block.timestamp + 300;

        vm.prank(user);
        vm.expectRevert(XCUPZapRouter.InvalidAmount.selector);
        zapRouter.zapXCUPToToken(0, address(tokenOut), 0, deadline);
    }

    function test_ZapXCUPToUSDC_Direct() public {
        uint256 xcupAmount = 100 * ONE_XCUP;
        uint256 deadline = block.timestamp + 300;

        uint256 userUSDCBefore = usdc.balanceOf(user);

        vm.prank(user);
        uint256 amountOut = zapRouter.zapXCUPToToken(
            xcupAmount,
            address(usdc), // Direct USDC swap
            0, // minAmountOut
            deadline
        );

        uint256 userUSDCAfter = usdc.balanceOf(user);
        assertEq(userUSDCAfter - userUSDCBefore, amountOut);
        assertGt(amountOut, 0);
    }

    function test_ZapXCUPToToken_InsufficientOutput() public {
        uint256 xcupAmount = 100 * ONE_XCUP;
        uint256 deadline = block.timestamp + 300;

        // Set very high minAmountOut that can't be reached
        // This will fail at Uniswap swap level, not at our contract level
        uint256 minAmountOut = 1000000 * ONE_TOKEN;

        vm.prank(user);
        // Will revert from Uniswap router, not our contract
        vm.expectRevert();
        zapRouter.zapXCUPToToken(xcupAmount, address(tokenOut), minAmountOut, deadline);
    }

    function test_ZapTokenToXCUP_USDC() public {
        uint256 usdcAmount = 100 * ONE_USDC;
        uint256 deadline = block.timestamp + 300;

        // Mint USDC to user
        usdc.mint(user, usdcAmount);
        vm.prank(user);
        usdc.approve(address(zapRouter), usdcAmount);

        uint256 userXCUPBefore = xcup.balanceOf(user);

        vm.prank(user);
        uint256 amountOut = zapRouter.zapTokenToXCUP(
            address(usdc), // Direct USDC swap
            usdcAmount,
            0, // minAmountOut
            deadline
        );

        uint256 userXCUPAfter = xcup.balanceOf(user);
        assertEq(userXCUPAfter - userXCUPBefore, amountOut);
        assertGt(amountOut, 0);
    }

    function test_ZapTokenToXCUP_Token() public {
        uint256 tokenAmount = 10 * ONE_TOKEN;
        uint256 deadline = block.timestamp + 300;

        // Mint tokens to user
        tokenOut.mint(user, tokenAmount);

        // Calculate expected USDC output from swap
        address[] memory path = new address[](2);
        path[0] = address(tokenOut);
        path[1] = address(usdc);
        uint256[] memory amountsOut = uniswapRouter.getAmountsOut(tokenAmount, path);
        uint256 expectedUSDC = amountsOut[amountsOut.length - 1];

        // Mint USDC to router - router needs to have USDC to transfer to zapRouter after swap
        usdc.mint(address(uniswapRouter), expectedUSDC * 2); // Extra buffer

        // Pool needs xCUP to give out
        xcup.mint(address(xcupPool), 10000000 * ONE_XCUP);
        usdc.mint(address(xcupPool), 10000000 * ONE_USDC);
        xcupPool.setReserves(10000000 * ONE_XCUP, 10000000 * ONE_USDC);

        vm.prank(user);
        tokenOut.approve(address(zapRouter), tokenAmount);

        uint256 userXCUPBefore = xcup.balanceOf(user);

        vm.prank(user);
        uint256 amountOut = zapRouter.zapTokenToXCUP(
            address(tokenOut),
            tokenAmount,
            0, // minAmountOut
            deadline
        );

        uint256 userXCUPAfter = xcup.balanceOf(user);
        assertEq(userXCUPAfter - userXCUPBefore, amountOut);
        assertGt(amountOut, 0);
    }

    function test_ZapTokenToXCUP_ETH() public {
        uint256 ethAmount = 0.001 ether;
        uint256 deadline = block.timestamp + 300;

        // Calculate expected USDC output from WETH swap
        address[] memory path = new address[](2);
        path[0] = address(weth);
        path[1] = address(usdc);
        uint256[] memory amountsOut = uniswapRouter.getAmountsOut(ethAmount, path);
        uint256 expectedUSDC = amountsOut[amountsOut.length - 1];

        // Mint USDC to router - router needs to have USDC to transfer to zapRouter after swap
        usdc.mint(address(uniswapRouter), expectedUSDC * 2); // Extra buffer

        // Pool needs xCUP to give out
        xcup.mint(address(xcupPool), 10000000 * ONE_XCUP);
        usdc.mint(address(xcupPool), 10000000 * ONE_USDC);
        xcupPool.setReserves(10000000 * ONE_XCUP, 10000000 * ONE_USDC);

        // Fund WETH with ETH
        vm.deal(address(weth), 100 ether);
        vm.deal(user, ethAmount);

        uint256 userXCUPBefore = xcup.balanceOf(user);

        vm.prank(user);
        uint256 amountOut = zapRouter.zapTokenToXCUP{value: ethAmount}(
            address(0), // ETH
            ethAmount,
            0, // minAmountOut
            deadline
        );

        uint256 userXCUPAfter = xcup.balanceOf(user);
        assertEq(userXCUPAfter - userXCUPBefore, amountOut);
        assertGt(amountOut, 0);
    }

    function test_ZapTokenToXCUP_ZeroAmount() public {
        uint256 deadline = block.timestamp + 300;

        vm.prank(user);
        vm.expectRevert(XCUPZapRouter.InvalidAmount.selector);
        zapRouter.zapTokenToXCUP(address(tokenOut), 0, 0, deadline);
    }

    function test_ZapTokenToXCUP_ETH_InvalidAmount() public {
        uint256 deadline = block.timestamp + 300;

        vm.deal(user, 1 ether);

        vm.prank(user);
        vm.expectRevert(XCUPZapRouter.InvalidAmount.selector);
        zapRouter.zapTokenToXCUP{value: 0.5 ether}(address(0), 1 ether, 0, deadline);
    }

    function test_GetAmountsIn() public {
        uint256 xcupAmountOut = 100 * ONE_XCUP;

        (uint256 tokenAmount, uint256 usdcAmount) = zapRouter.getAmountsIn(xcupAmountOut, address(tokenOut));

        assertGt(tokenAmount, 0);
        assertGt(usdcAmount, 0);
    }

    function test_GetAmountsIn_ETH() public {
        uint256 xcupAmountOut = 100 * ONE_XCUP;

        (uint256 tokenAmount, uint256 usdcAmount) = zapRouter.getAmountsIn(xcupAmountOut, address(0));

        assertGt(tokenAmount, 0);
        assertGt(usdcAmount, 0);
    }

    function test_GetAmountsIn_USDC() public {
        uint256 xcupAmountOut = 100 * ONE_XCUP;

        (uint256 tokenAmount, uint256 usdcAmount) = zapRouter.getAmountsIn(xcupAmountOut, address(usdc));

        assertGt(tokenAmount, 0);
        assertGt(usdcAmount, 0);
    }

    function test_GetAmountsOut_USDC() public {
        uint256 xcupAmount = 100 * ONE_XCUP;

        (uint256 usdcAmount, uint256 tokenAmount) = zapRouter.getAmountsOut(xcupAmount, address(usdc));

        assertGt(usdcAmount, 0);
        assertEq(tokenAmount, usdcAmount); // For USDC output, tokenAmount = usdcAmount
    }

    function test_GetAmountsOut_ETH() public {
        uint256 xcupAmount = 100 * ONE_XCUP;

        (uint256 usdcAmount, uint256 tokenAmount) = zapRouter.getAmountsOut(xcupAmount, address(0));

        assertGt(usdcAmount, 0);
        assertGt(tokenAmount, 0);
    }

    function test_GetAmountsOut_ZeroReserves() public {
        // Create new pool with zero reserves
        MockXCUPPool emptyPool = new MockXCUPPool(address(xcup), address(usdc));

        XCUPZapRouter newImpl = new XCUPZapRouter();
        bytes memory initData = abi.encodeWithSelector(
            XCUPZapRouter.initialize.selector,
            address(uniswapRouter),
            address(emptyPool),
            address(xcup),
            address(usdc)
        );
        ERC1967Proxy newProxy = new ERC1967Proxy(address(newImpl), initData);
        XCUPZapRouter newRouter = XCUPZapRouter(payable(address(newProxy)));

        (uint256 usdcAmount, uint256 tokenAmount) = newRouter.getAmountsOut(100 * ONE_XCUP, address(tokenOut));

        assertEq(usdcAmount, 0);
        assertEq(tokenAmount, 0);
    }

    function test_SetConfig_InvalidAddress() public {
        vm.prank(owner);
        vm.expectRevert(XCUPZapRouter.InvalidAddress.selector);
        zapRouter.setConfig(address(0), address(xcupPool), address(xcup), address(usdc));
    }

    function test_Initialize_InvalidAddress() public {
        XCUPZapRouter impl = new XCUPZapRouter();
        bytes memory initData = abi.encodeWithSelector(
            XCUPZapRouter.initialize.selector,
            address(0), // Invalid
            address(xcupPool),
            address(xcup),
            address(usdc)
        );
        vm.expectRevert();
        new ERC1967Proxy(address(impl), initData);
    }

    function test_EmergencyWithdrawETH() public {
        vm.deal(address(zapRouter), 1 ether);
        uint256 ownerBefore = owner.balance;

        vm.prank(owner);
        zapRouter.emergencyWithdrawETH();

        assertEq(owner.balance - ownerBefore, 1 ether);
    }

    function test_EmergencyWithdraw_ZeroBalance() public {
        vm.prank(owner);
        // Should not revert, just do nothing
        zapRouter.emergencyWithdraw(usdc);
    }

    function test_EmergencyWithdrawETH_ZeroBalance() public {
        vm.prank(owner);
        // Should not revert, just do nothing
        zapRouter.emergencyWithdrawETH();
    }

    function test_ZapTokenToXCUP_InsufficientOutput() public {
        uint256 usdcAmount = 100 * ONE_USDC;
        uint256 deadline = block.timestamp + 300;

        usdc.mint(user, usdcAmount);
        vm.prank(user);
        usdc.approve(address(zapRouter), usdcAmount);

        // Set very high minAmountOut
        uint256 minAmountOut = 1000000 * ONE_XCUP;

        vm.prank(user);
        vm.expectRevert(XCUPZapRouter.InsufficientOutput.selector);
        zapRouter.zapTokenToXCUP(address(usdc), usdcAmount, minAmountOut, deadline);
    }

    function test_ZapXCUPToUSDC_InsufficientOutput() public {
        uint256 xcupAmount = 100 * ONE_XCUP;
        uint256 deadline = block.timestamp + 300;

        // Set very high minAmountOut
        uint256 minAmountOut = 1000000 * ONE_USDC;

        vm.prank(user);
        vm.expectRevert(XCUPZapRouter.InsufficientOutput.selector);
        zapRouter.zapXCUPToToken(xcupAmount, address(usdc), minAmountOut, deadline);
    }
}
