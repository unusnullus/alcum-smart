// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {V2TestBase, MockERC20, MockAssetOracle} from "./Helpers.sol";
import {VaultFactory} from "../../contracts/v2/VaultFactory.sol";
import {VaultRegistry} from "../../contracts/v2/VaultRegistry.sol";
import {RWAVault} from "../../contracts/v2/RWAVault.sol";
import {CapitalFacility} from "../../contracts/v2/CapitalFacility.sol";
import {EpochManager} from "../../contracts/EpochManager.sol";
import {VaultLib} from "../../contracts/v2/libraries/VaultLib.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

contract VaultFactoryTest is V2TestBase {
    // ─── Successful vault creation ────────────────────────────────────────

    function test_createVault_assignsSequentialId() public {
        assertEq(vaultId, 1);

        vm.startPrank(admin);
        MockERC20 assetToken2 = new MockERC20("Gold Token", "GOLD", 6);
        MockAssetOracle oracle2 = new MockAssetOracle(200_000_000_000, "GOLD / USD");

        (uint256 vid2, , , ) = factory.createVault(
            VaultFactory.CreateVaultParams({
                assetToken: address(assetToken2),
                settlementToken: address(usdc),
                assetOracle: address(oracle2),
                uniswapRouter: address(uniswapRouter),
                useEpochs: true,
                epochDuration: 600,
                wethToken: weth,
                vaultName: "xGOLD Vault",
                vaultSymbol: "xGOLD",
                operator: address(0),
                treasury: treasury,
                reportedInventoryOnly: false
            })
        );
        vm.stopPrank();

        assertEq(vid2, 2);
        assertEq(registry.totalVaults(), 2);
    }

    function test_createVault_registryHasCorrectRecord() public {
        VaultLib.VaultRecord memory r = registry.getVault(vaultId);

        assertEq(r.vault, vaultAddr);
        assertEq(r.assetToken, address(assetToken));
        assertEq(r.settlementToken, address(usdc));
        assertEq(r.capitalFacility, facilityAddr);
        assertEq(r.rfqEngine, address(rfqEngine));
        assertEq(r.assetOracle, address(assetOracle));
        assertEq(r.uniswapRouter, address(uniswapRouter));
        // Factory auto-deployed a per-vault EpochManager — just verify it's non-zero
        assertEq(r.epochManager, epochManagerAddr, "epochManager should match deployed addr");
        assertTrue(r.epochManager != address(0), "epochManager must be set");
        assertEq(r.treasury, treasury);
        assertTrue(r.active);
    }

    function test_createVault_deployedEpochManagerHasCorrectDuration() public {
        // Factory deploys per-vault EpochManager — check its epoch duration
        EpochManager em = EpochManager(epochManagerAddr);
        assertEq(em.epochDuration(), 600);
    }

    function test_createVault_perVaultEpochManagersAreDistinct() public {
        // Each vault gets its own EpochManager proxy
        vm.startPrank(admin);
        MockERC20 assetToken2 = new MockERC20("Gold Token", "GOLD", 6);
        MockAssetOracle oracle2 = new MockAssetOracle(200_000_000_000, "GOLD / USD");

        (, , , address em2) = factory.createVault(
            VaultFactory.CreateVaultParams({
                assetToken: address(assetToken2),
                settlementToken: address(usdc),
                assetOracle: address(oracle2),
                uniswapRouter: address(uniswapRouter),
                useEpochs: true,
                epochDuration: 1200, // different duration
                wethToken: weth,
                vaultName: "xGOLD",
                vaultSymbol: "xGOLD",
                operator: address(0),
                treasury: treasury,
                reportedInventoryOnly: false
            })
        );
        vm.stopPrank();

        assertTrue(em2 != epochManagerAddr, "each vault gets a separate epoch manager proxy");
        assertEq(EpochManager(em2).epochDuration(), 1200);
    }

    function test_createVault_rwavaultHasRedeemerRoles() public {
        RWAVault vault = RWAVault(vaultAddr);
        bytes32 role = vault.REDEEMER_ROLE();

        assertTrue(vault.hasRole(role, address(router)), "router needs REDEEMER_ROLE");
        assertTrue(vault.hasRole(role, address(rfqEngine)), "rfqEngine needs REDEEMER_ROLE");
    }

    function test_createVault_facilityApprovesRouter() public {
        uint256 allowance = usdc.allowance(facilityAddr, address(router));
        assertEq(allowance, type(uint256).max, "facility must approve router");
    }

    function test_createVault_ownershipTransferredToAdmin() public {
        RWAVault vault = RWAVault(vaultAddr);
        CapitalFacility facility = CapitalFacility(facilityAddr);
        EpochManager em = EpochManager(epochManagerAddr);

        assertEq(vault.owner(), admin);
        assertEq(facility.owner(), admin);
        assertEq(em.owner(), admin);
    }

    function test_createVault_factoryDoesNotRetainOperatorRoles() public {
        CapitalFacility facility = CapitalFacility(facilityAddr);
        EpochManager em = EpochManager(epochManagerAddr);

        assertFalse(facility.hasRole(facility.FACILITY_OPERATOR_ROLE(), address(factory)));
        assertFalse(em.hasRole(em.EPOCH_MANAGER_ROLE(), address(factory)));
    }

    function test_createVault_emitsVaultCreated() public {
        vm.startPrank(admin);
        MockERC20 at = new MockERC20("Silver Token", "SLV", 6);
        MockAssetOracle oa = new MockAssetOracle(2500_000_000, "SLV / USD");

        // Only check that the event is emitted (no strict topic checks — addresses are dynamic)
        vm.expectEmit(false, false, false, false);
        emit VaultFactory.VaultCreated(0, address(0), address(0), address(0), address(0), address(0), address(0), "", "");

        factory.createVault(
            VaultFactory.CreateVaultParams({
                assetToken: address(at),
                settlementToken: address(usdc),
                assetOracle: address(oa),
                uniswapRouter: address(uniswapRouter),
                useEpochs: true,
                epochDuration: 600,
                wethToken: weth,
                vaultName: "xSLV Vault",
                vaultSymbol: "xSLV",
                operator: address(0),
                treasury: treasury,
                reportedInventoryOnly: false
            })
        );
        vm.stopPrank();
    }

    // ─── Revert conditions ────────────────────────────────────────────────

    function test_createVault_permissionless() public {
        // createVault is permissionless — any address can deploy a new vault stack.
        vm.prank(user);
        (uint256 vid, , , ) = factory.createVault(
            VaultFactory.CreateVaultParams({
                assetToken: address(assetToken),
                settlementToken: address(usdc),
                assetOracle: address(assetOracle),
                uniswapRouter: address(uniswapRouter),
                useEpochs: true,
                epochDuration: 600,
                wethToken: weth,
                vaultName: "x",
                vaultSymbol: "x",
                operator: address(0),
                treasury: treasury,
                reportedInventoryOnly: false
            })
        );
        assertGt(vid, 0);
    }

    function test_createVault_revertsZeroAssetToken() public {
        vm.prank(admin);
        vm.expectRevert(VaultFactory.ZeroAddress.selector);
        factory.createVault(
            VaultFactory.CreateVaultParams({
                assetToken: address(0),
                settlementToken: address(usdc),
                assetOracle: address(assetOracle),
                uniswapRouter: address(uniswapRouter),
                useEpochs: true,
                epochDuration: 600,
                wethToken: weth,
                vaultName: "x",
                vaultSymbol: "x",
                operator: address(0),
                treasury: treasury,
                reportedInventoryOnly: false
            })
        );
    }

    function test_createVault_revertsZeroOracle() public {
        vm.prank(admin);
        vm.expectRevert(VaultFactory.ZeroAddress.selector);
        factory.createVault(
            VaultFactory.CreateVaultParams({
                assetToken: address(assetToken),
                settlementToken: address(usdc),
                assetOracle: address(0),
                uniswapRouter: address(uniswapRouter),
                useEpochs: true,
                epochDuration: 600,
                wethToken: weth,
                vaultName: "x",
                vaultSymbol: "x",
                operator: address(0),
                treasury: treasury,
                reportedInventoryOnly: false
            })
        );
    }

    function test_createVault_revertsZeroEpochDuration() public {
        vm.prank(admin);
        vm.expectRevert(VaultFactory.InvalidEpochDuration.selector);
        factory.createVault(
            VaultFactory.CreateVaultParams({
                assetToken: address(assetToken),
                settlementToken: address(usdc),
                assetOracle: address(assetOracle),
                uniswapRouter: address(uniswapRouter),
                useEpochs: true,
                epochDuration: 0, // ← should revert
                wethToken: weth,
                vaultName: "x",
                vaultSymbol: "x",
                operator: address(0),
                treasury: treasury,
                reportedInventoryOnly: false
            })
        );
    }

    function test_createVault_revertsZeroTreasury() public {
        vm.prank(admin);
        vm.expectRevert(VaultFactory.ZeroAddress.selector);
        factory.createVault(
            VaultFactory.CreateVaultParams({
                assetToken: address(assetToken),
                settlementToken: address(usdc),
                assetOracle: address(assetOracle),
                uniswapRouter: address(uniswapRouter),
                useEpochs: true,
                epochDuration: 600,
                wethToken: weth,
                vaultName: "x",
                vaultSymbol: "x",
                operator: address(0),
                treasury: address(0),
                reportedInventoryOnly: false
            })
        );
    }

    // ─── Registry — governance guards ─────────────────────────────────────

    function test_registry_revertsUnknownVaultId() public {
        vm.expectRevert(abi.encodeWithSelector(VaultLib.VaultNotFound.selector, uint256(999)));
        registry.getVault(999);
    }

    function test_registry_setVaultActive_toggles() public {
        vm.prank(admin);
        registry.setVaultActive(vaultId, false);
        assertFalse(registry.isActive(vaultId));

        vm.prank(admin);
        registry.setVaultActive(vaultId, true);
        assertTrue(registry.isActive(vaultId));
    }

    function test_registry_setVaultActive_unauthorizedReverts() public {
        vm.prank(user);
        vm.expectRevert(VaultRegistry.Unauthorized.selector);
        registry.setVaultActive(vaultId, false);
    }

    function test_registry_setVaultOracle_byOwner() public {
        MockAssetOracle newOracle = new MockAssetOracle(500_000_000, "GRWA / USD v2");

        vm.prank(admin);
        registry.setVaultOracle(vaultId, address(newOracle));

        assertEq(registry.getVault(vaultId).assetOracle, address(newOracle));
    }

    function test_registry_setVaultOracle_unauthorizedReverts() public {
        vm.prank(user);
        vm.expectRevert(VaultRegistry.Unauthorized.selector);
        registry.setVaultOracle(vaultId, address(assetOracle));
    }

    function test_registry_setVaultEpochManager_byOwner() public {
        EpochManager newEm = EpochManager(
            address(
                new ERC1967Proxy(
                    address(epochManagerImpl),
                    abi.encodeWithSelector(EpochManager.initialize.selector, uint256(900))
                )
            )
        );

        vm.prank(admin);
        registry.setVaultEpochManager(vaultId, address(newEm));

        assertEq(registry.getVault(vaultId).epochManager, address(newEm));
    }

    function test_registry_setVaultTreasury_byOwner() public {
        address newTreasury = makeAddr("newVaultTreasury");

        vm.prank(admin);
        registry.setVaultTreasury(vaultId, newTreasury);

        assertEq(registry.getVault(vaultId).treasury, newTreasury);
    }

    function test_registry_governorRole_canSetVaultActive() public {
        address timelock = makeAddr("timelock");

        vm.prank(admin);
        registry.grantGovernorRole(timelock);

        // Timelock (governor) can now toggle vault
        vm.prank(timelock);
        registry.setVaultActive(vaultId, false);
        assertFalse(registry.isActive(vaultId));
    }

    // ─── Factory admin ────────────────────────────────────────────────────

    function test_factory_setEpochManagerImpl() public {
        EpochManager newImpl = new EpochManager();

        vm.prank(admin);
        factory.setEpochManagerImplementation(address(newImpl));

        assertEq(factory.epochManagerImplementation(), address(newImpl));
    }

    function test_factory_setEpochManagerImpl_unauthorizedReverts() public {
        vm.prank(user);
        vm.expectRevert();
        factory.setEpochManagerImplementation(address(epochManagerImpl));
    }

    function test_createVault_reportedInventoryOnly_requiresEpochs() public {
        vm.prank(admin);
        vm.expectRevert(VaultFactory.ReportedInventoryRequiresEpochs.selector);
        factory.createVault(
            VaultFactory.CreateVaultParams({
                assetToken: address(assetToken),
                settlementToken: address(usdc),
                assetOracle: address(assetOracle),
                uniswapRouter: address(uniswapRouter),
                useEpochs: false,
                epochDuration: 0,
                wethToken: weth,
                vaultName: "x",
                vaultSymbol: "x",
                operator: address(0),
                treasury: treasury,
                reportedInventoryOnly: true
            })
        );
    }

    function test_createVault_reportedInventoryOnly_storesFlag() public {
        vm.prank(admin);
        (uint256 vid, , , ) = factory.createVault(
            VaultFactory.CreateVaultParams({
                assetToken: address(assetToken),
                settlementToken: address(usdc),
                assetOracle: address(assetOracle),
                uniswapRouter: address(uniswapRouter),
                useEpochs: true,
                epochDuration: 600,
                wethToken: weth,
                vaultName: "xWH",
                vaultSymbol: "xWH",
                operator: address(0),
                treasury: treasury,
                reportedInventoryOnly: true
            })
        );
        assertTrue(registry.getVault(vid).reportedInventoryOnly);
    }
}
