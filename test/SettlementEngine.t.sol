// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";

import {Upgrades} from "openzeppelin-foundry-upgrades/Upgrades.sol";

import {SettlementEngine} from "../contracts/SettlementEngine.sol";
import {CUPToken} from "../contracts/CUPToken.sol";
import {xCUP} from "../contracts/xCUP.sol";
import {EpochManager, IEpochManager} from "../contracts/EpochManager.sol";
import {CopperPriceConsumerMock} from "../contracts/mock/CopperPriceConsumerMock.sol";
import {ERC20Mock} from "../contracts/mock/ERC20Mock.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/**
 * @title SettlementEngine Test Suite
 * @notice Comprehensive test suite for SettlementEngine contract
 * @dev Tests all major functionality including NAV management, revenue recording,
 *      settlement, distribution, analytics, and edge cases for audit readiness.
 */

contract SettlementEngineTest is Test {
    SettlementEngine internal settlementEngine;
    CUPToken internal cupToken;
    xCUP internal vault;
    IEpochManager internal epochManager;
    CopperPriceConsumerMock internal priceConsumer;
    ERC20Mock internal usdc;

    address internal owner;
    address internal treasury;
    address internal user1;
    address internal user2;
    address internal unauthorized;

    uint256 internal constant EPOCH_DURATION = 30 days;
    uint256 internal constant SYSTEM_FEE_BPS = 500; // 5%
    uint256 internal constant INITIAL_COPPER_PRICE = 450000000; // $4.50 with 8 decimals
    uint256 internal constant BASIS_POINTS = 10000;

    // NAV test data
    uint256 internal constant CUP_IN_WAREHOUSE = 1000000e6; // 1M CUP
    uint256 internal constant CUP_IN_TRANSIT = 500000e6; // 500K CUP
    uint256 internal constant RETAINED_EARNINGS = 100000e6; // 100K USDC
    uint256 internal constant STABLECOIN_BALANCE = 50000e6; // 50K USDC
    uint256 internal constant LIABILITIES = 25000e6; // 25K USDC

    event NAVUpdated(uint256 totalNAV, uint256 pricePerShare);
    event EpochRevenueRecorded(uint256 indexed epochId, uint256 netRevenue, uint256 cupProcessed);
    event CopperOperationCompleted(uint256 indexed epochId, uint256 cupPurchased, uint256 cupSold, uint256 netRevenue);
    event RevenueDistributed(
        uint256 indexed epochId,
        uint256 revenueDistributed,
        uint256 distributedCupTokens,
        uint256 systemFee
    );

    function setUp() public {
        owner = address(this);
        treasury = makeAddr("treasury");
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

        // Deploy USDC mock
        usdc = new ERC20Mock("USDC", "USDC", 6);

        // Deploy price consumer mock
        priceConsumer = new CopperPriceConsumerMock();
        priceConsumer.setPrice(INITIAL_COPPER_PRICE);

        // Deploy EpochManager
        address epochManagerProxy = Upgrades.deployTransparentProxy(
            "EpochManager.sol:EpochManager",
            owner,
            abi.encodeCall(EpochManager.initialize, (EPOCH_DURATION))
        );
        epochManager = IEpochManager(epochManagerProxy);

        // Deploy xCUP vault
        address vaultProxy = Upgrades.deployTransparentProxy(
            "xCUP.sol:xCUP",
            owner,
            abi.encodeCall(xCUP.initialize, (IERC20(address(cupToken)), "xCUP Vault", "xCUP"))
        );
        vault = xCUP(vaultProxy);

        // Deploy SettlementEngine
        address settlementEngineProxy = Upgrades.deployTransparentProxy(
            "SettlementEngine.sol:SettlementEngine",
            owner,
            abi.encodeCall(
                SettlementEngine.initialize,
                (address(vault), treasury, address(0), address(epochManager), address(priceConsumer), address(usdc), SYSTEM_FEE_BPS)
            )
        );
        settlementEngine = SettlementEngine(settlementEngineProxy);

        // Setup roles and permissions
        cupToken.grantRole(cupToken.MINTER_ROLE(), address(settlementEngine));
        cupToken.grantRole(cupToken.BURNER_ROLE(), address(settlementEngine));

        // Mint some tokens for testing
        usdc.mint(owner, 10000000e6); // 10M USDC
        usdc.mint(address(settlementEngine), 1000000e6); // 1M USDC
        cupToken.grantRole(cupToken.MINTER_ROLE(), owner);
        cupToken.mint(address(vault), 1000000e6); // 1M CUP in vault
    }

    function testInitialState() public {
        assertEq(address(settlementEngine._vault()), address(vault));
        assertEq(settlementEngine._treasury(), treasury);
        assertEq(address(settlementEngine._epochManager()), address(epochManager));
        assertEq(address(settlementEngine._copperPriceConsumer()), address(priceConsumer));
        assertEq(settlementEngine._systemFeeBps(), SYSTEM_FEE_BPS);
        assertEq(settlementEngine._currentEpochId(), 0);
        assertEq(settlementEngine.owner(), owner);
        assertFalse(settlementEngine.paused());
    }

    function testUpdateNAV() public {
        SettlementEngine.NAVComponents memory nav = SettlementEngine.NAVComponents({
            cupInWarehouse: CUP_IN_WAREHOUSE,
            copperSpotPrice: INITIAL_COPPER_PRICE,
            cupInTransit: CUP_IN_TRANSIT,
            retainedEarnings: RETAINED_EARNINGS,
            stablecoinBalance: STABLECOIN_BALANCE,
            liabilities: LIABILITIES
        });

        // Calculate expected values
        uint256 copperAssetValue = (CUP_IN_WAREHOUSE + CUP_IN_TRANSIT) * INITIAL_COPPER_PRICE;
        uint256 totalAssets = copperAssetValue + RETAINED_EARNINGS + STABLECOIN_BALANCE;
        uint256 netAssets = totalAssets - LIABILITIES;
        uint256 supply = vault.totalSupply();
        uint256 pricePerShare = supply == 0 ? 1e18 : (netAssets * 1e18) / supply;

        vm.expectEmit(false, false, false, true);
        emit NAVUpdated(netAssets, pricePerShare);

        settlementEngine.updateNAV(nav);

        // Verify NAV was stored
        (
            uint256 storedCupInWarehouse,
            uint256 storedCopperSpotPrice,
            uint256 storedCupInTransit,
            uint256 storedRetainedEarnings,
            uint256 storedStablecoinBalance,
            uint256 storedLiabilities
        ) = settlementEngine._nav();

        assertEq(storedCupInWarehouse, CUP_IN_WAREHOUSE);
        assertEq(storedCopperSpotPrice, INITIAL_COPPER_PRICE);
        assertEq(storedCupInTransit, CUP_IN_TRANSIT);
        assertEq(storedRetainedEarnings, RETAINED_EARNINGS);
        assertEq(storedStablecoinBalance, STABLECOIN_BALANCE);
        assertEq(storedLiabilities, LIABILITIES);
    }

    function testUpdateNAVRevertNotOwner() public {
        SettlementEngine.NAVComponents memory nav = SettlementEngine.NAVComponents({
            cupInWarehouse: CUP_IN_WAREHOUSE,
            copperSpotPrice: INITIAL_COPPER_PRICE,
            cupInTransit: CUP_IN_TRANSIT,
            retainedEarnings: RETAINED_EARNINGS,
            stablecoinBalance: STABLECOIN_BALANCE,
            liabilities: LIABILITIES
        });

        vm.prank(unauthorized);
        vm.expectRevert();
        settlementEngine.updateNAV(nav);
    }

    function testRecordEpochRevenue() public {
        uint256 epochId = 1;
        uint256 netRevenue = 50000e6; // 50K USDC
        uint256 cupPurchased = 100000e6; // 100K CUP
        uint256 cupSold = 95000e6; // 95K CUP
        uint256 avgPurchasePrice = 4e8; // $4.00
        uint256 avgSalePrice = 5e8; // $5.00

        vm.expectEmit(true, false, false, true);
        emit EpochRevenueRecorded(epochId, netRevenue, cupSold);

        vm.expectEmit(true, false, false, true);
        emit CopperOperationCompleted(epochId, cupPurchased, cupSold, netRevenue);

        settlementEngine.recordEpochRevenue(epochId, netRevenue, cupPurchased, cupSold, avgPurchasePrice, avgSalePrice);

        SettlementEngine.EpochRevenue memory revenue = settlementEngine.getEpochRevenue(epochId);
        assertEq(revenue.epochId, epochId);
        assertEq(revenue.netRevenue, netRevenue);
        assertEq(revenue.originalNetRevenue, netRevenue);
        assertEq(revenue.cupPurchased, cupPurchased);
        assertEq(revenue.cupSold, cupSold);
        assertEq(revenue.averagePurchasePrice, avgPurchasePrice);
        assertEq(revenue.averageSalePrice, avgSalePrice);
        assertFalse(revenue.isSettled);
    }

    function testRecordEpochRevenueRevertInvalidEpochId() public {
        vm.expectRevert(SettlementEngine.ZeroEpochId.selector);
        settlementEngine.recordEpochRevenue(0, 50000e6, 100000e6, 95000e6, 4e8, 5e8);
    }

    function testRecordEpochRevenueRevertZeroRevenue() public {
        vm.expectRevert(SettlementEngine.ZeroNetRevenue.selector);
        settlementEngine.recordEpochRevenue(1, 0, 100000e6, 95000e6, 4e8, 5e8);
    }

    function testRecordEpochRevenueRevertAlreadySettled() public {
        uint256 epochId = 1;

        // Record and settle first
        settlementEngine.recordEpochRevenue(epochId, 50000e6, 100000e6, 95000e6, 4e8, 5e8);
        settlementEngine.settleEpochRevenue(epochId);

        // Try to record again
        vm.expectRevert(SettlementEngine.EpochAlreadySettled.selector);
        settlementEngine.recordEpochRevenue(epochId, 60000e6, 110000e6, 105000e6, 4e8, 5e8);
    }

    function testSettleEpochRevenue() public {
        uint256 epochId = 1;
        uint256 netRevenue = 50000e6;

        // Record revenue first
        settlementEngine.recordEpochRevenue(epochId, netRevenue, 100000e6, 95000e6, 4e8, 5e8);

        // Settle revenue
        settlementEngine.settleEpochRevenue(epochId);

        SettlementEngine.EpochRevenue memory revenue = settlementEngine.getEpochRevenue(epochId);
        assertTrue(revenue.isSettled);

        // Check that retained earnings were updated
        (, , , uint256 retainedEarnings, , ) = settlementEngine._nav();
        assertEq(retainedEarnings, netRevenue);
    }

    function testSettleEpochRevenueRevertNotFound() public {
        vm.expectRevert(SettlementEngine.EpochRevenueNotFound.selector);
        settlementEngine.settleEpochRevenue(999);
    }

    function testSettleEpochRevenueRevertAlreadySettled() public {
        uint256 epochId = 1;

        settlementEngine.recordEpochRevenue(epochId, 50000e6, 100000e6, 95000e6, 4e8, 5e8);
        settlementEngine.settleEpochRevenue(epochId);

        vm.expectRevert(SettlementEngine.EpochAlreadySettled.selector);
        settlementEngine.settleEpochRevenue(epochId);
    }

    function testCalculateEpochROI() public {
        uint256 epochId = 1;
        uint256 netRevenue = 50000e6;
        uint256 cupPurchased = 100000e6;
        uint256 avgPurchasePrice = 4e8; // $4.00

        settlementEngine.recordEpochRevenue(epochId, netRevenue, cupPurchased, 95000e6, avgPurchasePrice, 5e8);

        uint256 roi = settlementEngine.calculateEpochROI(epochId);

        // Expected ROI = (50000e6 * 10000) / (100000e6 * 4e8) = 1250 basis points = 12.5%
        uint256 expectedROI = (netRevenue * BASIS_POINTS) / (cupPurchased * avgPurchasePrice);
        assertEq(roi, expectedROI);
    }

    function testCalculateEpochROIZeroPurchased() public {
        uint256 epochId = 1;

        settlementEngine.recordEpochRevenue(epochId, 50000e6, 0, 95000e6, 4e8, 5e8);

        uint256 roi = settlementEngine.calculateEpochROI(epochId);
        assertEq(roi, 0);
    }

    function testGetNAVSummary() public {
        // Update NAV first
        SettlementEngine.NAVComponents memory nav = SettlementEngine.NAVComponents({
            cupInWarehouse: CUP_IN_WAREHOUSE,
            copperSpotPrice: INITIAL_COPPER_PRICE,
            cupInTransit: CUP_IN_TRANSIT,
            retainedEarnings: RETAINED_EARNINGS,
            stablecoinBalance: STABLECOIN_BALANCE,
            liabilities: LIABILITIES
        });
        settlementEngine.updateNAV(nav);

        (uint256 totalAssets, uint256 netAssets, uint256 pricePerShare) = settlementEngine.getNAVSummary();

        uint256 expectedCopperValue = (CUP_IN_WAREHOUSE + CUP_IN_TRANSIT) * INITIAL_COPPER_PRICE;
        uint256 expectedTotalAssets = expectedCopperValue + RETAINED_EARNINGS + STABLECOIN_BALANCE;
        uint256 expectedNetAssets = expectedTotalAssets - LIABILITIES;

        assertEq(totalAssets, expectedTotalAssets);
        assertEq(netAssets, expectedNetAssets);
        assertGt(pricePerShare, 0);
    }

    function testAdvanceEpoch() public {
        uint256 initialEpochId = settlementEngine._currentEpochId();

        settlementEngine.advanceEpoch();

        assertEq(settlementEngine._currentEpochId(), initialEpochId + 1);
    }

    function testAdvanceEpochRevertNotOwner() public {
        vm.prank(unauthorized);
        vm.expectRevert();
        settlementEngine.advanceEpoch();
    }

    function testGetCopperProcessingEfficiency() public {
        uint256 epochId = 1;
        uint256 cupPurchased = 100000e6;
        uint256 cupSold = 95000e6;

        settlementEngine.recordEpochRevenue(epochId, 50000e6, cupPurchased, cupSold, 4e8, 5e8);

        uint256 efficiency = settlementEngine.getCopperProcessingEfficiency(epochId);

        // Expected efficiency = (95000e6 * 10000) / 100000e6 = 9500 basis points = 95%
        uint256 expectedEfficiency = (cupSold * BASIS_POINTS) / cupPurchased;
        assertEq(efficiency, expectedEfficiency);
    }

    function testGetCopperProcessingEfficiencyZeroPurchased() public {
        uint256 epochId = 1;

        settlementEngine.recordEpochRevenue(epochId, 50000e6, 0, 95000e6, 4e8, 5e8);

        uint256 efficiency = settlementEngine.getCopperProcessingEfficiency(epochId);
        assertEq(efficiency, 0);
    }

    function testGetProfitMargin() public {
        uint256 epochId = 1;
        uint256 netRevenue = 50000e6;
        uint256 cupSold = 95000e6;
        uint256 avgSalePrice = 5e8;

        settlementEngine.recordEpochRevenue(epochId, netRevenue, 100000e6, cupSold, 4e8, avgSalePrice);

        uint256 margin = settlementEngine.getProfitMargin(epochId);

        // Expected margin = (50000e6 * 10000) / (95000e6 * 5e8)
        uint256 totalSalesValue = cupSold * avgSalePrice;
        uint256 expectedMargin = (netRevenue * BASIS_POINTS) / totalSalesValue;
        assertEq(margin, expectedMargin);
    }

    function testGetProfitMarginZeroSold() public {
        uint256 epochId = 1;

        settlementEngine.recordEpochRevenue(epochId, 50000e6, 100000e6, 0, 4e8, 5e8);

        uint256 margin = settlementEngine.getProfitMargin(epochId);
        assertEq(margin, 0);
    }

    function testDistributeRevenueToVault() public {
        uint256 epochId = 1;
        uint256 netRevenue = 50000e6;

        // Setup: record and settle revenue
        settlementEngine.recordEpochRevenue(epochId, netRevenue, 100000e6, 95000e6, 4e8, 5e8);
        settlementEngine.settleEpochRevenue(epochId);

        // Approve USDC transfer
        usdc.approve(address(settlementEngine), netRevenue);

        // Calculate expected values
        uint256 systemFee = (netRevenue * SYSTEM_FEE_BPS) / BASIS_POINTS;
        uint256 netRevenueAfterFees = netRevenue - systemFee;
        // uint256 copperPriceUSD = priceConsumer.getPriceAsDecimal();
        uint256 expectedCupTokens = (netRevenueAfterFees * 1e8) / INITIAL_COPPER_PRICE;

        vm.expectEmit(true, false, false, true);
        emit RevenueDistributed(epochId, netRevenueAfterFees, expectedCupTokens, systemFee);

        settlementEngine.distributeRevenueToVault(epochId);

        // Verify revenue was zeroed out
        SettlementEngine.EpochRevenue memory revenue = settlementEngine.getEpochRevenue(epochId);
        assertEq(revenue.netRevenue, 0);

        // Verify fees were recorded
        uint256 recordedFees = settlementEngine.getEpochFees(epochId);
        assertEq(recordedFees, systemFee);
    }

    function testDistributeRevenueToVaultRevertNotSettled() public {
        uint256 epochId = 1;

        settlementEngine.recordEpochRevenue(epochId, 50000e6, 100000e6, 95000e6, 4e8, 5e8);

        vm.expectRevert(SettlementEngine.EpochNotSettled.selector);
        settlementEngine.distributeRevenueToVault(epochId);
    }

    function testDistributeRevenueToVaultRevertNotFound() public {
        vm.expectRevert(SettlementEngine.EpochRevenueNotFound.selector);
        settlementEngine.distributeRevenueToVault(999);
    }

    function testGetCurrentEpochRevenue() public {
        // uint256 currentEpochId = settlementEngine._currentEpochId();

        // Should return empty revenue for current epoch initially
        SettlementEngine.EpochRevenue memory revenue = settlementEngine.getCurrentEpochRevenue();
        assertEq(revenue.epochId, 0);
        assertEq(revenue.netRevenue, 0);
    }

    function testPauseAndUnpause() public {
        settlementEngine.pause();
        assertTrue(settlementEngine.paused());

        settlementEngine.unpause();
        assertFalse(settlementEngine.paused());
    }

    function testPauseRevertNotOwner() public {
        vm.prank(unauthorized);
        vm.expectRevert();
        settlementEngine.pause();
    }

    function testUnpauseRevertNotOwner() public {
        settlementEngine.pause();

        vm.prank(unauthorized);
        vm.expectRevert();
        settlementEngine.unpause();
    }

    function testNAVWithZeroLiabilities() public {
        SettlementEngine.NAVComponents memory nav = SettlementEngine.NAVComponents({
            cupInWarehouse: CUP_IN_WAREHOUSE,
            copperSpotPrice: INITIAL_COPPER_PRICE,
            cupInTransit: CUP_IN_TRANSIT,
            retainedEarnings: RETAINED_EARNINGS,
            stablecoinBalance: STABLECOIN_BALANCE,
            liabilities: 0
        });

        settlementEngine.updateNAV(nav);

        (uint256 totalAssets, uint256 netAssets, uint256 pricePerShare) = settlementEngine.getNAVSummary();

        assertEq(netAssets, totalAssets); // No liabilities
        assertGt(pricePerShare, 0);
    }

    function testNAVWithHighLiabilities() public {
        uint256 highLiabilities = 1000000000e6; // Very high liabilities

        SettlementEngine.NAVComponents memory nav = SettlementEngine.NAVComponents({
            cupInWarehouse: CUP_IN_WAREHOUSE,
            copperSpotPrice: INITIAL_COPPER_PRICE,
            cupInTransit: CUP_IN_TRANSIT,
            retainedEarnings: RETAINED_EARNINGS,
            stablecoinBalance: STABLECOIN_BALANCE,
            liabilities: highLiabilities
        });

        settlementEngine.updateNAV(nav);

        (, uint256 netAssets,) = settlementEngine.getNAVSummary();

        assertEq(netAssets, 0); // Liabilities exceed assets
    }

    function testMultipleEpochsRevenue() public {
        // Record revenue for multiple epochs
        for (uint256 i = 1; i <= 3; i++) {
            settlementEngine.recordEpochRevenue(i, 50000e6 * i, 100000e6, 95000e6, 4e8, 5e8);
            settlementEngine.settleEpochRevenue(i);
        }

        // Verify all epochs are recorded
        for (uint256 i = 1; i <= 3; i++) {
            SettlementEngine.EpochRevenue memory revenue = settlementEngine.getEpochRevenue(i);
            assertEq(revenue.epochId, i);
            assertEq(revenue.netRevenue, 50000e6 * i);
            assertTrue(revenue.isSettled);
        }
    }

    function testZeroSystemFee() public {
        // Deploy with zero system fee
        address zeroFeeEngineProxy = Upgrades.deployTransparentProxy(
            "SettlementEngine.sol:SettlementEngine",
            owner,
            abi.encodeCall(
                SettlementEngine.initialize,
                (
                    address(vault),
                    treasury,
                    address(epochManager),
                    address(priceConsumer),
                    address(usdc),
                    0 // Zero fee
                )
            )
        );
        SettlementEngine zeroFeeEngine = SettlementEngine(zeroFeeEngineProxy);

        assertEq(zeroFeeEngine._systemFeeBps(), 0);
    }

    function testMaxSystemFee() public {
        // Deploy with maximum system fee (100%)
        address maxFeeEngineProxy = Upgrades.deployTransparentProxy(
            "SettlementEngine.sol:SettlementEngine",
            owner,
            abi.encodeCall(
                SettlementEngine.initialize,
                (
                    address(vault),
                    treasury,
                    address(epochManager),
                    address(priceConsumer),
                    address(usdc),
                    10000 // 100% fee
                )
            )
        );
        SettlementEngine maxFeeEngine = SettlementEngine(maxFeeEngineProxy);

        assertEq(maxFeeEngine._systemFeeBps(), 10000);
    }

    function testInitializeRevertInvalidAddresses() public {
        vm.expectRevert(SettlementEngine.InvalidVaultAddress.selector);
        Upgrades.deployTransparentProxy(
            "SettlementEngine.sol:SettlementEngine",
            owner,
            abi.encodeCall(
                SettlementEngine.initialize,
                (address(0), treasury, address(0), address(epochManager), address(priceConsumer), address(usdc), SYSTEM_FEE_BPS)
            )
        );

        vm.expectRevert(SettlementEngine.InvalidTreasuryAddress.selector);
        Upgrades.deployTransparentProxy(
            "SettlementEngine.sol:SettlementEngine",
            owner,
            abi.encodeCall(
                SettlementEngine.initialize,
                (
                    address(vault),
                    address(0),
                    address(0),
                    address(epochManager),
                    address(priceConsumer),
                    address(usdc),
                    SYSTEM_FEE_BPS
                )
            )
        );

        vm.expectRevert(SettlementEngine.InvalidZapperAddress.selector);
        Upgrades.deployTransparentProxy(
            "SettlementEngine.sol:SettlementEngine",
            owner,
            abi.encodeCall(
                SettlementEngine.initialize,
                (address(vault), treasury, address(0), address(epochManager), address(priceConsumer), address(usdc), SYSTEM_FEE_BPS)
            )
        );

        vm.expectRevert(SettlementEngine.InvalidEpochManagerAddress.selector);
        Upgrades.deployTransparentProxy(
            "SettlementEngine.sol:SettlementEngine",
            owner,
            abi.encodeCall(
                SettlementEngine.initialize,
                (address(vault), treasury, address(epochManager), address(0), address(priceConsumer), address(usdc), SYSTEM_FEE_BPS)
            )
        );

        vm.expectRevert(SettlementEngine.InvalidCopperPriceConsumerAddress.selector);
        Upgrades.deployTransparentProxy(
            "SettlementEngine.sol:SettlementEngine",
            owner,
            abi.encodeCall(
                SettlementEngine.initialize,
                (address(vault), treasury, address(epochManager), address(epochManager), address(0), address(usdc), SYSTEM_FEE_BPS)
            )
        );

        vm.expectRevert(SettlementEngine.InvalidUSDCAddress.selector);
        Upgrades.deployTransparentProxy(
            "SettlementEngine.sol:SettlementEngine",
            owner,
            abi.encodeCall(
                SettlementEngine.initialize,
                (address(vault), treasury, address(epochManager), address(epochManager), address(priceConsumer), address(0), SYSTEM_FEE_BPS)
            )
        );
    }

    function testInitializeOnlyOnce() public {
        vm.expectRevert();
        settlementEngine.initialize(
            address(vault),
            treasury,
            address(0),
            address(epochManager),
            address(priceConsumer),
            address(usdc),
            SYSTEM_FEE_BPS
        );
    }

    // ============ Additional Security Tests ============

    function testRecordEpochRevenueRevertFutureEpoch() public {
        // Try to record revenue for a future epoch
        uint256 futureEpochId = _epochManager.currentEpochId() + 1;
        
        vm.expectRevert(SettlementEngine.FutureEpochId.selector);
        settlementEngine.recordEpochRevenue(futureEpochId, 50000e6, 100000e6, 95000e6, 4e8, 5e8);
    }

    function testRecordEpochRevenueRevertWhenPaused() public {
        settlementEngine.pause();
        
        vm.expectRevert();
        settlementEngine.recordEpochRevenue(1, 50000e6, 100000e6, 95000e6, 4e8, 5e8);
    }

    function testRecordEpochRevenueRevertUnauthorized() public {
        vm.prank(unauthorized);
        vm.expectRevert();
        settlementEngine.recordEpochRevenue(1, 50000e6, 100000e6, 95000e6, 4e8, 5e8);
    }

    function testSettleEpochRevenueRevertFutureEpoch() public {
        uint256 futureEpochId = _epochManager.currentEpochId() + 1;
        
        vm.expectRevert(SettlementEngine.FutureEpochId.selector);
        settlementEngine.settleEpochRevenue(futureEpochId);
    }

    function testSettleEpochRevenueRevertWhenPaused() public {
        uint256 epochId = 1;
        settlementEngine.recordEpochRevenue(epochId, 50000e6, 100000e6, 95000e6, 4e8, 5e8);
        
        settlementEngine.pause();
        
        vm.expectRevert();
        settlementEngine.settleEpochRevenue(epochId);
    }

    function testSettleEpochRevenueRevertUnauthorized() public {
        uint256 epochId = 1;
        settlementEngine.recordEpochRevenue(epochId, 50000e6, 100000e6, 95000e6, 4e8, 5e8);
        
        vm.prank(unauthorized);
        vm.expectRevert();
        settlementEngine.settleEpochRevenue(epochId);
    }

    function testDistributeRevenueToVaultRevertFutureEpoch() public {
        uint256 futureEpochId = _epochManager.currentEpochId() + 1;
        
        vm.expectRevert(SettlementEngine.FutureEpochId.selector);
        settlementEngine.distributeRevenueToVault(futureEpochId);
    }

    function testDistributeRevenueToVaultRevertWhenPaused() public {
        uint256 epochId = 1;
        settlementEngine.recordEpochRevenue(epochId, 50000e6, 100000e6, 95000e6, 4e8, 5e8);
        settlementEngine.settleEpochRevenue(epochId);
        
        settlementEngine.pause();
        
        vm.expectRevert();
        settlementEngine.distributeRevenueToVault(epochId);
    }

    function testDistributeRevenueToVaultRevertUnauthorized() public {
        uint256 epochId = 1;
        settlementEngine.recordEpochRevenue(epochId, 50000e6, 100000e6, 95000e6, 4e8, 5e8);
        settlementEngine.settleEpochRevenue(epochId);
        
        vm.prank(unauthorized);
        vm.expectRevert();
        settlementEngine.distributeRevenueToVault(epochId);
    }

    function testDistributeRevenueToVaultRevertInvalidCopperPrice() public {
        uint256 epochId = 1;
        settlementEngine.recordEpochRevenue(epochId, 50000e6, 100000e6, 95000e6, 4e8, 5e8);
        settlementEngine.settleEpochRevenue(epochId);
        
        // Set invalid copper price
        priceConsumer.setPrice(0);
        
        usdc.approve(address(settlementEngine), 50000e6);
        
        vm.expectRevert(SettlementEngine.InvalidCopperPrice.selector);
        settlementEngine.distributeRevenueToVault(epochId);
    }

    function testDistributeRevenueToVaultRevertDoubleDistribution() public {
        uint256 epochId = 1;
        uint256 netRevenue = 50000e6;
        
        settlementEngine.recordEpochRevenue(epochId, netRevenue, 100000e6, 95000e6, 4e8, 5e8);
        settlementEngine.settleEpochRevenue(epochId);
        
        // First distribution
        usdc.approve(address(settlementEngine), netRevenue);
        settlementEngine.distributeRevenueToVault(epochId);
        
        // Try to distribute again
        vm.expectRevert(SettlementEngine.NoRevenueToDistribute.selector);
        settlementEngine.distributeRevenueToVault(epochId);
    }

    // ============ Edge Case Tests ============

    function testNAVCalculationWithZeroSupply() public {
        // Test NAV calculation when vault has zero total supply
        SettlementEngine.NAVComponents memory nav = SettlementEngine.NAVComponents({
            cupInWarehouse: 0,
            copperSpotPrice: INITIAL_COPPER_PRICE,
            cupInTransit: 0,
            retainedEarnings: 100000e6,
            stablecoinBalance: 50000e6,
            liabilities: 0
        });
        
        settlementEngine.updateNAV(nav);
        
        (, uint256 netAssets, uint256 pricePerShare) = settlementEngine.getNAVSummary();
        
        assertEq(netAssets, 150000e6);
        assertEq(pricePerShare, 1e6); // Default price when supply is 0
    }

    function testLargeNumberCalculations() public {
        // Test with very large numbers to check for overflow
        uint256 epochId = 1;
        uint256 largeRevenue = type(uint128).max; // Large but safe number
        uint256 largeCupAmount = type(uint128).max;
        
        settlementEngine.recordEpochRevenue(epochId, largeRevenue, largeCupAmount, largeCupAmount, 4e8, 5e8);
        
        SettlementEngine.EpochRevenue memory revenue = settlementEngine.getEpochRevenue(epochId);
        assertEq(revenue.netRevenue, largeRevenue);
        assertEq(revenue.cupPurchased, largeCupAmount);
    }

    function testAnalyticsFunctionsWithZeroValues() public {
        uint256 epochId = 1;
        
        // Test with zero purchased copper
        settlementEngine.recordEpochRevenue(epochId, 50000e6, 0, 95000e6, 4e8, 5e8);
        
        uint256 roi = settlementEngine.calculateEpochROI(epochId);
        uint256 efficiency = settlementEngine.getCopperProcessingEfficiency(epochId);
        
        assertEq(roi, 0);
        assertEq(efficiency, 0);
    }

    function testAnalyticsFunctionsWithZeroSold() public {
        uint256 epochId = 1;
        
        // Test with zero sold copper
        settlementEngine.recordEpochRevenue(epochId, 50000e6, 100000e6, 0, 4e8, 5e8);
        
        uint256 margin = settlementEngine.getProfitMargin(epochId);
        
        assertEq(margin, 0);
    }

    function testCompleteWorkflowWithMultipleEpochs() public {
        // Test complete workflow with multiple epochs
        for (uint256 i = 1; i <= 5; i++) {
            uint256 epochId = i;
            uint256 netRevenue = 10000e6 * i; // Increasing revenue
            
            // Record revenue
            settlementEngine.recordEpochRevenue(epochId, netRevenue, 100000e6, 95000e6, 4e8, 5e8);
            
            // Settle revenue
            settlementEngine.settleEpochRevenue(epochId);
            
            // Distribute revenue
            usdc.approve(address(settlementEngine), netRevenue);
            settlementEngine.distributeRevenueToVault(epochId);
            
            // Verify distribution
            SettlementEngine.EpochRevenue memory revenue = settlementEngine.getEpochRevenue(epochId);
            assertEq(revenue.netRevenue, 0); // Should be zeroed after distribution
            assertTrue(revenue.isSettled);
            
            // Check fees were recorded
            uint256 expectedFee = (netRevenue * SYSTEM_FEE_BPS) / BASIS_POINTS;
            uint256 recordedFee = settlementEngine.getEpochFees(epochId);
            assertEq(recordedFee, expectedFee);
        }
    }

    function testRoleBasedAccessControl() public {
        // Test that only REVENUE_MANAGER_ROLE can perform operations
        address newManager = makeAddr("newManager");
        
        // Grant role to new manager
        settlementEngine.grantRole(settlementEngine.REVENUE_MANAGER_ROLE(), newManager);
        
        // New manager should be able to record revenue
        vm.prank(newManager);
        settlementEngine.recordEpochRevenue(1, 50000e6, 100000e6, 95000e6, 4e8, 5e8);
        
        // New manager should be able to settle revenue
        vm.prank(newManager);
        settlementEngine.settleEpochRevenue(1);
        
        // New manager should be able to distribute revenue
        usdc.approve(address(settlementEngine), 50000e6);
        vm.prank(newManager);
        settlementEngine.distributeRevenueToVault(1);
        
        // Revoke role
        settlementEngine.revokeRole(settlementEngine.REVENUE_MANAGER_ROLE(), newManager);
        
        // Should not be able to perform operations anymore
        vm.prank(newManager);
        vm.expectRevert();
        settlementEngine.recordEpochRevenue(2, 50000e6, 100000e6, 95000e6, 4e8, 5e8);
    }

    function testGasOptimizationForBatchOperations() public {
        // Test gas usage for batch operations
        uint256 startGas = gasleft();
        
        // Record multiple epochs
        for (uint256 i = 1; i <= 10; i++) {
            settlementEngine.recordEpochRevenue(i, 50000e6, 100000e6, 95000e6, 4e8, 5e8);
        }
        
        uint256 gasUsed = startGas - gasleft();
        
        // Ensure gas usage is reasonable (less than 2M gas for 10 operations)
        assertLt(gasUsed, 2000000);
    }

    function testEventEmissionIntegrity() public {
        uint256 epochId = 1;
        uint256 netRevenue = 50000e6;
        uint256 cupPurchased = 100000e6;
        uint256 cupSold = 95000e6;
        
        // Test EpochRevenueRecorded event
        vm.expectEmit(true, false, false, true);
        emit EpochRevenueRecorded(epochId, netRevenue, cupSold);
        
        // Test CopperOperationCompleted event
        vm.expectEmit(true, false, false, true);
        emit CopperOperationCompleted(epochId, cupPurchased, cupSold, netRevenue);
        
        settlementEngine.recordEpochRevenue(epochId, netRevenue, cupPurchased, cupSold, 4e8, 5e8);
        
        // Settle and test distribution events
        settlementEngine.settleEpochRevenue(epochId);
        
        uint256 systemFee = (netRevenue * SYSTEM_FEE_BPS) / BASIS_POINTS;
        uint256 netRevenueAfterFees = netRevenue - systemFee;
        uint256 expectedCupTokens = (netRevenueAfterFees * 1e8) / INITIAL_COPPER_PRICE;
        
        vm.expectEmit(true, false, false, true);
        emit RevenueDistributed(epochId, netRevenueAfterFees, expectedCupTokens, systemFee);
        
        usdc.approve(address(settlementEngine), netRevenue);
        settlementEngine.distributeRevenueToVault(epochId);
    }
}
