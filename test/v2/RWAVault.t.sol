// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {V2TestBase, MockAssetOracle} from "./Helpers.sol";
import {RWAVault} from "../../contracts/v2/RWAVault.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract RWAVaultTest is V2TestBase {
    RWAVault internal vault;

    uint256 constant ASSET_PRICE = 450_000_000; // $4.50 (8 dec)
    uint256 constant DEPOSIT_AMOUNT = 1000e6; // 1000 RWA tokens

    function setUp() public override {
        super.setUp();
        vault = RWAVault(vaultAddr);
    }

    // ─── decimals ─────────────────────────────────────────────────────────────

    function test_decimals_is6() public {
        assertEq(vault.decimals(), 6);
    }

    // ─── asset / underlying ───────────────────────────────────────────────────

    function test_asset_isAssetToken() public {
        assertEq(vault.asset(), address(assetToken));
    }

    // ─── getAssetPrice ────────────────────────────────────────────────────────

    function test_getAssetPrice_returnsOraclePrice() public {
        assertEq(vault.getAssetPrice(), ASSET_PRICE);
    }

    // ─── deposit (ERC-4626) ───────────────────────────────────────────────────

    function _mintAndDeposit(address depositor, uint256 amount) internal returns (uint256 shares) {
        assetToken.mint(depositor, amount);
        vm.prank(depositor);
        assetToken.approve(address(vault), amount);
        vm.prank(depositor);
        shares = vault.deposit(amount, depositor);
    }

    function test_deposit_mintsShares() public {
        uint256 shares = _mintAndDeposit(user, DEPOSIT_AMOUNT);
        assertGt(shares, 0);
        assertEq(vault.balanceOf(user), shares);
    }

    function test_deposit_increasesTotalAssets() public {
        _mintAndDeposit(user, DEPOSIT_AMOUNT);
        assertEq(vault.totalAssets(), DEPOSIT_AMOUNT);
    }

    function test_deposit_multipleUsers() public {
        uint256 s1 = _mintAndDeposit(user, DEPOSIT_AMOUNT);
        uint256 s2 = _mintAndDeposit(user2, DEPOSIT_AMOUNT);
        assertEq(s1, s2);
        assertEq(vault.totalAssets(), 2 * DEPOSIT_AMOUNT);
    }

    function test_mint_mintsTargetShares() public {
        uint256 targetShares = 2_000_000_000_000; // respects virtual offset in empty vault
        uint256 assetsNeeded = vault.previewMint(targetShares);

        assetToken.mint(user, assetsNeeded);
        vm.startPrank(user);
        assetToken.approve(address(vault), assetsNeeded);
        uint256 paidAssets = vault.mint(targetShares, user);
        vm.stopPrank();

        assertEq(vault.balanceOf(user), targetShares);
        assertEq(paidAssets, assetsNeeded);
    }

    // ─── withdraw / redeem (REDEEMER_ROLE only) ───────────────────────────────

    function test_withdraw_revertsIfNotRedeemer() public {
        _mintAndDeposit(user, DEPOSIT_AMOUNT);

        vm.prank(user);
        vm.expectRevert(); // AccessControlUnauthorizedAccount
        vault.withdraw(DEPOSIT_AMOUNT, user, user);
    }

    function test_redeem_revertsIfNotRedeemer() public {
        uint256 shares = _mintAndDeposit(user, DEPOSIT_AMOUNT);

        vm.prank(user);
        vm.expectRevert(); // AccessControlUnauthorizedAccount
        vault.redeem(shares, user, user);
    }

    function test_withdraw_succeeds_withRedeemerRole() public {
        _mintAndDeposit(user, DEPOSIT_AMOUNT);

        // Cache role before prank (calling a view function would consume vm.prank)
        bytes32 redeemerRole = vault.REDEEMER_ROLE();
        vm.prank(admin);
        vault.grantRole(redeemerRole, admin);

        // Admin approves itself to spend user's shares
        vm.prank(user);
        vault.approve(admin, type(uint256).max);

        uint256 before = assetToken.balanceOf(user);
        vm.prank(admin);
        vault.withdraw(DEPOSIT_AMOUNT, user, user);

        assertEq(assetToken.balanceOf(user) - before, DEPOSIT_AMOUNT);
    }

    function test_redeem_succeeds_withRedeemerRole() public {
        uint256 shares = _mintAndDeposit(user, DEPOSIT_AMOUNT);

        bytes32 redeemerRole = vault.REDEEMER_ROLE();
        vm.prank(admin);
        vault.grantRole(redeemerRole, admin);

        vm.prank(user);
        vault.approve(admin, type(uint256).max);

        uint256 before = assetToken.balanceOf(user);
        vm.prank(admin);
        uint256 assets = vault.redeem(shares, user, user);

        assertEq(assetToken.balanceOf(user) - before, assets);
        assertEq(vault.balanceOf(user), 0);
    }

    // ─── pause / unpause ─────────────────────────────────────────────────────

    function test_pause_blocksDeposit() public {
        vm.prank(admin);
        vault.pause();

        assetToken.mint(user, DEPOSIT_AMOUNT);
        vm.prank(user);
        assetToken.approve(address(vault), DEPOSIT_AMOUNT);
        vm.prank(user);
        vm.expectRevert();
        vault.deposit(DEPOSIT_AMOUNT, user);
    }

    function test_pause_blocksWithdraw() public {
        uint256 shares = _mintAndDeposit(user, DEPOSIT_AMOUNT);

        // Grant admin REDEEMER_ROLE so we can test the pause
        bytes32 redeemerRole = vault.REDEEMER_ROLE();
        vm.prank(admin);
        vault.grantRole(redeemerRole, admin);

        vm.prank(admin);
        vault.pause();

        // Redeem should revert when paused
        vm.prank(user);
        vault.approve(admin, type(uint256).max);

        vm.prank(admin);
        vm.expectRevert();
        vault.redeem(shares, user, user);
    }

    function test_unpause_restoresOperations() public {
        vm.prank(admin);
        vault.pause();
        vm.prank(admin);
        vault.unpause();

        uint256 shares = _mintAndDeposit(user, DEPOSIT_AMOUNT);
        assertGt(shares, 0);
    }

    function test_pause_revertsUnauthorized() public {
        vm.prank(user);
        vm.expectRevert();
        vault.pause();
    }

    // ─── setAssetOracle ───────────────────────────────────────────────────────

    function test_setAssetOracle_updatesOracle() public {
        address newOracle = address(new MockAssetOracle(500_000_000, "X/USD"));
        vm.prank(admin);
        vault.setAssetOracle(newOracle);
        assertEq(address(vault.assetOracle()), newOracle);
    }

    function test_setAssetOracle_emitsEvent() public {
        address newOracle = address(new MockAssetOracle(500_000_000, "X/USD"));
        vm.prank(admin);
        vm.expectEmit(true, true, false, false);
        emit RWAVault.AssetOracleUpdated(address(assetOracle), newOracle);
        vault.setAssetOracle(newOracle);
    }

    function test_setAssetOracle_revertsZeroAddress() public {
        vm.prank(admin);
        vm.expectRevert(RWAVault.InvalidAddress.selector);
        vault.setAssetOracle(address(0));
    }

    function test_setAssetOracle_revertsUnauthorized() public {
        vm.prank(user);
        vm.expectRevert();
        vault.setAssetOracle(address(assetOracle));
    }

    // ─── setUniswapRouter ─────────────────────────────────────────────────────

    function test_setUniswapRouter_updates() public {
        address newRouter = makeAddr("newRouter");
        vm.prank(admin);
        vault.setUniswapRouter(newRouter);
        assertEq(address(vault.uniswapRouter()), newRouter);
    }

    function test_setUniswapRouter_revertsZeroAddress() public {
        vm.prank(admin);
        vm.expectRevert(RWAVault.InvalidAddress.selector);
        vault.setUniswapRouter(address(0));
    }

    // ─── setSettlementToken ───────────────────────────────────────────────────

    function test_setUsdcToken_updates() public {
        address newUsdc = makeAddr("newUsdc");
        vm.prank(admin);
        vault.setSettlementToken(newUsdc);
        assertEq(address(vault.settlementToken()), newUsdc);
    }

    function test_setUsdcToken_revertsZeroAddress() public {
        vm.prank(admin);
        vm.expectRevert(RWAVault.InvalidAddress.selector);
        vault.setSettlementToken(address(0));
    }

    // ─── setWethToken ─────────────────────────────────────────────────────────

    function test_setWethToken_updates() public {
        address newWeth = makeAddr("newWeth");
        vm.prank(admin);
        vault.setWethToken(newWeth);
        assertEq(vault.wethToken(), newWeth);
    }

    function test_setWethToken_revertsZeroAddress() public {
        vm.prank(admin);
        vm.expectRevert(RWAVault.InvalidAddress.selector);
        vault.setWethToken(address(0));
    }

    function test_setSwapIntermediary_updates() public {
        address mid = makeAddr("swap-mid");
        vm.prank(admin);
        vault.setSwapIntermediary(mid);
        assertEq(vault.swapIntermediary(), mid);
    }

    // ─── getShareValueIn ─────────────────────────────────────────────────────

    function test_getShareValueIn_usdc() public {
        uint256 shares = _mintAndDeposit(user, DEPOSIT_AMOUNT);

        // Quote in USDC: 1000 tokens × $4.50 = $4500
        uint256 value = vault.getShareValueIn(address(usdc), shares);
        assertEq(value, 4500e6);
    }

    function test_getShareValueIn_revertsZeroShares() public {
        vm.expectRevert(RWAVault.InvalidAmount.selector);
        vault.getShareValueIn(address(usdc), 0);
    }

    function test_getShareValueIn_nonSettlementQuote_usesRouterQuote() public {
        uint256 shares = _mintAndDeposit(user, DEPOSIT_AMOUNT);
        uint256 value = vault.getShareValueIn(address(assetToken), shares);
        // Mock router is 1:1, so non-settlement quote equals settlement value.
        assertEq(value, 4500e6);
    }

    function test_getShareValueIn_nativeQuote_usesWethPath() public {
        uint256 shares = _mintAndDeposit(user, DEPOSIT_AMOUNT);
        uint256 value = vault.getShareValueIn(address(0), shares);
        assertEq(value, 4500e6);
    }

    function test_getShareValueIn_revertsWhenOraclePriceZero() public {
        MockAssetOracle(address(assetOracle)).setPrice(0);
        uint256 shares = _mintAndDeposit(user, DEPOSIT_AMOUNT);
        vm.expectRevert(RWAVault.InvalidAssetPrice.selector);
        vault.getShareValueIn(address(usdc), shares);
    }

    // ─── getTokenToShareRate ─────────────────────────────────────────────────

    function test_getTokenToShareRate_usdc() public {
        // 4500 USDC / $4.50 = 1000 tokens → shares
        // Vault is empty so rate = 1:1, shares = convertToShares(1000e6) = 1000e6
        uint256 shares = vault.getTokenToShareRate(address(usdc), 4500e6);
        assertGt(shares, 0);
    }

    function test_getTokenToShareRate_revertsZeroAmount() public {
        vm.expectRevert(RWAVault.InvalidAmount.selector);
        vault.getTokenToShareRate(address(usdc), 0);
    }

    function test_getTokenToShareRate_nonSettlementInput_usesRouterQuote() public {
        uint256 shares = vault.getTokenToShareRate(address(assetToken), 1000e6);
        assertGt(shares, 0);
    }

    function test_getTokenToShareRate_nativeInput_usesWethQuote() public {
        uint256 shares = vault.getTokenToShareRate(address(0), 1000e6);
        assertGt(shares, 0);
    }

    function test_getTokenToShareRate_revertsWhenOraclePriceZero() public {
        MockAssetOracle(address(assetOracle)).setPrice(0);
        vm.expectRevert(RWAVault.InvalidAssetPrice.selector);
        vault.getTokenToShareRate(address(usdc), 1000e6);
    }

    // ─── convertToAssets / convertToShares ───────────────────────────────────

    function test_convertToShares_zeroTotalSupply_usesVirtualOffset() public {
        // Empty vault: _decimalsOffset=3 → shares = assets * 10**3.
        assertEq(vault.convertToShares(1000e6), 1_000_000_000_000);
    }

    function test_convertToAssets_afterDeposit() public {
        _mintAndDeposit(user, DEPOSIT_AMOUNT);
        // totalAssets = DEPOSIT_AMOUNT, totalSupply = DEPOSIT_AMOUNT → 1:1
        uint256 assets = vault.convertToAssets(vault.balanceOf(user));
        assertApproxEqAbs(assets, DEPOSIT_AMOUNT, 1);
    }
}
