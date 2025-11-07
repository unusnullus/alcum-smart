// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {XCUPRatePool} from "../contracts/XCUPRatePool.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

contract ERC20Mock {
    string public name;
    string public symbol;
    uint8 public immutable decimals;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);

    constructor(string memory _name, string memory _symbol, uint8 _decimals) {
        name = _name;
        symbol = _symbol;
        decimals = _decimals;
    }

    function mint(address to, uint256 amount) external {
        totalSupply += amount;
        balanceOf[to] += amount;
        emit Transfer(address(0), to, amount);
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        emit Approval(msg.sender, spender, amount);
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        _transfer(msg.sender, to, amount);
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        uint256 allowed = allowance[from][msg.sender];
        require(allowed >= amount, "ALLOW");
        if (allowed != type(uint256).max) {
            allowance[from][msg.sender] = allowed - amount;
        }
        _transfer(from, to, amount);
        return true;
    }

    function _transfer(address from, address to, uint256 amount) internal {
        require(balanceOf[from] >= amount, "BAL");
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        emit Transfer(from, to, amount);
    }
}

contract XCUPRatePoolTest is Test {
    ERC20Mock xcup;
    ERC20Mock usdc;
    XCUPRatePool pool;

    address user = address(0xBEEF);
    address other = address(0xCAFE);

    uint256 constant ONE_XCUP = 1e18;
    uint256 constant ONE_USDC = 1e6;

    function setUp() public {
        // deploy mocks
        xcup = new ERC20Mock("xCUP", "xCUP", 18);
        usdc = new ERC20Mock("USDC", "USDC", 6);

        // mint balances
        xcup.mint(address(this), 1_000_000 * ONE_XCUP);
        xcup.mint(user, 1_000_000 * ONE_XCUP);
        usdc.mint(address(this), 1_000_000 * ONE_USDC);
        usdc.mint(user, 1_000_000 * ONE_USDC);

        // deploy implementation
        XCUPRatePool impl = new XCUPRatePool();
        // initialize via proxy (implementation has disabled initializers in constructor)
        bytes memory initData = abi.encodeWithSelector(XCUPRatePool.initialize.selector, address(xcup), address(usdc));
        ERC1967Proxy proxy = new ERC1967Proxy(address(impl), initData);
        pool = XCUPRatePool(address(proxy));

        // approvals
        xcup.approve(address(pool), type(uint256).max);
        usdc.approve(address(pool), type(uint256).max);
        vm.prank(user);
        xcup.approve(address(pool), type(uint256).max);
        vm.prank(user);
        usdc.approve(address(pool), type(uint256).max);
    }

    function _sqrt(uint256 y) internal pure returns (uint256 z) {
        if (y == 0) return 0;
        uint256 x = (y + 1) / 2;
        z = y;
        while (x < z) {
            z = x;
            x = (y / x + x) / 2;
        }
    }

    function test_AddLiquidity_Initial_MintsSqrt() public {
        uint256 x = 1_000 * ONE_XCUP;
        uint256 u = 1_000 * ONE_USDC;

        (uint256 ax, uint256 au, uint256 lp) = pool.addLiquidity(x, u);
        assertEq(ax, x, "ax");
        assertEq(au, u, "au");

        uint256 expectedLP = _sqrt(x * u);
        assertEq(pool.totalSupply(), expectedLP, "lp ts");
        assertEq(pool.balanceOf(address(this)), expectedLP, "lp bal");

        (uint256 rX, uint256 rU) = pool.getReserves();
        assertEq(rX, x, "rX");
        assertEq(rU, u, "rU");
    }

    function test_AddLiquidity_Proportional_MintsShare() public {
        test_AddLiquidity_Initial_MintsSqrt();
        (uint256 rX, uint256 rU) = pool.getReserves();
        uint256 ts = pool.totalSupply();

        uint256 addX = rX / 2;
        uint256 addU = rU / 2;
        (, , uint256 lpMinted) = pool.addLiquidity(addX, addU);
        // share = 0.5 → lp minted ~= ts/2
        assertEq(lpMinted, ts / 2, "lp share");

        (uint256 rX2, uint256 rU2) = pool.getReserves();
        assertEq(rX2, rX + addX, "rX2");
        assertEq(rU2, rU + addU, "rU2");
    }

    function test_AddLiquidity_Optimal_TrimsInputs() public {
        // init 1000:1000
        pool.addLiquidity(1_000 * ONE_XCUP, 1_000 * ONE_USDC);

        // provide off-ratio: more xcupDesired than needed
        uint256 xDesired = 2_000 * ONE_XCUP;
        uint256 uDesired = 500 * ONE_USDC;

        (uint256 ax, uint256 au, uint256 lp) = pool.addLiquidity(xDesired, uDesired);
        // should trim xcup to keep ratio ~ 1000:1000 → optimal x = uDesired * rX / rU = 500 * 1000 / 1000 = 500
        assertEq(ax, 500 * ONE_XCUP, "ax optimal");
        assertEq(au, uDesired, "au all");
        assertGt(lp, 0, "lp>0");
    }

    function test_RemoveLiquidity_Proportional() public {
        (, , uint256 lp0) = pool.addLiquidity(1_000 * ONE_XCUP, 2_000 * ONE_USDC);

        // user adds also
        vm.prank(user);
        pool.addLiquidity(1_000 * ONE_XCUP, 2_000 * ONE_USDC);

        uint256 ts = pool.totalSupply();
        // burn half of owner LP
        uint256 burn = lp0 / 2;

        (uint256 rX, uint256 rU) = pool.getReserves();
        (uint256 outX, uint256 outU) = pool.removeLiquidity(burn);

        assertEq(outX, (rX * burn) / ts, "outX");
        assertEq(outU, (rU * burn) / ts, "outU");
    }

    function test_Swap_XCUP_to_USDC_Formula_WithFee() public {
        pool.addLiquidity(10_000 * ONE_XCUP, 10_000 * ONE_USDC);

        (uint256 rX, uint256 rU) = pool.getReserves();
        uint16 feeBps = pool.swapFee();

        uint256 amountIn = 1_000 * ONE_XCUP;
        uint256 amountInWithFee = (amountIn * (10_000 - feeBps)) / 10_000;
        uint256 expectedOut = (amountInWithFee * rU) / (rX + amountInWithFee);

        vm.expectEmit(true, true, false, true);
        emit XCUPRatePool.Swapped(address(this), address(xcup), amountIn, expectedOut);
        pool.swapExactXCUPToUSDC(amountIn, expectedOut);

        assertEq(usdc.balanceOf(address(this)), 1_000_000 * ONE_USDC - (10_000 * ONE_USDC) + expectedOut, "usdc bal");
    }

    function test_Swap_USDC_to_XCUP_Formula_WithFee() public {
        pool.addLiquidity(10_000 * ONE_XCUP, 10_000 * ONE_USDC);

        (uint256 rX, uint256 rU) = pool.getReserves();
        uint16 feeBps = pool.swapFee();

        uint256 amountIn = 2_000 * ONE_USDC;
        uint256 amountInWithFee = (amountIn * (10_000 - feeBps)) / 10_000;
        uint256 expectedOut = (amountInWithFee * rX) / (rU + amountInWithFee);

        vm.expectEmit(true, true, false, true);
        emit XCUPRatePool.Swapped(address(this), address(usdc), amountIn, expectedOut);
        pool.swapExactUSDCToXCUP(amountIn, expectedOut);

        assertEq(xcup.balanceOf(address(this)), 1_000_000 * ONE_XCUP - (10_000 * ONE_XCUP) + expectedOut, "xcup bal");
    }

    function test_Swap_Slippage_Revert() public {
        pool.addLiquidity(5_000 * ONE_XCUP, 5_000 * ONE_USDC);

        // set unrealistic minOut
        vm.expectRevert(bytes("XCUPRatePool: slippage"));
        pool.swapExactUSDCToXCUP(1_000 * ONE_USDC, type(uint256).max);
    }

    function test_AddLiquidity_ZeroDesired_Revert() public {
        vm.expectRevert(bytes("XCUPRatePool: zero desired"));
        pool.addLiquidity(0, 1);

        vm.expectRevert(bytes("XCUPRatePool: zero desired"));
        pool.addLiquidity(1, 0);
    }

    function test_RemoveLiquidity_ZeroLP_Revert() public {
        pool.addLiquidity(1_000 * ONE_XCUP, 1_000 * ONE_USDC);
        vm.expectRevert(bytes("XCUPRatePool: zero LP"));
        pool.removeLiquidity(0);
    }

    function test_Swap_ZeroIn_Revert() public {
        pool.addLiquidity(1_000 * ONE_XCUP, 1_000 * ONE_USDC);
        vm.expectRevert(bytes("XCUPRatePool: zero in"));
        pool.swapExactXCUPToUSDC(0, 0);
        vm.expectRevert(bytes("XCUPRatePool: zero in"));
        pool.swapExactUSDCToXCUP(0, 0);
    }

    function test_Admin_SetSwapFee_Ok_And_Limit() public {
        pool.setSwapFee(100); // 1%
        assertEq(pool.swapFee(), 100);

        vm.expectRevert(bytes("XCUPRatePool: fee too high"));
        pool.setSwapFee(501);
    }

    function test_Admin_SetSwapFee_OnlyOwner() public {
        vm.prank(other);
        vm.expectRevert(); // OZ OwnableUpgradeable will revert with custom error in v5
        pool.setSwapFee(10);
    }

    function test_Pause_Unpause_BlocksMutations() public {
        pool.addLiquidity(1_000 * ONE_XCUP, 1_000 * ONE_USDC);
        pool.pause();

        // EnforcedPause() custom error; generic expectRevert is sufficient
        vm.expectRevert();
        pool.addLiquidity(1, 1);
        vm.expectRevert();
        pool.removeLiquidity(1);
        vm.expectRevert();
        pool.swapExactXCUPToUSDC(1, 0);
        vm.expectRevert();
        pool.swapExactUSDCToXCUP(1, 0);

        pool.unpause();
        // should work now
        (, , uint256 lp) = pool.addLiquidity(100 * ONE_XCUP, 100 * ONE_USDC);
        assertGt(lp, 0);
    }

    function test_GetReserves_ReflectsBalances() public {
        (uint256 x0, uint256 u0) = pool.getReserves();
        assertEq(x0, 0);
        assertEq(u0, 0);

        pool.addLiquidity(777 * ONE_XCUP, 888 * ONE_USDC);
        (uint256 x1, uint256 u1) = pool.getReserves();
        assertEq(x1, 777 * ONE_XCUP);
        assertEq(u1, 888 * ONE_USDC);
    }
}
