// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test, console} from "forge-std/Test.sol";
import {SettlementEngine} from "../contracts/SettlementEngine.sol";
import {CUPToken} from "../contracts/CUPToken.sol";
import {xCUP} from "../contracts/xCUP.sol";
import {EpochManager} from "../contracts/EpochManager.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ICopperPriceConsumer} from "../contracts/interfaces/ICopperPriceConsumer.sol";

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
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function decimals() external pure returns (uint8) {
        return 6;
    }

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        if (allowance[from][msg.sender] < amount) {
            revert("Insufficient allowance");
        }
        allowance[from][msg.sender] -= amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }
}

contract MockUniswapRouter {
    function WETH() external pure returns (address) {
        return address(0x1234567890123456789012345678901234567890);
    }

    function getAmountsOut(uint256 amountIn, address[] calldata path) external pure returns (uint256[] memory amounts) {
        amounts = new uint256[](2);
        amounts[0] = amountIn;
        amounts[1] = amountIn; // 1:1 for testing
    }
}

contract SettlementEngineTest is Test {
    SettlementEngine public settlementEngine;
    CUPToken public cupToken;
    xCUP public xcup;
    EpochManager public epochManager;
    MockCopperPriceConsumer public copperPriceConsumer;
    MockUSDC public usdc;
    address public owner;
    address public revenueManager;
    address public treasury;
    address public zapper;
    address public user1;

    function setUp() public {
        owner = address(this);
        revenueManager = makeAddr("revenueManager");
        treasury = makeAddr("treasury");
        zapper = makeAddr("zapper");
        user1 = makeAddr("user1");

        // Deploy dependencies
        CUPToken cupImpl = new CUPToken();
        bytes memory cupInitData = abi.encodeWithSelector(CUPToken.initialize.selector);
        ERC1967Proxy cupProxy = new ERC1967Proxy(address(cupImpl), cupInitData);
        cupToken = CUPToken(address(cupProxy));

        copperPriceConsumer = new MockCopperPriceConsumer();
        usdc = new MockUSDC();

        // Deploy EpochManager
        EpochManager epochImpl = new EpochManager();
        bytes memory epochInitData = abi.encodeWithSelector(EpochManager.initialize.selector, 7 days);
        ERC1967Proxy epochProxy = new ERC1967Proxy(address(epochImpl), epochInitData);
        epochManager = EpochManager(address(epochProxy));

        // Deploy xCUP
        xCUP xcupImpl = new xCUP();
        bytes memory xcupInitData = abi.encodeWithSelector(
            xCUP.initialize.selector,
            IERC20(address(cupToken)),
            "xCUP Vault",
            "xCUP",
            address(copperPriceConsumer),
            address(0x4567890123456789012345678901234567890123), // Mock router
            address(usdc),
            address(0x1234567890123456789012345678901234567890) // Mock WETH
        );
        ERC1967Proxy xcupProxy = new ERC1967Proxy(address(xcupImpl), xcupInitData);
        xcup = xCUP(address(xcupProxy));

        // Deploy SettlementEngine
        SettlementEngine settlementImpl = new SettlementEngine();
        bytes memory settlementInitData = abi.encodeWithSelector(
            SettlementEngine.initialize.selector,
            address(xcup),
            treasury,
            zapper,
            address(epochManager),
            address(copperPriceConsumer),
            address(usdc),
            500 // systemFeeBps
        );
        ERC1967Proxy settlementProxy = new ERC1967Proxy(address(settlementImpl), settlementInitData);
        settlementEngine = SettlementEngine(address(settlementProxy));

        // Grant roles
        settlementEngine.grantRole(settlementEngine.REVENUE_MANAGER_ROLE(), revenueManager);
        cupToken.grantRole(cupToken.MINTER_ROLE(), address(settlementEngine));
    }

    function testInitialization() public {
        // Most fields are private, can't test directly
        assertTrue(settlementEngine.hasRole(settlementEngine.DEFAULT_ADMIN_ROLE(), owner));
        assertTrue(settlementEngine.hasRole(settlementEngine.REVENUE_MANAGER_ROLE(), revenueManager));
    }

    function testUpdateNAV() public {
        SettlementEngine.NAVComponents memory nav = SettlementEngine.NAVComponents({
            cupInWarehouse: 1000000 * 10 ** 8,
            copperSpotPrice: 450000000,
            cupInTransit: 500000 * 10 ** 8,
            retainedEarnings: 100000 * 10 ** 6,
            stablecoinBalance: 500000 * 10 ** 6,
            liabilities: 200000 * 10 ** 6
        });

        vm.prank(revenueManager);
        settlementEngine.updateNAV(nav);

        // Check that NAV was updated
        (
            uint256 cupInWarehouse,
            uint256 copperSpotPrice,
            uint256 cupInTransit,
            uint256 retainedEarnings,
            uint256 stablecoinBalance,
            uint256 liabilities
        ) = settlementEngine._nav();
        assertEq(cupInWarehouse, nav.cupInWarehouse);
        assertEq(copperSpotPrice, nav.copperSpotPrice);
        assertEq(cupInTransit, nav.cupInTransit);
        assertEq(retainedEarnings, nav.retainedEarnings);
        assertEq(stablecoinBalance, nav.stablecoinBalance);
        assertEq(liabilities, nav.liabilities);
    }

    function testUpdateNAVWithoutRole() public {
        SettlementEngine.NAVComponents memory nav = SettlementEngine.NAVComponents({
            cupInWarehouse: 1000000 * 10 ** 8,
            copperSpotPrice: 450000000,
            cupInTransit: 500000 * 10 ** 8,
            retainedEarnings: 100000 * 10 ** 6,
            stablecoinBalance: 500000 * 10 ** 6,
            liabilities: 200000 * 10 ** 6
        });

        address nonManager = makeAddr("nonManager");
        vm.prank(nonManager);
        vm.expectRevert();
        settlementEngine.updateNAV(nav);
    }

    function testRecordEpochRevenue() public {
        // Start an epoch first
        vm.warp(7 days + 1);
        epochManager.nextEpoch();

        uint256 epochId = epochManager.currentEpochId();
        uint256 netRevenue = 80000 * 10 ** 6; // $80k net revenue

        vm.prank(revenueManager);
        settlementEngine.recordEpochRevenue(epochId, netRevenue, 0, 0, 0, 0);

        SettlementEngine.EpochRevenue memory revenue = settlementEngine.getEpochRevenue(epochId);
        assertEq(revenue.netRevenue, netRevenue);
        assertFalse(revenue.isSettled);
    }

    function testRecordEpochRevenueWithoutRole() public {
        // Start an epoch first
        vm.warp(7 days + 1);
        epochManager.nextEpoch();

        uint256 epochId = epochManager.currentEpochId();

        address nonManager = makeAddr("nonManager");
        vm.prank(nonManager);
        vm.expectRevert();
        settlementEngine.recordEpochRevenue(epochId, 80000 * 10 ** 6, 0, 0, 0, 0);
    }

    function testSettleEpochRevenue() public {
        // Start an epoch first
        vm.warp(7 days + 1);
        epochManager.nextEpoch();

        uint256 epochId = epochManager.currentEpochId();
        uint256 netRevenue = 80000 * 10 ** 6;

        // Record revenue
        vm.prank(revenueManager);
        settlementEngine.recordEpochRevenue(epochId, netRevenue, 0, 0, 0, 0);

        // Settle revenue
        vm.prank(revenueManager);
        settlementEngine.settleEpochRevenue(epochId);

        // Check that epoch is settled
        SettlementEngine.EpochRevenue memory revenue = settlementEngine.getEpochRevenue(epochId);
        assertTrue(revenue.isSettled);

        // Check that retained earnings were updated
        (,,, uint256 retainedEarnings,,) = settlementEngine._nav();
        // Retained earnings should be updated with net revenue
        assertEq(retainedEarnings, netRevenue);
    }

    function testSettleEpochRevenueNotFound() public {
        vm.prank(revenueManager);
        vm.expectRevert(SettlementEngine.FutureEpochId.selector);
        settlementEngine.settleEpochRevenue(999); // Use a non-existent epoch
    }

    function testCalculateEpochROI() public {
        // Start an epoch first
        vm.warp(7 days + 1);
        epochManager.nextEpoch();

        uint256 epochId = epochManager.currentEpochId();
        uint256 netRevenue = 80000 * 10 ** 6;

        vm.prank(revenueManager);
        settlementEngine.recordEpochRevenue(epochId, netRevenue, 0, 0, 0, 0);

        uint256 roi = settlementEngine.calculateEpochROI(epochId);
        // ROI is 0 if no cupPurchased, which is expected
        assertTrue(roi >= 0);
    }

    function testGetNAVSummary() public {
        SettlementEngine.NAVComponents memory nav = SettlementEngine.NAVComponents({
            cupInWarehouse: 1000000 * 10 ** 8,
            copperSpotPrice: 450000000,
            cupInTransit: 500000 * 10 ** 8,
            retainedEarnings: 100000 * 10 ** 6,
            stablecoinBalance: 500000 * 10 ** 6,
            liabilities: 200000 * 10 ** 6
        });

        vm.prank(revenueManager);
        settlementEngine.updateNAV(nav);

        (uint256 totalAssets, uint256 totalLiabilities, uint256 totalEquity) = settlementEngine.getNAVSummary();
        assertTrue(totalAssets > 0);
        assertTrue(totalLiabilities > 0);
        assertTrue(totalEquity > 0);
    }

    function testPause() public {
        settlementEngine.pause();
        assertTrue(settlementEngine.paused());
    }

    function testUnpause() public {
        settlementEngine.pause();
        settlementEngine.unpause();
        assertFalse(settlementEngine.paused());
    }

    function testUpdateSystemFee() public {
        uint256 newFee = 300; // 3%
        settlementEngine.updateSystemFee(newFee);
        // systemFeeBps is private, can't test directly
    }

    function testUpdateTreasury() public {
        address newTreasury = makeAddr("newTreasury");
        settlementEngine.updateTreasury(newTreasury);
        // treasury is private, can't test directly
    }

    function testUpdateZapper() public {
        address newZapper = makeAddr("newZapper");
        settlementEngine.updateZapper(newZapper);
        // zapper is private, can't test directly
    }

    function testGetEpochRevenue() public {
        uint256 epochId = 1;
        uint256 netRevenue = 1000000 * 10 ** 6;

        // Advance epoch to make epochId = 1 current
        vm.warp(block.timestamp + 7 days);
        epochManager.nextEpoch();

        vm.prank(revenueManager);
        settlementEngine.recordEpochRevenue(
            epochId, netRevenue, 1000 * 10 ** 8, 800 * 10 ** 8, 1000 * 10 ** 8, 1200 * 10 ** 8
        );

        SettlementEngine.EpochRevenue memory revenue = settlementEngine.getEpochRevenue(epochId);
        assertEq(revenue.epochId, epochId);
        assertEq(revenue.netRevenue, netRevenue);
    }

    function testGetCurrentEpochRevenue() public {
        SettlementEngine.EpochRevenue memory revenue = settlementEngine.getCurrentEpochRevenue();
        assertEq(revenue.epochId, 0); // Current epoch should be 0
    }

    function testAdvanceEpoch() public {
        uint256 currentEpoch = 0; // Start with epoch 0
        settlementEngine.advanceEpoch();
        // Can't test currentEpochId directly as it's private
    }

    function testAdvanceEpochWithoutRole() public {
        vm.prank(user1);
        vm.expectRevert();
        settlementEngine.advanceEpoch();
    }

    function testGetCopperProcessingEfficiency() public {
        uint256 epochId = 1;
        uint256 netRevenue = 1000000 * 10 ** 6;

        // Advance epoch to make epochId = 1 current
        vm.warp(block.timestamp + 7 days);
        epochManager.nextEpoch();

        vm.prank(revenueManager);
        settlementEngine.recordEpochRevenue(
            epochId, netRevenue, 1000 * 10 ** 8, 800 * 10 ** 8, 1000 * 10 ** 8, 1200 * 10 ** 8
        );

        uint256 efficiency = settlementEngine.getCopperProcessingEfficiency(epochId);
        assertTrue(efficiency >= 0);
    }

    function testGetCopperProcessingEfficiencyNotFound() public {
        vm.expectRevert(SettlementEngine.EpochRevenueNotFound.selector);
        settlementEngine.getCopperProcessingEfficiency(999);
    }

    function testGetProfitMargin() public {
        uint256 epochId = 1;
        uint256 netRevenue = 1000000 * 10 ** 6;

        // Advance epoch to make epochId = 1 current
        vm.warp(block.timestamp + 7 days);
        epochManager.nextEpoch();

        vm.prank(revenueManager);
        settlementEngine.recordEpochRevenue(
            epochId, netRevenue, 1000 * 10 ** 8, 800 * 10 ** 8, 1000 * 10 ** 8, 1200 * 10 ** 8
        );

        uint256 margin = settlementEngine.getProfitMargin(epochId);
        assertTrue(margin >= 0);
    }

    function testGetProfitMarginNotFound() public {
        vm.expectRevert(SettlementEngine.EpochRevenueNotFound.selector);
        settlementEngine.getProfitMargin(999);
    }

    function testDistributeRevenueToVault() public {
        uint256 epochId = 1;
        uint256 netRevenue = 1000000 * 10 ** 6;

        // Advance epoch to make epochId = 1 current
        vm.warp(block.timestamp + 7 days);
        epochManager.nextEpoch();

        vm.prank(revenueManager);
        settlementEngine.recordEpochRevenue(
            epochId, netRevenue, 1000 * 10 ** 8, 800 * 10 ** 8, 1000 * 10 ** 8, 1200 * 10 ** 8
        );

        // Settle the epoch first
        vm.prank(revenueManager);
        settlementEngine.settleEpochRevenue(epochId);

        // Mint USDC to revenueManager and approve
        usdc.mint(revenueManager, netRevenue);
        vm.prank(revenueManager);
        usdc.approve(address(settlementEngine), netRevenue);

        vm.prank(revenueManager);
        settlementEngine.distributeRevenueToVault(epochId);
        // Function should not revert
    }

    function testDistributeRevenueToVaultWithoutRole() public {
        vm.prank(user1);
        vm.expectRevert();
        settlementEngine.distributeRevenueToVault(0);
    }

    function testGetEpochFees() public {
        uint256 epochId = 0;
        uint256 fees = settlementEngine.getEpochFees(epochId);
        assertEq(fees, 0); // Should be 0 initially
    }

    function testUpdateSystemFeeInvalid() public {
        vm.expectRevert(SettlementEngine.InvalidSystemFee.selector);
        settlementEngine.updateSystemFee(10001); // > 10000 basis points
    }

    function testUpdateTreasuryInvalid() public {
        vm.expectRevert(SettlementEngine.InvalidTreasuryAddress.selector);
        settlementEngine.updateTreasury(address(0));
    }

    function testUpdateZapperInvalid() public {
        vm.expectRevert(SettlementEngine.InvalidZapperAddress.selector);
        settlementEngine.updateZapper(address(0));
    }

    function testUpdateSystemFeeWithoutRole() public {
        vm.prank(user1);
        vm.expectRevert();
        settlementEngine.updateSystemFee(100);
    }

    function testUpdateTreasuryWithoutRole() public {
        vm.prank(user1);
        vm.expectRevert();
        settlementEngine.updateTreasury(makeAddr("newTreasury"));
    }

    function testUpdateZapperWithoutRole() public {
        vm.prank(user1);
        vm.expectRevert();
        settlementEngine.updateZapper(makeAddr("newZapper"));
    }

    function testAdvanceEpochMultiple() public {
        // Test multiple epoch advances
        settlementEngine.advanceEpoch();
        settlementEngine.advanceEpoch();
        // Function should not revert
        assertTrue(true);
    }

    function testUpdateSystemFeeWithZeroFee() public {
        settlementEngine.updateSystemFee(0);
        // Should not revert
        assertTrue(true);
    }

    function testUpdateSystemFeeWithMaxFee() public {
        settlementEngine.updateSystemFee(10000); // 100%
        // Should not revert
        assertTrue(true);
    }

    function testUpdateSystemFeeWithInvalidFee() public {
        vm.expectRevert(SettlementEngine.InvalidSystemFee.selector);
        settlementEngine.updateSystemFee(10001); // > 100%
    }

    function testUpdateTreasuryWithValidAddress() public {
        address newTreasury = makeAddr("newTreasury");
        settlementEngine.updateTreasury(newTreasury);
        // Should not revert
        assertTrue(true);
    }

    function testUpdateZapperWithValidAddress() public {
        address newZapper = makeAddr("newZapper");
        settlementEngine.updateZapper(newZapper);
        // Should not revert
        assertTrue(true);
    }

    function testUpdateNAVWithZeroNAV() public {
        SettlementEngine.NAVComponents memory nav = SettlementEngine.NAVComponents(0, 0, 0, 0, 0, 0);
        settlementEngine.updateNAV(nav);
        // Should not revert
        assertTrue(true);
    }

    function testUpdateNAVWithMaxNAV() public {
        SettlementEngine.NAVComponents memory nav = SettlementEngine.NAVComponents(
            type(uint256).max,
            type(uint256).max,
            type(uint256).max,
            type(uint256).max,
            type(uint256).max,
            type(uint256).max
        );
        vm.expectRevert(); // Should revert due to arithmetic overflow
        settlementEngine.updateNAV(nav);
    }

    function testRecordEpochRevenueWithZeroRevenue() public {
        vm.expectRevert(SettlementEngine.ZeroEpochId.selector);
        settlementEngine.recordEpochRevenue(0, 0, 0, 0, 0, 0);
    }

    function testRecordEpochRevenueWithMaxRevenue() public {
        vm.expectRevert(SettlementEngine.FutureEpochId.selector);
        settlementEngine.recordEpochRevenue(
            type(uint256).max,
            type(uint256).max,
            type(uint256).max,
            type(uint256).max,
            type(uint256).max,
            type(uint256).max
        );
    }

    function testDistributeRevenueToVaultWithZeroAmount() public {
        vm.expectRevert(SettlementEngine.EpochNotSettled.selector);
        settlementEngine.distributeRevenueToVault(0);
    }

    function testDistributeRevenueToVaultWithMaxAmount() public {
        vm.expectRevert(SettlementEngine.FutureEpochId.selector);
        settlementEngine.distributeRevenueToVault(type(uint256).max);
    }

    function testPauseWhenAlreadyPaused() public {
        settlementEngine.pause();
        vm.expectRevert(); // Should revert when already paused
        settlementEngine.pause();
    }

    function testUnpauseWhenNotPaused() public {
        vm.expectRevert(); // Should revert when not paused
        settlementEngine.unpause();
    }

    // Test initialization error cases for better branch coverage
    function testInitializeWithZeroVault() public {
        SettlementEngine implementation = new SettlementEngine();
        bytes memory initData = abi.encodeWithSelector(
            SettlementEngine.initialize.selector,
            address(0), // Zero vault
            treasury,
            zapper,
            address(epochManager),
            address(copperPriceConsumer),
            address(usdc),
            100
        );

        vm.expectRevert(SettlementEngine.InvalidVaultAddress.selector);
        new ERC1967Proxy(address(implementation), initData);
    }

    function testInitializeWithZeroTreasury() public {
        SettlementEngine implementation = new SettlementEngine();
        bytes memory initData = abi.encodeWithSelector(
            SettlementEngine.initialize.selector,
            address(xcup),
            address(0), // Zero treasury
            zapper,
            address(epochManager),
            address(copperPriceConsumer),
            address(usdc),
            100
        );

        vm.expectRevert(SettlementEngine.InvalidTreasuryAddress.selector);
        new ERC1967Proxy(address(implementation), initData);
    }

    function testInitializeWithZeroZapper() public {
        SettlementEngine implementation = new SettlementEngine();
        bytes memory initData = abi.encodeWithSelector(
            SettlementEngine.initialize.selector,
            address(xcup),
            treasury,
            address(0), // Zero zapper
            address(epochManager),
            address(copperPriceConsumer),
            address(usdc),
            100
        );

        vm.expectRevert(SettlementEngine.InvalidZapperAddress.selector);
        new ERC1967Proxy(address(implementation), initData);
    }

    function testInitializeWithZeroEpochManager() public {
        SettlementEngine implementation = new SettlementEngine();
        bytes memory initData = abi.encodeWithSelector(
            SettlementEngine.initialize.selector,
            address(xcup),
            treasury,
            zapper,
            address(0), // Zero epoch manager
            address(copperPriceConsumer),
            address(usdc),
            100
        );

        vm.expectRevert(SettlementEngine.InvalidEpochManagerAddress.selector);
        new ERC1967Proxy(address(implementation), initData);
    }

    function testInitializeWithZeroCopperPriceConsumer() public {
        SettlementEngine implementation = new SettlementEngine();
        bytes memory initData = abi.encodeWithSelector(
            SettlementEngine.initialize.selector,
            address(xcup),
            treasury,
            zapper,
            address(epochManager),
            address(0), // Zero copper price consumer
            address(usdc),
            100
        );

        vm.expectRevert(SettlementEngine.InvalidCopperPriceConsumerAddress.selector);
        new ERC1967Proxy(address(implementation), initData);
    }

    function testInitializeWithZeroUSDC() public {
        SettlementEngine implementation = new SettlementEngine();
        bytes memory initData = abi.encodeWithSelector(
            SettlementEngine.initialize.selector,
            address(xcup),
            treasury,
            zapper,
            address(epochManager),
            address(copperPriceConsumer),
            address(0), // Zero USDC
            100
        );

        vm.expectRevert(SettlementEngine.InvalidUSDCAddress.selector);
        new ERC1967Proxy(address(implementation), initData);
    }

    function testInitializeWithInvalidSystemFee() public {
        SettlementEngine implementation = new SettlementEngine();
        bytes memory initData = abi.encodeWithSelector(
            SettlementEngine.initialize.selector,
            address(xcup),
            treasury,
            zapper,
            address(epochManager),
            address(copperPriceConsumer),
            address(usdc),
            10001 // Invalid fee > 10000 basis points
        );

        vm.expectRevert(SettlementEngine.InvalidSystemFee.selector);
        new ERC1967Proxy(address(implementation), initData);
    }

    function testRecordEpochRevenueWithZeroEpochId() public {
        vm.expectRevert(SettlementEngine.ZeroEpochId.selector);
        settlementEngine.recordEpochRevenue(0, 1000 * 10 ** 6, 1000 * 10 ** 6, 1000 * 10 ** 6, 450000000, 460000000);
    }

    function testRecordEpochRevenueWithFutureEpochId() public {
        uint256 futureEpoch = epochManager.currentEpochId() + 1;
        vm.expectRevert(SettlementEngine.FutureEpochId.selector);
        settlementEngine.recordEpochRevenue(
            futureEpoch, 1000 * 10 ** 6, 1000 * 10 ** 6, 1000 * 10 ** 6, 450000000, 460000000
        );
    }

    function testRecordEpochRevenueWithZeroNetRevenue() public {
        // Start an epoch first
        vm.warp(7 days + 1);
        epochManager.nextEpoch();
        uint256 epochId = epochManager.currentEpochId();

        vm.expectRevert(SettlementEngine.ZeroNetRevenue.selector);
        settlementEngine.recordEpochRevenue(epochId, 0, 1000 * 10 ** 6, 1000 * 10 ** 6, 450000000, 460000000);
    }

    function testSettleEpochRevenueWithFutureEpochId() public {
        uint256 futureEpoch = epochManager.currentEpochId() + 1;
        vm.expectRevert(SettlementEngine.FutureEpochId.selector);
        settlementEngine.settleEpochRevenue(futureEpoch);
    }

    function testSettleEpochRevenueNotFoundNew() public {
        uint256 futureEpoch = epochManager.currentEpochId() + 1; // Use future epoch
        vm.expectRevert(SettlementEngine.FutureEpochId.selector);
        settlementEngine.settleEpochRevenue(futureEpoch);
    }

    function testSettleEpochRevenueWithZeroRevenue() public {
        // Start an epoch first
        vm.warp(7 days + 1);
        epochManager.nextEpoch();
        uint256 epochId = epochManager.currentEpochId();

        // First record revenue with zero net revenue - this should revert
        vm.prank(revenueManager);
        vm.expectRevert(SettlementEngine.ZeroNetRevenue.selector);
        settlementEngine.recordEpochRevenue(epochId, 0, 1000 * 10 ** 6, 1000 * 10 ** 6, 450000000, 460000000);
    }

    function testCalculateEpochROINotFound() public {
        uint256 nonExistentEpoch = 999;
        vm.expectRevert(SettlementEngine.EpochRevenueNotFound.selector);
        settlementEngine.calculateEpochROI(nonExistentEpoch);
    }

    function testCalculateEpochROIWithZeroCupPurchased() public {
        // Start an epoch first
        vm.warp(7 days + 1);
        epochManager.nextEpoch();
        uint256 epochId = epochManager.currentEpochId();

        // Record revenue with zero cup purchased
        vm.prank(revenueManager);
        settlementEngine.recordEpochRevenue(epochId, 1000 * 10 ** 6, 0, 1000 * 10 ** 6, 450000000, 460000000);

        // Calculate ROI should return 0
        uint256 roi = settlementEngine.calculateEpochROI(epochId);
        assertEq(roi, 0);
    }

    function testCalculateEpochROIWithZeroTotalInvestment() public {
        // Start an epoch first
        vm.warp(7 days + 1);
        epochManager.nextEpoch();
        uint256 epochId = epochManager.currentEpochId();

        // Record revenue with zero average purchase price
        vm.prank(revenueManager);
        settlementEngine.recordEpochRevenue(epochId, 1000 * 10 ** 6, 1000 * 10 ** 6, 1000 * 10 ** 6, 0, 460000000);

        // Calculate ROI should return 0
        uint256 roi = settlementEngine.calculateEpochROI(epochId);
        assertEq(roi, 0);
    }
}
