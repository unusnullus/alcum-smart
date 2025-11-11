// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test, console} from "forge-std/Test.sol";
import {XCUPOraclePool} from "../contracts/XCUPOraclePool.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IXCUPPriceView} from "../contracts/interfaces/IXCUPPriceView.sol";

// Mock xCUP with price view
contract MockXCUP is ERC20, IXCUPPriceView {
    uint256 public constant PRICE_MULTIPLIER = 1_000_000; // 1 xCUP = 1 USDC (6 decimals each)
    IERC20 public usdc;

    constructor(address _usdc) ERC20("xCUP", "XCUP") {
        usdc = IERC20(_usdc);
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

// Mock USDC
contract MockUSDC is ERC20 {
    constructor() ERC20("USDC", "USDC") {}

    function decimals() public pure override returns (uint8) {
        return 6;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract XCUPOraclePoolTest is Test {
    XCUPOraclePool public pool;
    MockXCUP public xcup;
    MockUSDC public usdc;
    address public owner;
    address public user;

    uint256 constant ONE_XCUP = 1e6;
    uint256 constant ONE_USDC = 1e6;

    function setUp() public {
        owner = makeAddr("owner");
        user = makeAddr("user");

        vm.startPrank(owner);

        // Deploy tokens
        usdc = new MockUSDC();
        xcup = new MockXCUP(address(usdc));

        // Deploy pool
        XCUPOraclePool impl = new XCUPOraclePool();
        bytes memory initData = abi.encodeWithSelector(
            XCUPOraclePool.initialize.selector,
            address(xcup),
            address(usdc)
        );
        ERC1967Proxy proxy = new ERC1967Proxy(address(impl), initData);
        pool = XCUPOraclePool(address(proxy));

        // Mint tokens to user
        xcup.mint(user, 100000 * ONE_XCUP);
        usdc.mint(user, 100000 * ONE_USDC);

        vm.stopPrank();
    }

    // ───────────────────────────── INITIALIZATION TESTS ─────────────────────────────

    function test_Initialize() public {
        assertEq(address(pool.xcup()), address(xcup));
        assertEq(address(pool.usdc()), address(usdc));
        assertEq(pool.swapFee(), 50); // 0.5% default
    }

    // ───────────────────────────── RESERVES TESTS ─────────────────────────────

    function test_GetReservesEmpty() public {
        (uint256 rX, uint256 rU) = pool.getReserves();
        assertEq(rX, 0);
        assertEq(rU, 0);
    }

    // ───────────────────────────── PRICING TESTS ─────────────────────────────

    function test_GetAdjustedPriceXCUPToUSDC() public {
        uint256 price = pool.getAdjustedPrice(address(xcup), address(usdc));
        // 1 xCUP = 1 USDC
        assertEq(price, 1_000_000);
    }

    function test_GetAdjustedPriceUSDCToXCUP() public {
        uint256 price = pool.getAdjustedPrice(address(usdc), address(xcup));
        // 1 USDC = 1 xCUP
        assertEq(price, 1_000_000);
    }

    function test_GetAdjustedPriceInvalidPair() public {
        address otherToken = makeAddr("otherToken");
        vm.expectRevert("XCUPOraclePool: invalid pair");
        pool.getAdjustedPrice(address(xcup), otherToken);
    }

    // ───────────────────────────── ADD LIQUIDITY TESTS ─────────────────────────────

    function test_AddLiquiditySingleSidedXCUP() public {
        uint256 xcupAmount = 1000 * ONE_XCUP;

        vm.startPrank(user);
        xcup.approve(address(pool), xcupAmount);
        (uint256 xcupAdded, uint256 usdcAdded, uint256 lpMinted) = pool.addLiquidity(xcupAmount, 0);
        vm.stopPrank();

        assertEq(xcupAdded, xcupAmount);
        assertEq(usdcAdded, 0);
        assertEq(lpMinted, xcupAmount); // First LP, minted by USD value
        assertEq(xcup.balanceOf(address(pool)), xcupAmount);
    }

    function test_AddLiquiditySingleSidedUSDC() public {
        uint256 usdcAmount = 1000 * ONE_USDC;

        vm.startPrank(user);
        usdc.approve(address(pool), usdcAmount);
        (uint256 xcupAdded, uint256 usdcAdded, uint256 lpMinted) = pool.addLiquidity(0, usdcAmount);
        vm.stopPrank();

        assertEq(xcupAdded, 0);
        assertEq(usdcAdded, usdcAmount);
        assertEq(lpMinted, usdcAmount); // First LP, minted by USD value
        assertEq(usdc.balanceOf(address(pool)), usdcAmount);
    }

    function test_AddLiquidityDualSided() public {
        uint256 xcupAmount = 1000 * ONE_XCUP;
        uint256 usdcAmount = 1000 * ONE_USDC;

        vm.startPrank(user);
        xcup.approve(address(pool), xcupAmount);
        usdc.approve(address(pool), usdcAmount);
        (uint256 xcupAdded, uint256 usdcAdded, uint256 lpMinted) = pool.addLiquidity(xcupAmount, usdcAmount);
        vm.stopPrank();

        assertEq(xcupAdded, xcupAmount);
        assertEq(usdcAdded, usdcAmount);
        assertEq(lpMinted, xcupAmount + usdcAmount); // First LP
        assertEq(xcup.balanceOf(address(pool)), xcupAmount);
        assertEq(usdc.balanceOf(address(pool)), usdcAmount);
    }

    function test_AddLiquidityZeroDesired() public {
        vm.startPrank(user);
        vm.expectRevert("XCUPOraclePool: zero desired");
        pool.addLiquidity(0, 0);
        vm.stopPrank();
    }

    function test_AddLiquidityProportional() public {
        // First add liquidity
        uint256 xcupAmount1 = 1000 * ONE_XCUP;
        uint256 usdcAmount1 = 1000 * ONE_USDC;

        vm.startPrank(user);
        xcup.approve(address(pool), xcupAmount1 * 2);
        usdc.approve(address(pool), usdcAmount1 * 2);
        pool.addLiquidity(xcupAmount1, usdcAmount1);

        // Second add should be proportional
        uint256 xcupAmount2 = 500 * ONE_XCUP;
        uint256 usdcAmount2 = 1000 * ONE_USDC; // More than needed

        (uint256 xcupAdded, uint256 usdcAdded, uint256 lpMinted) = pool.addLiquidity(xcupAmount2, usdcAmount2);
        vm.stopPrank();

        // Should use all xCUP and proportional USDC
        assertEq(xcupAdded, xcupAmount2);
        assertEq(usdcAdded, 500 * ONE_USDC); // Proportional to xCUP
        assertGt(lpMinted, 0);
    }

    // ───────────────────────────── REMOVE LIQUIDITY TESTS ─────────────────────────────

    function test_RemoveLiquidity() public {
        // First add liquidity
        uint256 xcupAmount = 1000 * ONE_XCUP;
        uint256 usdcAmount = 1000 * ONE_USDC;

        vm.startPrank(user);
        uint256 userXCUPBefore = xcup.balanceOf(user);
        uint256 userUSDCBefore = usdc.balanceOf(user);

        xcup.approve(address(pool), xcupAmount);
        usdc.approve(address(pool), usdcAmount);
        (, , uint256 lpMinted) = pool.addLiquidity(xcupAmount, usdcAmount);

        // Remove half liquidity
        uint256 lpToRemove = lpMinted / 2;
        pool.approve(address(pool), lpToRemove);
        (uint256 xcupReturned, uint256 usdcReturned) = pool.removeLiquidity(lpToRemove);

        uint256 userXCUPAfter = xcup.balanceOf(user);
        uint256 userUSDCAfter = usdc.balanceOf(user);
        vm.stopPrank();

        assertEq(xcupReturned, xcupAmount / 2);
        assertEq(usdcReturned, usdcAmount / 2);
        // User spent xcupAmount, got back half, so net change is -xcupAmount/2
        assertEq(userXCUPBefore - userXCUPAfter, xcupAmount / 2);
        assertEq(userUSDCBefore - userUSDCAfter, usdcAmount / 2);
    }

    function test_RemoveLiquidityZeroLP() public {
        vm.startPrank(user);
        vm.expectRevert("XCUPOraclePool: zero LP");
        pool.removeLiquidity(0);
        vm.stopPrank();
    }

    function test_RemoveLiquidityEmptyPool() public {
        vm.startPrank(user);
        xcup.mint(user, 1000 * ONE_XCUP);
        xcup.approve(address(pool), 1000 * ONE_XCUP);
        (, , uint256 lpMinted) = pool.addLiquidity(1000 * ONE_XCUP, 0);

        // Remove all liquidity
        pool.removeLiquidity(lpMinted);

        // Try to remove from empty pool
        vm.expectRevert("XCUPOraclePool: empty");
        pool.removeLiquidity(1);
        vm.stopPrank();
    }

    // ───────────────────────────── SWAP TESTS ─────────────────────────────

    function test_SwapExactXCUPToUSDC() public {
        // Add liquidity first
        uint256 xcupLiquidity = 10000 * ONE_XCUP;
        uint256 usdcLiquidity = 10000 * ONE_USDC;

        vm.startPrank(user);
        xcup.approve(address(pool), xcupLiquidity * 2);
        usdc.approve(address(pool), usdcLiquidity);
        pool.addLiquidity(xcupLiquidity, usdcLiquidity);

        // Swap xCUP to USDC
        uint256 xcupAmount = 1000 * ONE_XCUP;
        uint256 minUSDCOut = 900 * ONE_USDC; // Allow some slippage

        uint256 userUSDCBefore = usdc.balanceOf(user);
        xcup.approve(address(pool), xcupAmount);
        pool.swapExactXCUPToUSDC(xcupAmount, minUSDCOut);
        uint256 userUSDCAfter = usdc.balanceOf(user);

        assertGt(userUSDCAfter - userUSDCBefore, minUSDCOut);
        vm.stopPrank();
    }

    function test_SwapExactXCUPToUSDCZeroAmount() public {
        vm.startPrank(user);
        vm.expectRevert("XCUPOraclePool: zero in");
        pool.swapExactXCUPToUSDC(0, 0);
        vm.stopPrank();
    }

    function test_SwapExactXCUPToUSDCSlippage() public {
        // Add liquidity first
        uint256 xcupLiquidity = 10000 * ONE_XCUP;
        uint256 usdcLiquidity = 10000 * ONE_USDC;

        vm.startPrank(user);
        xcup.approve(address(pool), xcupLiquidity * 2);
        usdc.approve(address(pool), usdcLiquidity);
        pool.addLiquidity(xcupLiquidity, usdcLiquidity);

        // Try swap with too high minOut
        uint256 xcupAmount = 1000 * ONE_XCUP;
        uint256 minUSDCOut = 10000 * ONE_USDC; // Too high

        xcup.approve(address(pool), xcupAmount);
        vm.expectRevert("XCUPOraclePool: slippage");
        pool.swapExactXCUPToUSDC(xcupAmount, minUSDCOut);
        vm.stopPrank();
    }

    function test_SwapExactUSDCToXCUP() public {
        // Add liquidity first
        uint256 xcupLiquidity = 10000 * ONE_XCUP;
        uint256 usdcLiquidity = 10000 * ONE_USDC;

        vm.startPrank(user);
        xcup.approve(address(pool), xcupLiquidity);
        usdc.approve(address(pool), usdcLiquidity * 2);
        pool.addLiquidity(xcupLiquidity, usdcLiquidity);

        // Swap USDC to xCUP
        uint256 usdcAmount = 1000 * ONE_USDC;
        uint256 minXCUPOut = 900 * ONE_XCUP; // Allow some slippage

        uint256 userXCUPBefore = xcup.balanceOf(user);
        usdc.approve(address(pool), usdcAmount);
        pool.swapExactUSDCToXCUP(usdcAmount, minXCUPOut);
        uint256 userXCUPAfter = xcup.balanceOf(user);

        assertGt(userXCUPAfter - userXCUPBefore, minXCUPOut);
        vm.stopPrank();
    }

    function test_SwapExactUSDCToXCUPZeroAmount() public {
        vm.startPrank(user);
        vm.expectRevert("XCUPOraclePool: zero in");
        pool.swapExactUSDCToXCUP(0, 0);
        vm.stopPrank();
    }

    // ───────────────────────────── ADMIN FUNCTIONS TESTS ─────────────────────────────

    function test_SetSwapFee() public {
        vm.prank(owner);
        pool.setSwapFee(100); // 1%
        assertEq(pool.swapFee(), 100);
    }

    function test_SetSwapFeeTooHigh() public {
        vm.prank(owner);
        vm.expectRevert("XCUPOraclePool: fee too high");
        pool.setSwapFee(501); // > 5%
    }

    function test_Pause() public {
        vm.prank(owner);
        pool.pause();
        assertTrue(pool.paused());
    }

    function test_Unpause() public {
        vm.prank(owner);
        pool.pause();
        vm.prank(owner);
        pool.unpause();
        assertFalse(pool.paused());
    }

    function test_AddLiquidityWhenPaused() public {
        vm.prank(owner);
        pool.pause();

        vm.startPrank(user);
        xcup.approve(address(pool), 1000 * ONE_XCUP);
        vm.expectRevert();
        pool.addLiquidity(1000 * ONE_XCUP, 0);
        vm.stopPrank();
    }

    function test_SwapWhenPaused() public {
        vm.prank(owner);
        pool.pause();

        vm.startPrank(user);
        xcup.approve(address(pool), 1000 * ONE_XCUP);
        vm.expectRevert();
        pool.swapExactXCUPToUSDC(1000 * ONE_XCUP, 0);
        vm.stopPrank();
    }

    // ───────────────────────────── PREVIEW TESTS ─────────────────────────────

    function test_PreviewAddLiquidity() public {
        uint256 xcupDesired = 1000 * ONE_XCUP;
        uint256 usdcDesired = 1000 * ONE_USDC;

        (uint256 xcupToAdd, uint256 usdcToAdd, uint256 lpToMint) = pool.previewAddLiquidity(xcupDesired, usdcDesired);

        assertEq(xcupToAdd, xcupDesired);
        assertEq(usdcToAdd, usdcDesired);
        assertGt(lpToMint, 0);
    }

    function test_PreviewAddLiquidityZeroDesired() public {
        vm.expectRevert("XCUPOraclePool: zero desired");
        pool.previewAddLiquidity(0, 0);
    }

    // ───────────────────────────── DECIMALS TESTS ─────────────────────────────

    function test_Decimals() public {
        assertEq(pool.decimals(), 6);
    }
}
