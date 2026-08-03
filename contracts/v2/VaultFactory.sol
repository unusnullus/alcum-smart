// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IERC20} from "@openzeppelin/contracts/interfaces/IERC20.sol";
import {RWAVault} from "./RWAVault.sol";
import {CapitalFacility} from "./CapitalFacility.sol";
import {VaultRegistry} from "./VaultRegistry.sol";
import {EpochManager} from "../EpochManager.sol";

/// @dev Minimal interface implemented by OpenLiquidityRouter and SharedSettlementEngine.
interface IVaultOperatorRegistry {
    function setVaultOperator(uint256 vaultId, address operator) external;
}

/**
 * @title VaultFactory
 * @notice Deploys a complete RWA vault ecosystem and registers it in VaultRegistry.
 *
 * @dev A single `createVault()` call atomically deploys three UUPS proxies:
 *      1. RWAVault         — ERC-4626 share token for any tokenised RWA.
 *      2. CapitalFacility  — per-vault settlement token buffer with optional yield deployment.
 *      3. EpochManager     — time-based settlement cycle for this vault.
 *
 *      Post-deployment wiring (performed inside createVault):
 *      - OpenLiquidityRouter and RFQEngine receive REDEEMER_ROLE on the new vault.
 *      - OpenLiquidityRouter receives unlimited spender approval on CapitalFacility.
 *      - Ownership of all three proxies is transferred to the protocol admin (owner).
 *
 *      RFQEngine is shared across all vaults and is injected at initialization time.
 *      VaultFactory itself must hold FACTORY_ROLE in VaultRegistry before calling createVault.
 */
contract VaultFactory is Initializable, OwnableUpgradeable, UUPSUpgradeable {
    // ─────────────────────────── STATE ──────────────────────────────────────

    VaultRegistry public registry;

    /// @notice RWAVault logic contract (UUPS proxy target).
    address public rwavaultImplementation;

    /// @notice CapitalFacility logic contract (UUPS proxy target).
    address public capitalFacilityImplementation;

    /// @notice EpochManager logic contract deployed as a fresh proxy per vault.
    address public epochManagerImplementation;

    /// @notice Receives REDEEMER_ROLE and spender approval on every new vault.
    address public openLiquidityRouter;

    /// @notice Shared RFQEngine — also receives REDEEMER_ROLE on every new vault.
    address public rfqEngine;

    /// @notice Shared SharedSettlementEngine — used to grant REVENUE_MANAGER_ROLE to vault operators.
    address public sharedSettlementEngine;

    // ─────────────────────────── EVENTS ─────────────────────────────────────

    event VaultCreated(
        uint256 indexed vaultId,
        address indexed vault,
        address capitalFacility,
        address epochManager,
        address assetToken,
        address settlementToken,
        address treasury,
        string vaultName,
        string vaultSymbol
    );
    event RWAVaultImplementationUpdated(address indexed oldImpl, address indexed newImpl);
    event CapitalFacilityImplementationUpdated(address indexed oldImpl, address indexed newImpl);
    event EpochManagerImplementationUpdated(address indexed oldImpl, address indexed newImpl);
    event SharedSettlementEngineUpdated(address indexed oldEngine, address indexed newEngine);

    // ─────────────────────────── ERRORS ─────────────────────────────────────

    error ZeroAddress();
    error InvalidEpochDuration();
    error RouterNotSet();
    error RFQEngineNotSet();
    error EpochManagerImplNotSet();
    error ReportedInventoryRequiresEpochs();

    // ─────────────────────────── PARAMS ─────────────────────────────────────

    struct CreateVaultParams {
        /// @notice RWA token the vault will wrap (must already be deployed).
        address assetToken;
        /// @notice Settlement token used for deposits and redemptions (e.g. USDC, USDT, DAI).
        address settlementToken;
        /// @notice IAssetOracle implementation for this asset.
        address assetOracle;
        /// @notice Uniswap V2 router for exchange-rate queries.
        address uniswapRouter;
        /// @notice When true, deploys an EpochManager and enables epoch-based settlement.
        ///         When false, no EpochManager is deployed (epochManager == address(0) in registry).
        bool useEpochs;
        /// @notice EpochManager cycle duration in seconds. Ignored when useEpochs is false.
        uint256 epochDuration;
        /// @notice WETH address used for ETH-denominated price paths.
        address wethToken;
        /// @notice ERC-20 name for vault shares (e.g. "xGOLD Vault").
        string vaultName;
        /// @notice ERC-20 symbol for vault shares (e.g. "xGOLD").
        string vaultSymbol;
        /// @notice Operational operator address.
        ///         Receives VAULT_CURATOR_ROLE + HOST_INTEGRATION_ROLE on OpenLiquidityRouter,
        ///         REVENUE_MANAGER_ROLE on SharedSettlementEngine, and
        ///         FACILITY_OPERATOR_ROLE on the deployed CapitalFacility.
        ///         Pass address(0) to skip — roles can be granted manually later.
        address operator;
        /// @notice Custodian / issuer treasury for this vault.
        ///         Receives USDC on deposit claims and serves as fee fallback in settlement.
        address treasury;
        /// @notice When true (requires `useEpochs`), settlement writes NAV warehouse inventory from the
        ///         operator-reported amount. On-vault asset balance is never used as inventory.
        bool reportedInventoryOnly;
    }

    // ─────────────────────────── INIT ───────────────────────────────────────

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(
        address registry_,
        address rwavaultImplementation_,
        address capitalFacilityImplementation_,
        address epochManagerImplementation_,
        address openLiquidityRouter_,
        address rfqEngine_,
        address sharedSettlementEngine_
    ) public initializer {
        if (registry_ == address(0)) revert ZeroAddress();
        if (rwavaultImplementation_ == address(0)) revert ZeroAddress();
        if (capitalFacilityImplementation_ == address(0)) revert ZeroAddress();
        if (epochManagerImplementation_ == address(0)) revert ZeroAddress();
        if (openLiquidityRouter_ == address(0)) revert ZeroAddress();
        if (rfqEngine_ == address(0)) revert ZeroAddress();
        if (sharedSettlementEngine_ == address(0)) revert ZeroAddress();

        __Ownable_init(_msgSender());
        __UUPSUpgradeable_init();

        registry = VaultRegistry(registry_);
        rwavaultImplementation = rwavaultImplementation_;
        capitalFacilityImplementation = capitalFacilityImplementation_;
        epochManagerImplementation = epochManagerImplementation_;
        openLiquidityRouter = openLiquidityRouter_;
        rfqEngine = rfqEngine_;
        sharedSettlementEngine = sharedSettlementEngine_;
    }

    // ─────────────────────────── EXTERNAL ───────────────────────────────────

    /**
     * @notice Deploy and register a new RWA vault stack.
     *
     * @dev Permissionless — any address may call this function; no whitelist required.
     *      The caller (msg.sender) becomes the owner and DEFAULT_ADMIN_ROLE holder of all
     *      three newly deployed proxies (RWAVault, CapitalFacility, EpochManager).
     *      The shared protocol contracts (OpenLiquidityRouter, SharedSettlementEngine,
     *      RFQEngine) remain under protocol-level ownership and are unaffected.
     *
     * @param p Vault configuration (see CreateVaultParams).
     * @return vaultId          Sequential registry identifier.
     * @return vaultAddr        RWAVault proxy address.
     * @return facilityAddr     CapitalFacility proxy address.
     * @return epochManagerAddr EpochManager proxy address, or address(0) when p.useEpochs is false.
     */
    function createVault(
        CreateVaultParams calldata p
    ) external returns (uint256 vaultId, address vaultAddr, address facilityAddr, address epochManagerAddr) {
        _validate(p);

        if (p.useEpochs) {
            epochManagerAddr = _deployEpochManager(p.epochDuration);
        }

        vaultAddr = _deployRWAVault(p);
        facilityAddr = _deployCapitalFacility(p.settlementToken);

        vaultId = registry.registerVault(
            vaultAddr,
            p.assetToken,
            p.settlementToken,
            facilityAddr,
            rfqEngine,
            p.assetOracle,
            p.uniswapRouter,
            epochManagerAddr,
            p.treasury,
            p.reportedInventoryOnly
        );

        _wireRoles(vaultAddr);

        // Register per-vault operator before transferring ownership (factory still holds admin).
        if (p.operator != address(0)) {
            _registerOperator(vaultId, facilityAddr, epochManagerAddr, p.operator);
        }

        // Transfer vault ownership to the caller — each issuer owns their own vault stack.
        _transferOwnership(vaultAddr, facilityAddr, epochManagerAddr, msg.sender);

        emit VaultCreated(
            vaultId,
            vaultAddr,
            facilityAddr,
            epochManagerAddr,
            p.assetToken,
            p.settlementToken,
            p.treasury,
            p.vaultName,
            p.vaultSymbol
        );
    }

    // ─────────────────────────── OWNER CONFIG ───────────────────────────────

    function setOpenLiquidityRouter(address newRouter) external onlyOwner {
        if (newRouter == address(0)) revert ZeroAddress();
        openLiquidityRouter = newRouter;
    }

    function setRFQEngine(address newEngine) external onlyOwner {
        if (newEngine == address(0)) revert ZeroAddress();
        rfqEngine = newEngine;
    }

    function setRWAVaultImplementation(address newImpl) external onlyOwner {
        if (newImpl == address(0)) revert ZeroAddress();
        emit RWAVaultImplementationUpdated(rwavaultImplementation, newImpl);
        rwavaultImplementation = newImpl;
    }

    function setCapitalFacilityImplementation(address newImpl) external onlyOwner {
        if (newImpl == address(0)) revert ZeroAddress();
        emit CapitalFacilityImplementationUpdated(capitalFacilityImplementation, newImpl);
        capitalFacilityImplementation = newImpl;
    }

    function setEpochManagerImplementation(address newImpl) external onlyOwner {
        if (newImpl == address(0)) revert ZeroAddress();
        emit EpochManagerImplementationUpdated(epochManagerImplementation, newImpl);
        epochManagerImplementation = newImpl;
    }

    function setSharedSettlementEngine(address newEngine) external onlyOwner {
        if (newEngine == address(0)) revert ZeroAddress();
        emit SharedSettlementEngineUpdated(sharedSettlementEngine, newEngine);
        sharedSettlementEngine = newEngine;
    }

    // ─────────────────────────── INTERNAL ───────────────────────────────────

    function _deployEpochManager(uint256 duration) private returns (address) {
        if (epochManagerImplementation == address(0)) revert EpochManagerImplNotSet();
        return
            address(
                new ERC1967Proxy(
                    epochManagerImplementation,
                    abi.encodeWithSelector(EpochManager.initialize.selector, duration)
                )
            );
    }

    function _deployRWAVault(CreateVaultParams calldata p) private returns (address) {
        return
            address(
                new ERC1967Proxy(
                    rwavaultImplementation,
                    abi.encodeWithSelector(
                        RWAVault.initialize.selector,
                        IERC20(p.assetToken),
                        p.vaultName,
                        p.vaultSymbol,
                        p.assetOracle,
                        p.uniswapRouter,
                        p.settlementToken,
                        p.wethToken
                    )
                )
            );
    }

    function _deployCapitalFacility(address settlementToken) private returns (address) {
        return
            address(
                new ERC1967Proxy(
                    capitalFacilityImplementation,
                    abi.encodeWithSelector(
                        CapitalFacility.initialize.selector,
                        settlementToken,
                        openLiquidityRouter,
                        address(this)
                    )
                )
            );
    }

    /**
     * @dev Register `operator` as the per-vault operator atomically.
     *      - FACILITY_OPERATOR_ROLE on the newly deployed CapitalFacility (factory is its admin).
     *      - EPOCH_MANAGER_ROLE on EpochManager (when useEpochs=true) so the operator can
     *        advance epochs via nextEpoch() after settling revenue.
     *      - setVaultOperator(vaultId, operator) on OpenLiquidityRouter  — grants curator +
     *        host-integration rights scoped to this vault only.
     *      - setVaultOperator(vaultId, operator) on SharedSettlementEngine — grants revenue-manager
     *        rights scoped to this vault only.
     *
     *      Requires VaultFactory to hold VAULT_FACTORY_ROLE on OpenLiquidityRouter and
     *      SharedSettlementEngine — grant it once during protocol setup.
     */
    function _registerOperator(
        uint256 vaultId,
        address facilityAddr,
        address epochManagerAddr,
        address operator
    ) private {
        CapitalFacility(facilityAddr).grantRole(keccak256("FACILITY_OPERATOR_ROLE"), operator);

        // Grant EPOCH_MANAGER_ROLE so operator can call nextEpoch() to advance the epoch cycle.
        if (epochManagerAddr != address(0)) {
            EpochManager(epochManagerAddr).grantRole(keccak256("EPOCH_MANAGER_ROLE"), operator);
        }

        IVaultOperatorRegistry(openLiquidityRouter).setVaultOperator(vaultId, operator);
        IVaultOperatorRegistry(sharedSettlementEngine).setVaultOperator(vaultId, operator);
    }

    function _wireRoles(address vaultAddr) private {
        bytes32 redeemerRole = keccak256("REDEEMER_ROLE");
        RWAVault(vaultAddr).grantRole(redeemerRole, openLiquidityRouter);
        RWAVault(vaultAddr).grantRole(redeemerRole, rfqEngine);
    }

    /// @dev `vaultAdmin` is the issuer (msg.sender of createVault) who will own this vault stack.
    function _transferOwnership(
        address vaultAddr,
        address facilityAddr,
        address epochManagerAddr,
        address vaultAdmin
    ) private {
        bytes32 zeroRole = 0x00; // DEFAULT_ADMIN_ROLE

        // RWAVault — factory holds DEFAULT_ADMIN_ROLE (set during _deployRWAVault).
        RWAVault(vaultAddr).grantRole(zeroRole, vaultAdmin);
        RWAVault(vaultAddr).revokeRole(zeroRole, address(this));
        RWAVault(vaultAddr).transferOwnership(vaultAdmin);

        // CapitalFacility — factory was passed as admin_ during initialization.
        CapitalFacility(facilityAddr).grantRole(zeroRole, vaultAdmin);
        CapitalFacility(facilityAddr).revokeRole(zeroRole, address(this));
        CapitalFacility(facilityAddr).transferOwnership(vaultAdmin);

        // EpochManager — only present when vault was created with useEpochs = true.
        if (epochManagerAddr != address(0)) {
            EpochManager(epochManagerAddr).grantRole(zeroRole, vaultAdmin);
            EpochManager(epochManagerAddr).revokeRole(zeroRole, address(this));
            EpochManager(epochManagerAddr).transferOwnership(vaultAdmin);
        }
    }

    function _validate(CreateVaultParams calldata p) internal pure {
        if (p.assetToken == address(0)) revert ZeroAddress();
        if (p.settlementToken == address(0)) revert ZeroAddress();
        if (p.assetOracle == address(0)) revert ZeroAddress();
        if (p.uniswapRouter == address(0)) revert ZeroAddress();
        if (p.useEpochs && p.epochDuration == 0) revert InvalidEpochDuration();
        if (p.reportedInventoryOnly && !p.useEpochs) revert ReportedInventoryRequiresEpochs();
        if (p.wethToken == address(0)) revert ZeroAddress();
        if (p.treasury == address(0)) revert ZeroAddress();
    }

    function _authorizeUpgrade(address) internal override onlyOwner {}

    uint256[45] private __gap;
}
