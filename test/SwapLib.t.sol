// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test, console} from "forge-std/Test.sol";
import {SwapLib} from "../contracts/libraries/SwapLib.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IUniswapV2Router02} from "@uniswap/v2-periphery/contracts/interfaces/IUniswapV2Router02.sol";

// Mock contracts for testing
contract MockUSDC {
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function decimals() external pure returns (uint8) {
        return 6;
    }

    function totalSupply() external pure returns (uint256) {
        return 0;
    }

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        require(balanceOf[from] >= amount, "Insufficient balance");
        require(allowance[from][msg.sender] >= amount, "Insufficient allowance");

        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        allowance[from][msg.sender] -= amount;

        return true;
    }
}

contract MockToken {
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function decimals() external pure returns (uint8) {
        return 18;
    }

    function totalSupply() external pure returns (uint256) {
        return 0;
    }

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        require(balanceOf[from] >= amount, "Insufficient balance");
        require(allowance[from][msg.sender] >= amount, "Insufficient allowance");

        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        allowance[from][msg.sender] -= amount;

        return true;
    }
}

contract MockUniswapRouter is IUniswapV2Router02 {
    function removeLiquidityETHSupportingFeeOnTransferTokens(
        address token,
        uint256 liquidity,
        uint256 amountTokenMin,
        uint256 amountETHMin,
        address to,
        uint256 deadline
    ) external pure override returns (uint256 amountETH) {
        revert("Not implemented");
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
    ) external pure override returns (uint256 amountETH) {
        revert("Not implemented");
    }
    address public constant WETH_ADDRESS = address(0x1234567890123456789012345678901234567890);
    MockUSDC public usdc;

    constructor(MockUSDC _usdc) {
        usdc = _usdc;
    }

    function WETH() external pure override returns (address) {
        return WETH_ADDRESS;
    }

    function getAmountsOut(
        uint256 amountIn,
        address[] calldata path
    ) external pure override returns (uint256[] memory amounts) {
        amounts = new uint256[](2);
        amounts[0] = amountIn;
        // 1:1 swap for testing
        amounts[1] = amountIn;
    }

    function swapExactETHForTokens(
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external payable override returns (uint256[] memory amounts) {
        // Mock: transfer USDC to recipient
        usdc.mint(to, msg.value);
        amounts = new uint256[](2);
        amounts[0] = msg.value;
        amounts[1] = msg.value;
    }

    function swapExactTokensForTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external override returns (uint256[] memory amounts) {
        // Mock: transfer USDC to recipient
        usdc.mint(to, amountIn);
        amounts = new uint256[](2);
        amounts[0] = amountIn;
        amounts[1] = amountIn;
    }

    // Stub implementations for interface
    function factory() external pure override returns (address) {
        return address(0);
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
    ) external pure override returns (uint256 amountA, uint256 amountB, uint256 liquidity) {
        revert("Not implemented");
    }

    function addLiquidityETH(
        address token,
        uint256 amountTokenDesired,
        uint256 amountTokenMin,
        uint256 amountETHMin,
        address to,
        uint256 deadline
    ) external payable override returns (uint256 amountToken, uint256 amountETH, uint256 liquidity) {
        revert("Not implemented");
    }

    function removeLiquidity(
        address tokenA,
        address tokenB,
        uint256 liquidity,
        uint256 amountAMin,
        uint256 amountBMin,
        address to,
        uint256 deadline
    ) external pure override returns (uint256 amountA, uint256 amountB) {
        revert("Not implemented");
    }

    function removeLiquidityETH(
        address token,
        uint256 liquidity,
        uint256 amountTokenMin,
        uint256 amountETHMin,
        address to,
        uint256 deadline
    ) external pure override returns (uint256 amountToken, uint256 amountETH) {
        revert("Not implemented");
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
    ) external pure override returns (uint256 amountA, uint256 amountB) {
        revert("Not implemented");
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
    ) external pure override returns (uint256 amountToken, uint256 amountETH) {
        revert("Not implemented");
    }

    function swapExactTokensForETH(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external pure override returns (uint256[] memory amounts) {
        revert("Not implemented");
    }

    function swapETHForExactTokens(
        uint256 amountOut,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external payable override returns (uint256[] memory amounts) {
        revert("Not implemented");
    }

    function swapTokensForExactTokens(
        uint256 amountOut,
        uint256 amountInMax,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external pure override returns (uint256[] memory amounts) {
        revert("Not implemented");
    }

    function swapTokensForExactETH(
        uint256 amountOut,
        uint256 amountInMax,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external pure override returns (uint256[] memory amounts) {
        revert("Not implemented");
    }

    function swapExactTokensForETHSupportingFeeOnTransferTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external pure override {
        revert("Not implemented");
    }

    function swapExactETHForTokensSupportingFeeOnTransferTokens(
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external payable override {
        revert("Not implemented");
    }

    function swapExactTokensForTokensSupportingFeeOnTransferTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external pure override {
        revert("Not implemented");
    }

    function quote(
        uint256 amountA,
        uint256 reserveA,
        uint256 reserveB
    ) external pure override returns (uint256 amountB) {
        revert("Not implemented");
    }

    function getAmountsIn(
        uint256 amountOut,
        address[] calldata path
    ) external pure override returns (uint256[] memory amounts) {
        revert("Not implemented");
    }

    function getAmountOut(
        uint amountIn,
        uint reserveIn,
        uint reserveOut
    ) external pure override returns (uint amountOut) {
        revert("Not implemented");
    }

    function getAmountIn(
        uint amountOut,
        uint reserveIn,
        uint reserveOut
    ) external pure override returns (uint amountIn) {
        revert("Not implemented");
    }
}

/**
 * @title TestContract
 * @notice Test contract that uses SwapLib to test library functions
 */
contract TestContract {
    using SwapLib for IERC20;

    MockUSDC public usdc;
    MockUniswapRouter public router;
    address public silo;

    constructor(MockUSDC _usdc, MockUniswapRouter _router, address _silo) {
        usdc = _usdc;
        router = _router;
        silo = _silo;
    }

    function zapIn(
        IERC20 tokenIn,
        uint256 amount,
        uint256 slippageBps,
        address msgSender,
        uint256 msgValue
    ) external payable returns (uint256) {
        return
            SwapLib.zapIn(
                tokenIn,
                amount,
                slippageBps,
                router,
                IERC20(address(usdc)),
                silo,
                address(this),
                msgSender,
                msgValue
            );
    }

    function tradeForToken(
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 slippageBps,
        uint256 msgValue
    ) external payable {
        SwapLib.tradeForToken(tokenIn, tokenOut, amountIn, slippageBps, router, silo, address(this), msgValue);
    }
}

contract SwapLibTest is Test {
    TestContract public testContract;
    MockUSDC public usdc;
    MockUniswapRouter public router;
    MockToken public token;
    address public silo;
    address public user1;

    function setUp() public {
        usdc = new MockUSDC();
        router = new MockUniswapRouter(usdc);
        token = new MockToken();
        silo = makeAddr("silo");
        user1 = makeAddr("user1");

        testContract = new TestContract(usdc, router, silo);

        // Mint initial USDC to silo
        usdc.mint(silo, 1000000 * 10 ** 6);
    }

    // ───────────────────────────── ZAP IN TESTS ─────────────────────────────

    function testZapInERC20() public {
        uint256 amount = 1000 * 10 ** 18;
        uint256 slippageBps = 100; // 1%

        // Mint tokens to user
        token.mint(user1, amount);

        // Approve test contract to spend tokens
        vm.startPrank(user1);
        token.approve(address(testContract), amount);

        uint256 initialSiloBalance = usdc.balanceOf(silo);
        uint256 depositValue = testContract.zapIn(IERC20(address(token)), amount, slippageBps, user1, 0);
        vm.stopPrank();

        uint256 finalSiloBalance = usdc.balanceOf(silo);
        assertEq(depositValue, finalSiloBalance - initialSiloBalance);
        assertTrue(depositValue > 0);
    }

    function testZapInETH() public {
        uint256 amount = 1 ether;
        uint256 slippageBps = 100; // 1%

        uint256 initialSiloBalance = usdc.balanceOf(silo);
        uint256 depositValue = testContract.zapIn{value: amount}(
            IERC20(address(0)),
            amount,
            slippageBps,
            address(this),
            amount
        );
        uint256 finalSiloBalance = usdc.balanceOf(silo);

        assertEq(depositValue, finalSiloBalance - initialSiloBalance);
        assertTrue(depositValue > 0);
    }

    function testZapInETHInvalidAmount() public {
        uint256 amount = 1 ether;
        uint256 slippageBps = 100;

        vm.expectRevert(SwapLib.InvalidETHAmount.selector);
        testContract.zapIn{value: 0.5 ether}(IERC20(address(0)), amount, slippageBps, address(this), 0.5 ether);
    }

    function testZapInWithDifferentSlippage() public {
        uint256 amount = 1000 * 10 ** 18;

        token.mint(user1, amount);

        vm.startPrank(user1);
        token.approve(address(testContract), amount);

        // Test with 0.5% slippage
        uint256 depositValue1 = testContract.zapIn(IERC20(address(token)), amount, 50, user1, 0);

        // Test with 5% slippage
        token.mint(user1, amount);
        token.approve(address(testContract), amount);
        uint256 depositValue2 = testContract.zapIn(IERC20(address(token)), amount, 500, user1, 0);
        vm.stopPrank();

        // Both should work (mock returns same amount)
        assertTrue(depositValue1 > 0);
        assertTrue(depositValue2 > 0);
    }

    // ───────────────────────────── TRADE FOR TOKEN TESTS ─────────────────────────────

    function testTradeForTokenERC20() public {
        uint256 amountIn = 1000 * 10 ** 18;
        uint256 slippageBps = 100;

        // Mint tokens to test contract
        token.mint(address(testContract), amountIn);
        token.approve(address(router), amountIn);

        uint256 initialSiloBalance = usdc.balanceOf(silo);
        testContract.tradeForToken(address(token), address(usdc), amountIn, slippageBps, 0);
        uint256 finalSiloBalance = usdc.balanceOf(silo);

        assertTrue(finalSiloBalance > initialSiloBalance);
    }

    function testTradeForTokenETH() public {
        uint256 amountIn = 1 ether;
        uint256 slippageBps = 100;

        uint256 initialSiloBalance = usdc.balanceOf(silo);
        testContract.tradeForToken{value: amountIn}(address(0), address(usdc), amountIn, slippageBps, amountIn);
        uint256 finalSiloBalance = usdc.balanceOf(silo);

        assertTrue(finalSiloBalance > initialSiloBalance);
    }

    function testTradeForTokenWETH() public {
        uint256 amountIn = 1 ether;
        uint256 slippageBps = 100;

        uint256 initialSiloBalance = usdc.balanceOf(silo);
        testContract.tradeForToken{value: amountIn}(router.WETH(), address(usdc), amountIn, slippageBps, amountIn);
        uint256 finalSiloBalance = usdc.balanceOf(silo);

        assertTrue(finalSiloBalance > initialSiloBalance);
    }
}
