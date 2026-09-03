// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {V2TestBase, MockAccessControlMintable, MockERC20} from "./Helpers.sol";
import {SharedSettlementEngine} from "../../contracts/v2/SharedSettlementEngine.sol";
import {VaultFactory} from "../../contracts/v2/VaultFactory.sol";
import {EpochManager} from "../../contracts/EpochManager.sol";

contract SharedSettlementEngineTest is V2TestBase {
    uint256 constant EPOCH = 1;
    uint256 constant NET_REVENUE = 10_000e6; // $10k USDC
    uint256 constant ASSET_PRICE = 450_000_000; // $4.50
    uint256 constant ASSET_BOUGHT = 5000e6;
    uint256 constant ASSET_SOLD = 3000e6;

    // ─── recordEpochRevenue ────────────────────────────────────────────────

    function test_recordEpochRevenue_storesData() public {
        vm.prank(admin);
        settlement.recordEpochRevenue(
            vaultId,
            EPOCH,
            NET_REVENUE,
            ASSET_BOUGHT,
            ASSET_SOLD,
            ASSET_PRICE,
            ASSET_PRICE + 5_000_000
        );

        SharedSettlementEngine.EpochRevenue memory r = settlement.getEpochRevenue(vaultId, EPOCH);

        assertEq(r.epochId, EPOCH);
        assertEq(r.netRevenue, NET_REVENUE);
        assertEq(r.originalNetRevenue, NET_REVENUE);
        assertEq(r.assetBought, ASSET_BOUGHT);
        assertEq(r.assetSold, ASSET_SOLD);
        assertFalse(r.isSettled);
    }

    function test_recordEpochRevenue_revertsZeroEpoch() public {
        vm.prank(admin);
        vm.expectRevert(SharedSettlementEngine.ZeroEpochId.selector);
        settlement.recordEpochRevenue(vaultId, 0, NET_REVENUE, 0, 0, 0, 0);
    }

    function test_recordEpochRevenue_revertsZeroRevenue() public {
        vm.prank(admin);
        vm.expectRevert(SharedSettlementEngine.ZeroNetRevenue.selector);
        settlement.recordEpochRevenue(vaultId, EPOCH, 0, 0, 0, 0, 0);
    }

    function test_recordEpochRevenue_revertsAlreadySettled() public {
        vm.startPrank(admin);
        settlement.recordEpochRevenue(vaultId, EPOCH, NET_REVENUE, 0, 0, ASSET_PRICE, 0);
        _endCurrentEpoch();
        settlement.settleEpochRevenue(vaultId, EPOCH);

        vm.expectRevert(abi.encodeWithSelector(SharedSettlementEngine.EpochAlreadySettled.selector, vaultId, EPOCH));
        settlement.recordEpochRevenue(vaultId, EPOCH, NET_REVENUE, 0, 0, 0, 0);
        vm.stopPrank();
    }

    // ─── settleEpochRevenue ────────────────────────────────────────────────

    function test_settleEpochRevenue_marksSettled() public {
        vm.startPrank(admin);
        settlement.recordEpochRevenue(vaultId, EPOCH, NET_REVENUE, 0, 0, ASSET_PRICE, 0);
        _endCurrentEpoch();
        settlement.settleEpochRevenue(vaultId, EPOCH);
        vm.stopPrank();

        SharedSettlementEngine.EpochRevenue memory r = settlement.getEpochRevenue(vaultId, EPOCH);
        assertTrue(r.isSettled);
    }

    function test_settleEpochRevenue_updatesRetainedEarnings() public {
        vm.startPrank(admin);
        settlement.recordEpochRevenue(vaultId, EPOCH, NET_REVENUE, 0, 0, ASSET_PRICE, 0);
        _endCurrentEpoch();
        settlement.settleEpochRevenue(vaultId, EPOCH);
        vm.stopPrank();

        SharedSettlementEngine.NAVComponents memory n = settlement.getNav(vaultId);
        assertEq(n.retainedEarnings, NET_REVENUE);
    }

    function test_settleEpochRevenue_revertsEpochNotFound() public {
        vm.prank(admin);
        vm.expectRevert(
            abi.encodeWithSelector(SharedSettlementEngine.EpochRevenueNotFound.selector, vaultId, uint256(99))
        );
        settlement.settleEpochRevenue(vaultId, 99);
    }

    // ─── distributeRevenueToVault ──────────────────────────────────────────

    function _settled() internal {
        _endCurrentEpoch();
        vm.startPrank(admin);
        settlement.recordEpochRevenue(vaultId, EPOCH, NET_REVENUE, 0, 0, ASSET_PRICE, 0);
        settlement.settleEpochRevenue(vaultId, EPOCH);
        vm.stopPrank();
    }

    function test_distributeRevenue_sendsFeeToTreasury() public {
        _settled();

        usdc.mint(admin, NET_REVENUE);
        vm.prank(admin);
        usdc.approve(address(settlement), NET_REVENUE);

        uint256 treasuryBefore = usdc.balanceOf(treasury);
        vm.prank(admin);
        settlement.distributeRevenueToVault(vaultId, EPOCH);

        uint256 expectedFee = (NET_REVENUE * 600) / 10_000;
        assertEq(usdc.balanceOf(treasury) - treasuryBefore, expectedFee);
    }

    function test_distributeRevenue_sendsNetToFacility() public {
        _settled();

        usdc.mint(admin, NET_REVENUE);
        vm.prank(admin);
        usdc.approve(address(settlement), NET_REVENUE);

        uint256 facilityBefore = usdc.balanceOf(facilityAddr);
        vm.prank(admin);
        settlement.distributeRevenueToVault(vaultId, EPOCH);

        uint256 fee = (NET_REVENUE * 600) / 10_000;
        uint256 net = NET_REVENUE - fee;
        assertEq(usdc.balanceOf(facilityAddr) - facilityBefore, net);
    }

    function test_distributeRevenue_mintsAssetToVault() public {
        _settled();

        usdc.mint(admin, NET_REVENUE);
        vm.prank(admin);
        usdc.approve(address(settlement), NET_REVENUE);

        uint256 vaultAssetBefore = assetToken.balanceOf(vaultAddr);
        vm.prank(admin);
        settlement.distributeRevenueToVault(vaultId, EPOCH);

        assertGt(assetToken.balanceOf(vaultAddr) - vaultAssetBefore, 0);
    }

    function test_distributeRevenue_zerosNetRevenue() public {
        _settled();

        usdc.mint(admin, NET_REVENUE);
        vm.prank(admin);
        usdc.approve(address(settlement), NET_REVENUE);

        vm.prank(admin);
        settlement.distributeRevenueToVault(vaultId, EPOCH);

        SharedSettlementEngine.EpochRevenue memory r = settlement.getEpochRevenue(vaultId, EPOCH);
        assertEq(r.netRevenue, 0);
    }

    function test_distributeRevenue_revertsNotSettled() public {
        vm.startPrank(admin);
        settlement.recordEpochRevenue(vaultId, EPOCH, NET_REVENUE, 0, 0, 0, 0);
        // NOT calling settleEpochRevenue

        usdc.mint(admin, NET_REVENUE);
        usdc.approve(address(settlement), NET_REVENUE);

        vm.expectRevert(abi.encodeWithSelector(SharedSettlementEngine.EpochNotSettled.selector, vaultId, EPOCH));
        settlement.distributeRevenueToVault(vaultId, EPOCH);
        vm.stopPrank();
    }

    function test_distributeRevenue_revertsDoubleDistribution() public {
        _settled();

        usdc.mint(admin, NET_REVENUE * 2);
        vm.startPrank(admin);
        usdc.approve(address(settlement), NET_REVENUE * 2);
        settlement.distributeRevenueToVault(vaultId, EPOCH);

        vm.expectRevert(abi.encodeWithSelector(SharedSettlementEngine.NoRevenueToDistribute.selector, vaultId, EPOCH));
        settlement.distributeRevenueToVault(vaultId, EPOCH);
        vm.stopPrank();
    }

    // ─── NAV ──────────────────────────────────────────────────────────────

    function test_updateNAV_stores() public {
        _mintAsset(vaultAddr, 100_000e6);

        SharedSettlementEngine.NAVComponents memory nav = SharedSettlementEngine.NAVComponents({
            assetInInventory: 100_000e6,
            assetSpotPrice: ASSET_PRICE,
            assetInTransit: 5_000e6,
            retainedEarnings: 500e6,
            stablecoinBalance: 1000e6,
            liabilities: 200e6
        });

        vm.prank(admin);
        settlement.updateNAV(vaultId, nav);

        SharedSettlementEngine.NAVComponents memory stored = settlement.getNav(vaultId);
        assertEq(stored.assetInInventory, 100_000e6);
        assertEq(stored.liabilities, 200e6);
        // FIND-030: calldata retainedEarnings is ignored while storage is still 0.
        assertEq(stored.retainedEarnings, 0);
    }

    function test_updateNAV_preservesRetainedEarnings() public {
        _settled();

        SharedSettlementEngine.NAVComponents memory beforeNav = settlement.getNav(vaultId);
        assertEq(beforeNav.retainedEarnings, NET_REVENUE);

        SharedSettlementEngine.NAVComponents memory nav = SharedSettlementEngine.NAVComponents({
            assetInInventory: 100_000e6,
            assetSpotPrice: ASSET_PRICE,
            assetInTransit: 0,
            retainedEarnings: 0, // would wipe without FIND-030 guard
            stablecoinBalance: 1000e6,
            liabilities: 0
        });

        vm.prank(admin);
        settlement.updateNAV(vaultId, nav);

        SharedSettlementEngine.NAVComponents memory stored = settlement.getNav(vaultId);
        assertEq(stored.retainedEarnings, NET_REVENUE);
        assertEq(stored.stablecoinBalance, 1000e6);
    }

    function test_getNAVSummary_returnsPositiveValues() public {
        _mintAsset(vaultAddr, 100_000e6);

        SharedSettlementEngine.NAVComponents memory nav = SharedSettlementEngine.NAVComponents({
            assetInInventory: 100_000e6,
            assetSpotPrice: ASSET_PRICE,
            assetInTransit: 0,
            retainedEarnings: 0,
            stablecoinBalance: 0,
            liabilities: 0
        });

        vm.prank(admin);
        settlement.updateNAV(vaultId, nav);

        settlement.getNAVSummary(vaultId); // must not revert
    }

    function test_getNAVSummary_scalesAssetValueToSettlementDecimals() public {
        MockERC20 dai = new MockERC20("DAI", "DAI", 18);

        vm.startPrank(admin);
        (uint256 daiVaultId, address daiVaultAddr, , ) = factory.createVault(
            VaultFactory.CreateVaultParams({
                assetToken: address(assetToken),
                settlementToken: address(dai),
                assetOracle: address(assetOracle),
                uniswapRouter: address(uniswapRouter),
                useEpochs: true,
                epochDuration: 600,
                wethToken: weth,
                vaultName: "xDAI",
                vaultSymbol: "xDAI",
                operator: address(0),
                treasury: treasury,
                reportedInventoryOnly: false
            })
        );
        vm.stopPrank();

        _mintAsset(daiVaultAddr, 1e6);

        SharedSettlementEngine.NAVComponents memory nav = SharedSettlementEngine.NAVComponents({
            assetInInventory: 1e6,
            assetSpotPrice: 100_000_000,
            assetInTransit: 0,
            retainedEarnings: 0,
            stablecoinBalance: 0,
            liabilities: 0
        });

        vm.prank(admin);
        settlement.updateNAV(daiVaultId, nav);

        (uint256 totalAssets, , ) = settlement.getNAVSummary(daiVaultId);
        assertEq(totalAssets, 1e18);
    }

    // ─── getLastSettledEpoch ───────────────────────────────────────────────

    function test_getLastSettledEpoch_returnsCorrect() public {
        vm.startPrank(admin);
        settlement.recordEpochRevenue(vaultId, 1, NET_REVENUE, 0, 0, ASSET_PRICE, 0);
        _endCurrentEpoch();
        settlement.settleEpochRevenue(vaultId, 1);
        settlement.recordEpochRevenue(vaultId, 2, NET_REVENUE, 0, 0, ASSET_PRICE, 0);
        // epoch 2 is NOT settled
        vm.stopPrank();

        (SharedSettlementEngine.EpochRevenue memory r, bool found) = settlement.getLastSettledEpochRevenue(vaultId, 2);

        assertTrue(found);
        assertEq(r.epochId, 1);
    }

    function test_getLastSettledEpoch_notFoundReturnsEmpty() public {
        (, bool found) = settlement.getLastSettledEpochRevenue(vaultId, 3);
        assertFalse(found);
    }

    // ─── Multi-vault isolation ─────────────────────────────────────────────

    function test_multiVault_epochsIsolated() public {
        vm.startPrank(admin);
        // vault 2
        MockERC20v2 at2 = new MockERC20v2();
        (uint256 vid2, , , ) = factory.createVault(
            VaultFactory.CreateVaultParams({
                assetToken: address(at2),
                settlementToken: address(usdc),
                assetOracle: address(assetOracle),
                uniswapRouter: address(uniswapRouter),
                useEpochs: true,
                epochDuration: 600,
                wethToken: weth,
                vaultName: "xAT2",
                vaultSymbol: "xAT2",
                operator: address(0),
                treasury: treasury,
                reportedInventoryOnly: false
            })
        );

        settlement.recordEpochRevenue(vaultId, 1, NET_REVENUE, 0, 0, 0, 0);
        settlement.recordEpochRevenue(vid2, 1, NET_REVENUE * 2, 0, 0, 0, 0);
        vm.stopPrank();

        SharedSettlementEngine.EpochRevenue memory r1 = settlement.getEpochRevenue(vaultId, 1);
        SharedSettlementEngine.EpochRevenue memory r2 = settlement.getEpochRevenue(vid2, 1);

        assertEq(r1.netRevenue, NET_REVENUE);
        assertEq(r2.netRevenue, NET_REVENUE * 2);
    }

    // ─── Admin ────────────────────────────────────────────────────────────

    function test_setSystemFee() public {
        vm.prank(admin);
        settlement.setSystemFee(300); // 3%
        assertEq(settlement.systemFeeBps(), 300);
    }

    function test_setSystemFee_revertsAbove100Percent() public {
        vm.prank(admin);
        vm.expectRevert(SharedSettlementEngine.InvalidSystemFee.selector);
        settlement.setSystemFee(10_001);
    }

    function test_pause_blocksRecord() public {
        vm.prank(admin);
        settlement.pause();

        vm.prank(admin);
        vm.expectRevert();
        settlement.recordEpochRevenue(vaultId, EPOCH, NET_REVENUE, 0, 0, 0, 0);
    }

    // ─── Multi-recipient fee distribution (CommissionTransfer pattern) ────

    function test_setFeeDistribution_storesRecipients() public {
        SharedSettlementEngine.FeeRecipient[] memory r = new SharedSettlementEngine.FeeRecipient[](2);
        r[0] = SharedSettlementEngine.FeeRecipient({recipient: makeAddr("rec1"), bps: 7000});
        r[1] = SharedSettlementEngine.FeeRecipient({recipient: makeAddr("rec2"), bps: 3000});

        vm.prank(admin);
        settlement.setFeeDistribution(r);

        SharedSettlementEngine.FeeRecipient[] memory stored = settlement.getFeeRecipients();
        assertEq(stored.length, 2);
        assertEq(stored[0].bps, 7000);
        assertEq(stored[1].bps, 3000);
    }

    function test_setFeeDistribution_revertsIfBpsExceeds10000() public {
        SharedSettlementEngine.FeeRecipient[] memory r = new SharedSettlementEngine.FeeRecipient[](1);
        r[0] = SharedSettlementEngine.FeeRecipient({recipient: makeAddr("rec1"), bps: 10_001});

        vm.prank(admin);
        vm.expectRevert(SharedSettlementEngine.InvalidFeeDistribution.selector);
        settlement.setFeeDistribution(r);
    }

    function test_distributeRevenue_withMultiRecipients_splitsFee() public {
        address rec1 = makeAddr("rec1");
        address rec2 = makeAddr("rec2");

        SharedSettlementEngine.FeeRecipient[] memory recipients = new SharedSettlementEngine.FeeRecipient[](2);
        recipients[0] = SharedSettlementEngine.FeeRecipient({recipient: rec1, bps: 6000}); // 60% of fee
        recipients[1] = SharedSettlementEngine.FeeRecipient({recipient: rec2, bps: 4000}); // 40% of fee

        vm.startPrank(admin);
        settlement.setFeeDistribution(recipients);

        // Record + settle epoch
        settlement.recordEpochRevenue(vaultId, EPOCH, NET_REVENUE, 0, 0, ASSET_PRICE, 0);
        _endCurrentEpoch();
        settlement.settleEpochRevenue(vaultId, EPOCH);

        // Approve + distribute
        usdc.mint(admin, NET_REVENUE);
        usdc.approve(address(settlement), NET_REVENUE);
        settlement.distributeRevenueToVault(vaultId, EPOCH);
        vm.stopPrank();

        // systemFeeBps = 600 bps = 6%, fee = 10000e6 * 6% = 600e6
        // rec1 gets 60% of 600e6 = 360e6
        // rec2 gets 40% of 600e6 = 240e6
        uint256 expectedFee = (NET_REVENUE * 600) / 10_000; // 600e6
        assertEq(usdc.balanceOf(rec1), (expectedFee * 6000) / 10_000);
        assertEq(usdc.balanceOf(rec2), (expectedFee * 4000) / 10_000);
        // treasury gets 0 (100% of fee is distributed among recipients)
        assertEq(usdc.balanceOf(treasury), 0);
    }

    function test_distributeRevenue_withNoRecipients_goesToTreasury() public {
        vm.startPrank(admin);
        settlement.recordEpochRevenue(vaultId, EPOCH, NET_REVENUE, 0, 0, ASSET_PRICE, 0);
        _endCurrentEpoch();
        settlement.settleEpochRevenue(vaultId, EPOCH);

        usdc.mint(admin, NET_REVENUE);
        usdc.approve(address(settlement), NET_REVENUE);
        settlement.distributeRevenueToVault(vaultId, EPOCH);
        vm.stopPrank();

        uint256 expectedFee = (NET_REVENUE * 600) / 10_000;
        assertEq(usdc.balanceOf(treasury), expectedFee, "fee should go to treasury when no recipients");
    }

    function test_setFeeDistributor_pluggableModule() public {
        address distributor = makeAddr("distributor");

        vm.prank(admin);
        settlement.setFeeDistributor(distributor);

        assertEq(settlement.feeDistributor(), distributor);
    }

    function test_setFeeDistributor_clearWithZeroAddress() public {
        vm.startPrank(admin);
        settlement.setFeeDistributor(makeAddr("d"));
        settlement.setFeeDistributor(address(0)); // clear
        vm.stopPrank();

        assertEq(settlement.feeDistributor(), address(0));
    }

    // ─── EpochIdMismatch ──────────────────────────────────────────────────

    function test_settleEpochRevenue_revertsEpochIdMismatch() public {
        // EpochManager is at epoch 1 (advanced in Helpers setUp), record epoch 2 which doesn't match
        vm.startPrank(admin);
        settlement.recordEpochRevenue(vaultId, 2, NET_REVENUE, 0, 0, ASSET_PRICE, 0);

        _endCurrentEpoch();
        vm.expectRevert(
            abi.encodeWithSelector(SharedSettlementEngine.EpochIdMismatch.selector, uint256(1), uint256(2))
        );
        settlement.settleEpochRevenue(vaultId, 2);
        vm.stopPrank();
    }

    function test_settleEpochRevenue_revertsAlreadySettled() public {
        vm.startPrank(admin);
        settlement.recordEpochRevenue(vaultId, EPOCH, NET_REVENUE, 0, 0, ASSET_PRICE, 0);
        _endCurrentEpoch();
        settlement.settleEpochRevenue(vaultId, EPOCH);

        vm.expectRevert(abi.encodeWithSelector(SharedSettlementEngine.EpochAlreadySettled.selector, vaultId, EPOCH));
        settlement.settleEpochRevenue(vaultId, EPOCH);
        vm.stopPrank();
    }

    function test_settleEpochRevenue_revertsEpochNotFinished() public {
        vm.startPrank(admin);
        settlement.recordEpochRevenue(vaultId, EPOCH, NET_REVENUE, 0, 0, ASSET_PRICE, 0);
        vm.expectRevert(abi.encodeWithSelector(SharedSettlementEngine.EpochNotFinished.selector, vaultId));
        settlement.settleEpochRevenue(vaultId, EPOCH);
        vm.stopPrank();
    }

    // ─── rescueTokens ─────────────────────────────────────────────────────

    function test_rescueTokens_sendsToRecipient() public {
        usdc.mint(address(settlement), 100e6);

        uint256 before = usdc.balanceOf(admin);
        vm.prank(admin);
        settlement.rescueTokens(address(usdc), admin, 100e6);
        assertEq(usdc.balanceOf(admin) - before, 100e6);
        assertEq(usdc.balanceOf(address(settlement)), 0);
    }

    function test_rescueTokens_revertsZeroTo() public {
        usdc.mint(address(settlement), 100e6);
        vm.prank(admin);
        vm.expectRevert(SharedSettlementEngine.ZeroAddress.selector);
        settlement.rescueTokens(address(usdc), address(0), 100e6);
    }

    function test_rescueTokens_revertsUnauthorized() public {
        vm.prank(user);
        vm.expectRevert();
        settlement.rescueTokens(address(usdc), user, 1);
    }

    // ─── REVENUE_MANAGER_ROLE access guard ────────────────────────────────

    function test_recordEpochRevenue_revertsUnauthorized() public {
        vm.prank(user);
        vm.expectRevert();
        settlement.recordEpochRevenue(vaultId, EPOCH, NET_REVENUE, 0, 0, 0, 0);
    }

    function test_settleEpochRevenue_revertsUnauthorized() public {
        vm.prank(user);
        vm.expectRevert();
        settlement.settleEpochRevenue(vaultId, EPOCH);
    }

    // ─── reportedInventoryOnly ────────────────────────────────────────────

    function test_distribute_reportedInventoryOnly_zeroKeepsZero_ignoresVaultBalance() public {
        // Create epoch vault that never syncs inventory from vault.balanceOf
        vm.startPrank(admin);
        MockAccessControlMintable asset2 = new MockAccessControlMintable("Asset2", "AT2", 6);
        (uint256 vid, address vAddr, , address emAddr) = factory.createVault(
            VaultFactory.CreateVaultParams({
                assetToken: address(asset2),
                settlementToken: address(usdc),
                assetOracle: address(assetOracle),
                uniswapRouter: address(uniswapRouter),
                useEpochs: true,
                epochDuration: 600,
                wethToken: weth,
                vaultName: "xRPT",
                vaultSymbol: "xRPT",
                operator: address(0),
                treasury: treasury,
                reportedInventoryOnly: true
            })
        );
        assertTrue(registry.getVault(vid).reportedInventoryOnly);

        registry.authorizeVaultMint(vid);
        asset2.grantRole(asset2.MINTER_ROLE(), admin);
        asset2.grantRole(asset2.MINTER_ROLE(), address(settlement));

        EpochManager em = EpochManager(emAddr);
        em.grantRole(em.EPOCH_MANAGER_ROLE(), admin);
        vm.warp(block.timestamp + 601);
        em.nextEpoch();
        uint256 epochId = em.currentEpochId();

        // Pre-fund vault with asset liquidity that must NOT become warehouse inventory
        asset2.mint(vAddr, 50_000e6);

        // Manual warehouse = 0 via updateNAV (same path as v1 ops reporting)
        settlement.updateNAV(
            vid,
            SharedSettlementEngine.NAVComponents({
                assetInInventory: 0,
                assetSpotPrice: ASSET_PRICE,
                assetInTransit: 0,
                retainedEarnings: 0,
                stablecoinBalance: 0,
                liabilities: 0
            })
        );

        settlement.recordEpochRevenue(vid, epochId, NET_REVENUE, 0, 0, ASSET_PRICE, 0);
        vm.warp(block.timestamp + em.epochDuration() + 1);
        settlement.settleEpochRevenue(vid, epochId);

        usdc.mint(admin, NET_REVENUE);
        usdc.approve(address(settlement), NET_REVENUE);
        settlement.distributeRevenueToVault(vid, epochId);
        vm.stopPrank();

        // Zero warehouse preserved — vault balance (50k + minted) is ignored
        assertEq(settlement.getNav(vid).assetInInventory, 0);
        assertGt(asset2.balanceOf(vAddr), 50_000e6);
    }

    function test_distribute_reportedInventoryOnly_preservesUpdateNAVAmount() public {
        vm.startPrank(admin);
        MockAccessControlMintable asset2 = new MockAccessControlMintable("Asset2b", "AT2b", 6);
        (uint256 vid, address vAddr, , address emAddr) = factory.createVault(
            VaultFactory.CreateVaultParams({
                assetToken: address(asset2),
                settlementToken: address(usdc),
                assetOracle: address(assetOracle),
                uniswapRouter: address(uniswapRouter),
                useEpochs: true,
                epochDuration: 600,
                wethToken: weth,
                vaultName: "xRPT2",
                vaultSymbol: "xRPT2",
                operator: address(0),
                treasury: treasury,
                reportedInventoryOnly: true
            })
        );

        registry.authorizeVaultMint(vid);
        asset2.grantRole(asset2.MINTER_ROLE(), admin);
        asset2.grantRole(asset2.MINTER_ROLE(), address(settlement));

        EpochManager em = EpochManager(emAddr);
        em.grantRole(em.EPOCH_MANAGER_ROLE(), admin);
        vm.warp(block.timestamp + 601);
        em.nextEpoch();
        uint256 epochId = em.currentEpochId();

        asset2.mint(vAddr, 99_999e6); // would overwrite inventory on a default vault

        settlement.updateNAV(
            vid,
            SharedSettlementEngine.NAVComponents({
                assetInInventory: 12_345e6,
                assetSpotPrice: ASSET_PRICE,
                assetInTransit: 0,
                retainedEarnings: 0,
                stablecoinBalance: 0,
                liabilities: 0
            })
        );

        settlement.recordEpochRevenue(vid, epochId, NET_REVENUE, 0, 0, ASSET_PRICE, 0);
        vm.warp(block.timestamp + em.epochDuration() + 1);
        settlement.settleEpochRevenue(vid, epochId);

        usdc.mint(admin, NET_REVENUE);
        usdc.approve(address(settlement), NET_REVENUE);
        settlement.distributeRevenueToVault(vid, epochId);
        vm.stopPrank();

        assertEq(settlement.getNav(vid).assetInInventory, 12_345e6);
    }

    function test_distribute_defaultVault_syncsInventoryFromVaultBalance() public {
        _settled();

        usdc.mint(admin, NET_REVENUE);
        vm.startPrank(admin);
        usdc.approve(address(settlement), NET_REVENUE);
        settlement.distributeRevenueToVault(vaultId, EPOCH);
        vm.stopPrank();

        uint256 vaultBal = assetToken.balanceOf(vaultAddr);
        assertEq(settlement.getNav(vaultId).assetInInventory, vaultBal);
        assertGt(vaultBal, 0);
    }
}

import {MockERC20} from "./Helpers.sol";

// Tiny stub to avoid import cycle
contract MockERC20v2 {
    string public name = "Asset2";
    string public symbol = "AT2";
    uint8 public decimals = 6;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    uint256 public totalSupply;
    function mint(address to, uint256 a) external {
        balanceOf[to] += a;
        totalSupply += a;
    }
    function transfer(address to, uint256 a) external returns (bool) {
        balanceOf[msg.sender] -= a;
        balanceOf[to] += a;
        return true;
    }
    function transferFrom(address from, address to, uint256 a) external returns (bool) {
        if (allowance[from][msg.sender] != type(uint256).max) allowance[from][msg.sender] -= a;
        balanceOf[from] -= a;
        balanceOf[to] += a;
        return true;
    }
    function approve(address s, uint256 a) external returns (bool) {
        allowance[msg.sender][s] = a;
        return true;
    }
    function forceApprove(address s, uint256 a) external {
        allowance[msg.sender][s] = a;
    }
}
