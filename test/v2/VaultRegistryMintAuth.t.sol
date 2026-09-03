// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {V2TestBase} from "./Helpers.sol";
import {VaultFactory} from "../../contracts/v2/VaultFactory.sol";
import {VaultRegistry} from "../../contracts/v2/VaultRegistry.sol";
import {OpenLiquidityRouter} from "../../contracts/v2/OpenLiquidityRouter.sol";
import {RWAVault} from "../../contracts/v2/RWAVault.sol";
import {CUPToken} from "../../contracts/CUPToken.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @dev Halborn FIND-023: permissionless createVault + global router minter must not allow rogue mint.
contract VaultRegistryMintAuthTest is V2TestBase {
    address internal attacker = makeAddr("attacker");
    address internal legitIssuer = makeAddr("legitIssuer");

    CUPToken internal victimAsset;
    uint256 internal legitVaultId;

    function setUp() public override {
        super.setUp();

        vm.startPrank(admin);
        victimAsset = CUPToken(
            address(new ERC1967Proxy(address(new CUPToken()), abi.encodeWithSelector(CUPToken.initialize.selector)))
        );

        bytes32 minterRole = victimAsset.MINTER_ROLE();
        victimAsset.grantRole(minterRole, address(router));
        victimAsset.grantRole(minterRole, address(settlement));
        vm.stopPrank();

        vm.prank(legitIssuer);
        (legitVaultId, , , ) = factory.createVault(
            VaultFactory.CreateVaultParams({
                assetToken: address(victimAsset),
                settlementToken: address(usdc),
                assetOracle: address(assetOracle),
                uniswapRouter: address(uniswapRouter),
                useEpochs: false,
                epochDuration: 0,
                wethToken: weth,
                vaultName: "Legit Victim Vault",
                vaultSymbol: "vVICT",
                operator: legitIssuer,
                treasury: legitIssuer,
                reportedInventoryOnly: false
            })
        );

        vm.prank(admin);
        registry.authorizeVaultMint(legitVaultId);
    }

    function test_authorizeVaultMint_revertsForNonMinterAdmin() public {
        uint256 rogueId = _createRogueVault(attacker);

        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(VaultRegistry.NotAssetMinterAdmin.selector, attacker, address(victimAsset)));
        registry.authorizeVaultMint(rogueId);
    }

    function test_authorizeVaultMint_setsFlag() public {
        uint256 rogueId = _createRogueVault(attacker);

        assertFalse(registry.isMintAuthorized(rogueId));

        vm.prank(admin);
        registry.authorizeVaultMint(rogueId);

        assertTrue(registry.isMintAuthorized(rogueId));
    }

    function test_rogueVault_approveDeposit_revertsWithoutAuthorization() public {
        uint256 rogueVaultId = _createRogueVault(attacker);
        bytes32 depositId = keccak256("rogue-deposit");
        uint256 depositUsdc = 1_000_000;

        _mintUsdc(attacker, depositUsdc);

        vm.startPrank(attacker);
        usdc.approve(address(router), depositUsdc);
        router.zapAndDeposit(rogueVaultId, IERC20(address(usdc)), depositUsdc, depositId, 0, 0);

        vm.expectRevert(abi.encodeWithSelector(VaultRegistry.MintNotAuthorized.selector, rogueVaultId));
        router.approveDeposit(rogueVaultId, depositId, depositUsdc, 1);
        vm.stopPrank();
    }

    function test_authorizedVault_approveDeposit_succeeds() public {
        bytes32 depositId = keccak256("authorized-deposit");
        _mintUsdc(user, USDC_AMOUNT);
        vm.startPrank(user);
        usdc.approve(address(router), USDC_AMOUNT);
        router.zapAndDeposit(vaultId, IERC20(address(usdc)), USDC_AMOUNT, depositId, 100, 0);
        vm.stopPrank();

        vm.prank(curator);
        router.approveDeposit(vaultId, depositId, USDC_AMOUNT, ASSET_PRICE);

        assertGt(router.getDeposit(vaultId, depositId).approvedShares, 0);
    }

    function test_confusedDeputy_blockedAfterFix() public {
        uint256 rogueVaultId = _createRogueVault(attacker);
        bytes32 depositId = keccak256("rogue-extract");
        uint256 depositUsdc = 1_000_000;

        _mintUsdc(attacker, depositUsdc);

        vm.startPrank(attacker);
        usdc.approve(address(router), depositUsdc);
        router.zapAndDeposit(rogueVaultId, IERC20(address(usdc)), depositUsdc, depositId, 0, 0);

        vm.expectRevert(abi.encodeWithSelector(VaultRegistry.MintNotAuthorized.selector, rogueVaultId));
        router.approveDeposit(rogueVaultId, depositId, depositUsdc, 1);
        vm.stopPrank();

        assertEq(victimAsset.balanceOf(attacker), 0);
    }

    function _createRogueVault(address creator) internal returns (uint256 rogueVaultId) {
        vm.prank(creator);
        (rogueVaultId, , , ) = factory.createVault(
            VaultFactory.CreateVaultParams({
                assetToken: address(victimAsset),
                settlementToken: address(usdc),
                assetOracle: address(assetOracle),
                uniswapRouter: address(uniswapRouter),
                useEpochs: false,
                epochDuration: 0,
                wethToken: weth,
                vaultName: "Rogue Vault",
                vaultSymbol: "ROGUE",
                operator: creator,
                treasury: creator,
                reportedInventoryOnly: false
            })
        );
    }

    uint256 constant USDC_AMOUNT = 4500e6;
    uint256 constant ASSET_PRICE = 450_000_000;
}
