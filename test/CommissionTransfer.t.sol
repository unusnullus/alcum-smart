// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test, console} from "forge-std/Test.sol";
import {CommissionTransfer} from "../contracts/CommissionTransfer.sol";
import {XCUPOraclePool} from "../contracts/XCUPOraclePool.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Permit.sol";
import {ERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IUniswapRouterV2} from "../contracts/interfaces/IUniswapRouterV2.sol";
import {IXCUPPriceView} from "../contracts/interfaces/IXCUPPriceView.sol";

// Mock tokens
contract MockERC20 is ERC20 {
    constructor(string memory name, string memory symbol, uint8 decimals_) ERC20(name, symbol) {
        _mint(msg.sender, 1000000 * 10 ** decimals_);
    }

    function decimals() public pure override returns (uint8) {
        return 6;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract MockERC20Permit is ERC20Permit {
    constructor() ERC20("MockPermit", "MP") ERC20Permit("MockPermit") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

// Mock xCUP with price view
contract MockXCUP is ERC20, IXCUPPriceView {
    uint256 public constant PRICE_MULTIPLIER = 1_000_000; // 1 xCUP = 1 USDC (6 decimals each)
    IERC20 public usdc;

    constructor(address _usdc) ERC20("xCUP", "XCUP") {
        usdc = IERC20(_usdc);
        _mint(msg.sender, 1000000 * 10 ** 6);
    }

    function decimals() public pure override returns (uint8) {
        return 6;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function getXcupPriceInToken(address token, uint256 xcupAmount) external view override returns (uint256) {
        require(token == address(usdc), "Only USDC supported");
        // 1 xCUP = 1 USDC
        return xcupAmount;
    }

    function getTokenToXcupExchangeRate(address token, uint256 tokenAmount) external view override returns (uint256) {
        require(token == address(usdc), "Only USDC supported");
        // 1 USDC = 1 xCUP
        return tokenAmount;
    }
}

// Mock Uniswap Router
contract MockUniswapRouter is IUniswapRouterV2 {
    mapping(address => mapping(address => uint256)) public rates;
    address public constant WETH_ADDRESS = address(0x1234);

    function setRate(address tokenIn, address tokenOut, uint256 rate) external {
        rates[tokenIn][tokenOut] = rate;
    }

    function WETH() external pure returns (address) {
        return WETH_ADDRESS;
    }

    function getAmountsOut(uint256 amountIn, address[] calldata path) external view returns (uint256[] memory amounts) {
        amounts = new uint256[](path.length);
        amounts[0] = amountIn;
        for (uint256 i = 1; i < path.length; i++) {
            uint256 rate = rates[path[i - 1]][path[i]];
            if (rate == 0) rate = 1e18; // Default 1:1
            amounts[i] = (amounts[i - 1] * rate) / 1e18;
        }
    }

    // Stub implementations
    function factory() external pure returns (address) {
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
    ) external pure returns (uint256 amountA, uint256 amountB, uint256 liquidity) {
        revert("Not implemented");
    }

    function addLiquidityETH(
        address token,
        uint256 amountTokenDesired,
        uint256 amountTokenMin,
        uint256 amountETHMin,
        address to,
        uint256 deadline
    ) external payable returns (uint256 amountToken, uint256 amountETH, uint256 liquidity) {
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
    ) external pure returns (uint256 amountA, uint256 amountB) {
        revert("Not implemented");
    }

    function removeLiquidityETH(
        address token,
        uint256 liquidity,
        uint256 amountTokenMin,
        uint256 amountETHMin,
        address to,
        uint256 deadline
    ) external pure returns (uint256 amountToken, uint256 amountETH) {
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
    ) external pure returns (uint256 amountA, uint256 amountB) {
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
    ) external pure returns (uint256 amountToken, uint256 amountETH) {
        revert("Not implemented");
    }

    function swapExactTokensForTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external pure returns (uint256[] memory amounts) {
        revert("Not implemented");
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
    ) external pure returns (uint256[] memory amounts) {
        revert("Not implemented");
    }

    function swapTokensForExactETH(
        uint256 amountOut,
        uint256 amountInMax,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external pure returns (uint256[] memory amounts) {
        revert("Not implemented");
    }

    function swapExactTokensForETH(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external pure returns (uint256[] memory amounts) {
        revert("Not implemented");
    }

    function swapETHForExactTokens(
        uint256 amountOut,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external payable returns (uint256[] memory amounts) {
        revert("Not implemented");
    }

    function swapExactTokensForETHSupportingFeeOnTransferTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external pure {
        revert("Not implemented");
    }

    function swapExactETHForTokensSupportingFeeOnTransferTokens(
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external payable {
        revert("Not implemented");
    }

    function swapExactTokensForTokensSupportingFeeOnTransferTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external {
        uint256 amountOut = (amountIn * rates[path[0]][path[1]]) / 1e18;
        require(amountOut >= amountOutMin, "Insufficient output");
        // Mint tokens to this contract first, then transfer
        IERC20 outToken = IERC20(path[1]);
        // For testing, we'll mint tokens if needed
        if (outToken.balanceOf(address(this)) < amountOut) {
            // In real scenario, router would have tokens from swap
            // For mock, we assume tokens are available
        }
        outToken.transfer(to, amountOut);
    }

    function quote(uint256 amountA, uint256 reserveA, uint256 reserveB) external pure returns (uint256 amountB) {
        revert("Not implemented");
    }

    function getAmountsIn(uint256 amountOut, address[] calldata path) external pure returns (uint256[] memory amounts) {
        revert("Not implemented");
    }

    function getAmountOut(uint amountIn, uint reserveIn, uint reserveOut) external pure returns (uint amountOut) {
        revert("Not implemented");
    }

    function getAmountIn(uint amountOut, uint reserveIn, uint reserveOut) external pure returns (uint amountIn) {
        revert("Not implemented");
    }

    function removeLiquidityETHSupportingFeeOnTransferTokens(
        address token,
        uint256 liquidity,
        uint256 amountTokenMin,
        uint256 amountETHMin,
        address to,
        uint256 deadline
    ) external pure returns (uint256 amountETH) {
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
    ) external pure returns (uint256 amountETH) {
        revert("Not implemented");
    }
}

contract CommissionTransferTest is Test {
    CommissionTransfer public commissionTransfer;
    XCUPOraclePool public xcupPool;
    MockUniswapRouter public uniswapRouter;
    MockERC20 public usdt;
    MockXCUP public xcup;
    MockERC20 public usdc;
    MockERC20 public otherToken;
    MockERC20Permit public permitToken;

    address public owner;
    address public commissionReceiver;
    address public user;
    address public recipient;

    uint256 constant ONE_USDC = 1e6;
    uint256 constant ONE_XCUP = 1e6;
    uint256 constant ONE_USDT = 1e6;

    function setUp() public {
        owner = makeAddr("owner");
        commissionReceiver = makeAddr("commissionReceiver");
        user = makeAddr("user");
        recipient = makeAddr("recipient");

        vm.startPrank(owner);

        // Deploy tokens
        usdc = new MockERC20("USDC", "USDC", 6);
        usdt = new MockERC20("USDT", "USDT", 6);
        xcup = new MockXCUP(address(usdc));
        otherToken = new MockERC20("Other", "OTHER", 18);
        permitToken = new MockERC20Permit();

        // Deploy Uniswap Router
        uniswapRouter = new MockUniswapRouter();
        uniswapRouter.setRate(address(usdt), address(usdc), 1e18); // 1:1 rate

        // Deploy XCUPOraclePool
        XCUPOraclePool poolImpl = new XCUPOraclePool();
        bytes memory poolInitData = abi.encodeWithSelector(
            XCUPOraclePool.initialize.selector,
            address(xcup),
            address(usdc)
        );
        ERC1967Proxy poolProxy = new ERC1967Proxy(address(poolImpl), poolInitData);
        xcupPool = XCUPOraclePool(address(poolProxy));

        // Add liquidity to pool
        xcup.mint(address(this), 10000 * ONE_XCUP);
        usdc.mint(address(this), 10000 * ONE_USDC);
        xcup.approve(address(xcupPool), 10000 * ONE_XCUP);
        usdc.approve(address(xcupPool), 10000 * ONE_USDC);
        xcupPool.addLiquidity(10000 * ONE_XCUP, 10000 * ONE_USDC);

        // Deploy CommissionTransfer
        CommissionTransfer impl = new CommissionTransfer();
        bytes memory initData = abi.encodeWithSelector(CommissionTransfer.initialize.selector, commissionReceiver);
        ERC1967Proxy proxy = new ERC1967Proxy(address(impl), initData);
        commissionTransfer = CommissionTransfer(payable(address(proxy)));

        // Set swap config
        commissionTransfer.setSwapConfig(address(uniswapRouter), address(usdt), address(xcup), address(usdc));

        // Set XCUP pool
        commissionTransfer.setXCUPPool(address(xcupPool));

        // Mint tokens to user
        usdt.mint(user, 10000 * ONE_USDT);
        xcup.mint(user, 10000 * ONE_XCUP);
        usdc.mint(user, 10000 * ONE_USDC);
        otherToken.mint(user, 10000 * 1e18);
        permitToken.mint(user, 10000 * 1e18);

        vm.stopPrank();
    }

    // ───────────────────────────── INITIALIZATION TESTS ─────────────────────────────

    function test_Initialize() public {
        assertEq(commissionTransfer.getCommissionReceiver(), commissionReceiver);
        assertEq(commissionTransfer.getCommissionPercentage(), 20); // 2.0%
        assertEq(commissionTransfer.getSlippageTolerance(), 50); // 0.5%
    }

    function test_InitializeInvalidAddress() public {
        CommissionTransfer impl = new CommissionTransfer();
        // Initialize with invalid address should revert during proxy deployment
        bytes memory initData = abi.encodeWithSelector(CommissionTransfer.initialize.selector, address(0));
        vm.expectRevert();
        new ERC1967Proxy(address(impl), initData);
    }

    // ───────────────────────────── ADMIN FUNCTIONS TESTS ─────────────────────────────

    function test_SetCommissionReceiver() public {
        address newReceiver = makeAddr("newReceiver");
        vm.prank(owner);
        commissionTransfer.setCommissionReceiver(newReceiver);
        assertEq(commissionTransfer.getCommissionReceiver(), newReceiver);
    }

    function test_SetCommissionReceiverInvalidAddress() public {
        vm.prank(owner);
        vm.expectRevert(CommissionTransfer.InvalidAddress.selector);
        commissionTransfer.setCommissionReceiver(address(0));
    }

    function test_SetCommissionPercentage() public {
        vm.prank(owner);
        commissionTransfer.setCommissionPercentage(50); // 5.0%
        assertEq(commissionTransfer.getCommissionPercentage(), 50);
    }

    function test_SetCommissionPercentageTooHigh() public {
        vm.prank(owner);
        vm.expectRevert(CommissionTransfer.InvalidAmount.selector);
        commissionTransfer.setCommissionPercentage(1001); // > 100%
    }

    function test_SetSwapConfig() public {
        MockUniswapRouter newRouter = new MockUniswapRouter();
        MockERC20 newUsdt = new MockERC20("NewUSDT", "NUSDT", 6);
        MockXCUP newXcup = new MockXCUP(address(usdc));
        MockERC20 newUsdc = new MockERC20("NewUSDC", "NUSDC", 6);

        vm.prank(owner);
        commissionTransfer.setSwapConfig(address(newRouter), address(newUsdt), address(newXcup), address(newUsdc));

        (address router, address usdtAddr, address xcupAddr, address usdcAddr) = commissionTransfer.getSwapConfig();
        assertEq(router, address(newRouter));
        assertEq(usdtAddr, address(newUsdt));
        assertEq(xcupAddr, address(newXcup));
        assertEq(usdcAddr, address(newUsdc));
    }

    function test_SetSwapConfigInvalidAddress() public {
        vm.prank(owner);
        vm.expectRevert(CommissionTransfer.InvalidAddress.selector);
        commissionTransfer.setSwapConfig(address(0), address(usdt), address(xcup), address(usdc));
    }

    function test_SetXCUPPool() public {
        XCUPOraclePool newPoolImpl = new XCUPOraclePool();
        bytes memory poolInitData = abi.encodeWithSelector(
            XCUPOraclePool.initialize.selector,
            address(xcup),
            address(usdc)
        );
        ERC1967Proxy newPoolProxy = new ERC1967Proxy(address(newPoolImpl), poolInitData);
        XCUPOraclePool newPool = XCUPOraclePool(address(newPoolProxy));

        vm.prank(owner);
        commissionTransfer.setXCUPPool(address(newPool));
    }

    function test_SetXCUPPoolInvalidAddress() public {
        vm.prank(owner);
        vm.expectRevert(CommissionTransfer.InvalidAddress.selector);
        commissionTransfer.setXCUPPool(address(0));
    }

    function test_SetSlippageTolerance() public {
        vm.prank(owner);
        commissionTransfer.setSlippageTolerance(100); // 1%
        assertEq(commissionTransfer.getSlippageTolerance(), 100);
    }

    function test_SetSlippageToleranceTooHigh() public {
        vm.prank(owner);
        vm.expectRevert(CommissionTransfer.InvalidAmount.selector);
        commissionTransfer.setSlippageTolerance(1001); // > 10%
    }

    // ───────────────────────────── ETH TRANSFER TESTS ─────────────────────────────

    function test_TransferETHWithCommission() public {
        uint256 amount = 1 ether;
        uint256 expectedCommission = (amount * 20) / 1000; // 2.0%
        uint256 expectedTransfer = amount - expectedCommission;

        uint256 receiverBefore = commissionReceiver.balance;
        uint256 recipientBefore = recipient.balance;

        commissionTransfer.transferETHWithCommission{value: amount}(payable(recipient));

        assertEq(commissionReceiver.balance - receiverBefore, expectedCommission);
        assertEq(recipient.balance - recipientBefore, expectedTransfer);
    }

    function test_TransferETHWithCommissionInvalidAddress() public {
        vm.expectRevert(CommissionTransfer.InvalidAddress.selector);
        commissionTransfer.transferETHWithCommission{value: 1 ether}(payable(address(0)));
    }

    function test_TransferETHWithCommissionZeroAmount() public {
        vm.expectRevert(CommissionTransfer.InvalidAmount.selector);
        commissionTransfer.transferETHWithCommission{value: 0}(payable(recipient));
    }

    function test_ReceiveReverts() public {
        vm.expectRevert(CommissionTransfer.UseTransferETHWithCommission.selector);
        address(commissionTransfer).call{value: 1 ether}("");
    }

    // ───────────────────────────── TOKEN TRANSFER TESTS ─────────────────────────────

    function test_TransferTokenWithCommission_USDC() public {
        uint256 amount = 1000 * ONE_USDC;
        uint256 expectedCommission = (amount * 20) / 1000; // 2.0%
        uint256 expectedTransfer = amount - expectedCommission;

        vm.startPrank(user);
        usdc.approve(address(commissionTransfer), amount);

        uint256 receiverBefore = usdc.balanceOf(commissionReceiver);
        uint256 recipientBefore = usdc.balanceOf(recipient);

        commissionTransfer.transferTokenWithCommission(usdc, recipient, amount);

        assertEq(usdc.balanceOf(commissionReceiver) - receiverBefore, expectedCommission);
        assertEq(usdc.balanceOf(recipient) - recipientBefore, expectedTransfer);
        vm.stopPrank();
    }

    function test_TransferTokenWithCommission_USDT() public {
        uint256 amount = 1000 * ONE_USDT;
        // Mint USDC to router for swap output
        usdc.mint(address(uniswapRouter), amount);

        // USDT will be swapped to USDC, then commission calculated on USDC
        uint256 usdcAmount = amount; // 1:1 swap rate
        uint256 expectedCommission = (usdcAmount * 20) / 1000; // 2.0%
        uint256 expectedTransfer = usdcAmount - expectedCommission;

        vm.startPrank(user);
        usdt.approve(address(commissionTransfer), amount);

        uint256 receiverBefore = usdc.balanceOf(commissionReceiver);
        uint256 recipientBefore = usdc.balanceOf(recipient);

        commissionTransfer.transferTokenWithCommission(usdt, recipient, amount);

        assertEq(usdc.balanceOf(commissionReceiver) - receiverBefore, expectedCommission);
        assertEq(usdc.balanceOf(recipient) - recipientBefore, expectedTransfer);
        vm.stopPrank();
    }

    function test_TransferTokenWithCommission_XCUP() public {
        uint256 amount = 1000 * ONE_XCUP;
        // xCUP will be swapped to USDC via pool, then commission calculated on USDC
        // With 1:1 price and 0.5% fee, output will be slightly less
        uint256 usdcAmount = (amount * 9950) / 10000; // After 0.5% fee
        uint256 expectedCommission = (usdcAmount * 20) / 1000; // 2.0%
        uint256 expectedTransfer = usdcAmount - expectedCommission;

        vm.startPrank(user);
        xcup.approve(address(commissionTransfer), amount);

        uint256 receiverBefore = usdc.balanceOf(commissionReceiver);
        uint256 recipientBefore = usdc.balanceOf(recipient);

        commissionTransfer.transferTokenWithCommission(xcup, recipient, amount);

        assertGe(usdc.balanceOf(commissionReceiver) - receiverBefore, expectedCommission - 1); // Allow 1 wei difference
        assertGe(usdc.balanceOf(recipient) - recipientBefore, expectedTransfer - 1);
        vm.stopPrank();
    }

    function test_TransferTokenWithCommission_OtherToken() public {
        uint256 amount = 1000 * 1e18;
        uint256 expectedCommission = (amount * 20) / 1000; // 2.0%
        uint256 expectedTransfer = amount - expectedCommission;

        vm.startPrank(user);
        otherToken.approve(address(commissionTransfer), amount);

        uint256 receiverBefore = otherToken.balanceOf(commissionReceiver);
        uint256 recipientBefore = otherToken.balanceOf(recipient);

        commissionTransfer.transferTokenWithCommission(otherToken, recipient, amount);

        assertEq(otherToken.balanceOf(commissionReceiver) - receiverBefore, expectedCommission);
        assertEq(otherToken.balanceOf(recipient) - recipientBefore, expectedTransfer);
        vm.stopPrank();
    }

    function test_TransferTokenWithCommissionInvalidAddress() public {
        vm.startPrank(user);
        usdc.approve(address(commissionTransfer), 1000 * ONE_USDC);
        vm.expectRevert(CommissionTransfer.InvalidAddress.selector);
        commissionTransfer.transferTokenWithCommission(usdc, address(0), 1000 * ONE_USDC);
        vm.stopPrank();
    }

    function test_TransferTokenWithCommissionZeroAmount() public {
        vm.startPrank(user);
        usdc.approve(address(commissionTransfer), 1000 * ONE_USDC);
        vm.expectRevert(CommissionTransfer.InvalidAmount.selector);
        commissionTransfer.transferTokenWithCommission(usdc, recipient, 0);
        vm.stopPrank();
    }

    // ───────────────────────────── PERMIT TESTS ─────────────────────────────

    function _getPermitSignature(
        IERC20Permit token,
        address owner,
        address spender,
        uint256 value,
        uint256 deadline,
        uint256 privateKey
    ) internal view returns (uint8 v, bytes32 r, bytes32 s) {
        uint256 nonce = token.nonces(owner);
        bytes32 structHash = keccak256(
            abi.encode(
                keccak256("Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)"),
                owner,
                spender,
                value,
                nonce,
                deadline
            )
        );
        bytes32 domainSeparator = token.DOMAIN_SEPARATOR();
        bytes32 hash = keccak256(abi.encodePacked("\x19\x01", domainSeparator, structHash));
        return vm.sign(privateKey, hash);
    }

    function test_TransferTokenWithCommissionWithPermit() public {
        uint256 amount = 1000 * 1e18;
        uint256 deadline = block.timestamp + 1 days;
        uint256 privateKey = 0x1234567890123456789012345678901234567890123456789012345678901234;
        address signer = vm.addr(privateKey);

        permitToken.mint(signer, amount);

        (uint8 v, bytes32 r, bytes32 s) = _getPermitSignature(
            permitToken,
            signer,
            address(commissionTransfer),
            amount,
            deadline,
            privateKey
        );

        uint256 expectedCommission = (amount * 20) / 1000;
        uint256 expectedTransfer = amount - expectedCommission;

        vm.startPrank(signer);
        uint256 receiverBefore = permitToken.balanceOf(commissionReceiver);
        uint256 recipientBefore = permitToken.balanceOf(recipient);

        commissionTransfer.transferTokenWithCommissionWithPermit(permitToken, recipient, amount, deadline, v, r, s);

        assertEq(permitToken.balanceOf(commissionReceiver) - receiverBefore, expectedCommission);
        assertEq(permitToken.balanceOf(recipient) - recipientBefore, expectedTransfer);
        vm.stopPrank();
    }

    // ───────────────────────────── VIEW FUNCTIONS TESTS ─────────────────────────────

    function test_IsSwapSupportedToken() public {
        assertTrue(commissionTransfer.isSwapSupportedToken(address(usdt)));
        assertTrue(commissionTransfer.isSwapSupportedToken(address(xcup)));
        assertFalse(commissionTransfer.isSwapSupportedToken(address(usdc)));
        assertFalse(commissionTransfer.isSwapSupportedToken(address(otherToken)));
    }

    // ───────────────────────────── EMERGENCY WITHDRAW TESTS ─────────────────────────────

    function test_EmergencyWithdraw() public {
        usdc.mint(address(commissionTransfer), 1000 * ONE_USDC);
        uint256 ownerBefore = usdc.balanceOf(owner);

        vm.prank(owner);
        commissionTransfer.emergencyWithdraw(usdc);

        assertEq(usdc.balanceOf(owner) - ownerBefore, 1000 * ONE_USDC);
    }

    function test_EmergencyWithdrawNoBalance() public {
        vm.prank(owner);
        vm.expectRevert(CommissionTransfer.NoBalance.selector);
        commissionTransfer.emergencyWithdraw(usdc);
    }

    function test_EmergencyWithdrawETH() public {
        vm.deal(address(commissionTransfer), 1 ether);
        uint256 ownerBefore = owner.balance;

        vm.prank(owner);
        commissionTransfer.emergencyWithdrawETH();

        assertEq(owner.balance - ownerBefore, 1 ether);
    }

    function test_EmergencyWithdrawETHNoBalance() public {
        vm.prank(owner);
        vm.expectRevert(CommissionTransfer.NoBalance.selector);
        commissionTransfer.emergencyWithdrawETH();
    }

    // ───────────────────────────── EDGE CASES TESTS ─────────────────────────────

    function test_TransferTokenWithCommissionMaxCommission() public {
        vm.prank(owner);
        commissionTransfer.setCommissionPercentage(1000); // 100%

        uint256 amount = 1000 * ONE_USDC;
        vm.startPrank(user);
        usdc.approve(address(commissionTransfer), amount);

        uint256 receiverBefore = usdc.balanceOf(commissionReceiver);
        uint256 recipientBefore = usdc.balanceOf(recipient);

        commissionTransfer.transferTokenWithCommission(usdc, recipient, amount);

        assertEq(usdc.balanceOf(commissionReceiver) - receiverBefore, amount);
        assertEq(usdc.balanceOf(recipient) - recipientBefore, 0);
        vm.stopPrank();
    }

    function test_TransferTokenWithCommissionZeroCommission() public {
        vm.prank(owner);
        commissionTransfer.setCommissionPercentage(0); // 0%

        uint256 amount = 1000 * ONE_USDC;
        vm.startPrank(user);
        usdc.approve(address(commissionTransfer), amount);

        uint256 recipientBefore = usdc.balanceOf(recipient);

        commissionTransfer.transferTokenWithCommission(usdc, recipient, amount);

        assertEq(usdc.balanceOf(recipient) - recipientBefore, amount);
        vm.stopPrank();
    }
}
