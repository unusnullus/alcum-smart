// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";

import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";

import {VaultLib} from "./libraries/VaultLib.sol";

/**
 * @title VaultRegistry
 * @notice Authoritative registry of every RWA vault deployed by VaultFactory.
 *
 * @dev Access control:
 *      FACTORY_ROLE   — granted to VaultFactory; the only address that may register new vaults.
 *      owner          — protocol multisig; soft-pause vaults and rotate oracle / epoch manager / treasury.
 *
 *      Sequential vaultIds start at 1 (0 is reserved as "not found" in reverse lookups).
 */
contract VaultRegistry is Initializable, OwnableUpgradeable, AccessControlUpgradeable, UUPSUpgradeable {
    // ─────────────────────────── ROLES ──────────────────────────────────────

    bytes32 public constant FACTORY_ROLE = keccak256("FACTORY_ROLE");

    // ─────────────────────────── STATE ──────────────────────────────────────

    /// @notice Next vaultId to be assigned. Incremented after each registration.
    uint256 public nextVaultId;

    /// @notice vaultId → VaultRecord.
    mapping(uint256 => VaultLib.VaultRecord) private _vaults;

    /// @notice vault proxy address → vaultId (reverse lookup).
    mapping(address => uint256) public vaultIdByAddress;

    /// @notice vaultId → whether OpenLiquidityRouter / SharedSettlementEngine may mint this vault's asset token.
    mapping(uint256 => bool) public mintAuthorized;

    /// @notice Default max oracle age for freshness checks (FIND-029). `0` disables checks.
    uint256 public defaultMaxOracleAge;

    /// @notice Per-vault override. `0` → use `defaultMaxOracleAge`.
    mapping(uint256 => uint256) private _vaultMaxOracleAge;
    /// @dev True when an explicit per-vault age was set (including zero = disable for that vault).
    mapping(uint256 => bool) private _vaultMaxOracleAgeSet;

    // ─────────────────────────── EVENTS ─────────────────────────────────────

    event VaultRegistered(
        uint256 indexed vaultId,
        address indexed vault,
        address indexed assetToken,
        address capitalFacility,
        address rfqEngine
    );
    event VaultStatusChanged(uint256 indexed vaultId, bool active);
    event VaultOracleUpdated(uint256 indexed vaultId, address indexed oldOracle, address indexed newOracle);
    event VaultEpochManagerUpdated(uint256 indexed vaultId, address indexed oldEm, address indexed newEm);
    event VaultTreasuryUpdated(uint256 indexed vaultId, address indexed oldTreasury, address indexed newTreasury);
    event VaultMintAuthorized(uint256 indexed vaultId, address indexed assetToken, address indexed by);
    event DefaultMaxOracleAgeUpdated(uint256 oldAge, uint256 newAge);
    event VaultMaxOracleAgeUpdated(uint256 indexed vaultId, uint256 maxAge, bool explicit);

    // ─────────────────────────── ERRORS ─────────────────────────────────────

    error ZeroAddress();
    error VaultAlreadyRegistered(address vault);
    error ReportedInventoryRequiresEpochs();
    error MintNotAuthorized(uint256 vaultId);
    error MintAlreadyAuthorized(uint256 vaultId);
    error NotAssetMinterAdmin(address caller, address assetToken);
    error AssetTokenNotAccessControl(address assetToken);

    // ─────────────────────────── INIT ───────────────────────────────────────

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /**
     * @notice Initialize the registry proxy. Can be called only once.
     * @param admin_ Owner and DEFAULT_ADMIN_ROLE holder. Must be non-zero.
     */
    function initialize(address admin_) public initializer {
        if (admin_ == address(0)) revert ZeroAddress();
        __Ownable_init(admin_);
        __AccessControl_init();
        __UUPSUpgradeable_init();
        _grantRole(DEFAULT_ADMIN_ROLE, admin_);
        nextVaultId = 1;
        // FIND-029: 25 hours default; ops may raise per-vault / globally as bypass.
        defaultMaxOracleAge = 25 hours;
    }

    // ─────────────────────────── FACTORY ────────────────────────────────────

    /**
     * @notice Register a newly deployed vault ecosystem.
     * @dev Called exclusively by VaultFactory immediately after deploying all proxies.
     *      epochManager may be address(0) for vaults created without epoch-based settlement.
     * @return vaultId Sequential identifier assigned to this vault.
     */
    function registerVault(
        address vault,
        address assetToken,
        address settlementToken,
        address capitalFacility,
        address rfqEngine,
        address assetOracle,
        address uniswapRouter,
        address epochManager,
        address treasury,
        bool reportedInventoryOnly
    ) external onlyRole(FACTORY_ROLE) returns (uint256 vaultId) {
        if (vault == address(0)) revert ZeroAddress();
        if (assetToken == address(0)) revert ZeroAddress();
        if (settlementToken == address(0)) revert ZeroAddress();
        if (capitalFacility == address(0)) revert ZeroAddress();
        if (rfqEngine == address(0)) revert ZeroAddress();
        if (assetOracle == address(0)) revert ZeroAddress();
        if (uniswapRouter == address(0)) revert ZeroAddress();
        if (treasury == address(0)) revert ZeroAddress();
        // epochManager may be address(0) for non-epoch vaults
        if (reportedInventoryOnly && epochManager == address(0)) revert ReportedInventoryRequiresEpochs();
        if (vaultIdByAddress[vault] != 0) revert VaultAlreadyRegistered(vault);

        vaultId = nextVaultId++;

        _vaults[vaultId] = VaultLib.VaultRecord({
            vault: vault,
            assetToken: assetToken,
            settlementToken: settlementToken,
            capitalFacility: capitalFacility,
            rfqEngine: rfqEngine,
            assetOracle: assetOracle,
            uniswapRouter: uniswapRouter,
            epochManager: epochManager,
            active: true,
            treasury: treasury,
            reportedInventoryOnly: reportedInventoryOnly
        });

        vaultIdByAddress[vault] = vaultId;

        emit VaultRegistered(vaultId, vault, assetToken, capitalFacility, rfqEngine);
    }

    /**
     * @notice Authorize minting paths for a vault (deposit approve settle + revenue distribute).
     * @dev Callable only by the admin of `MINTER_ROLE` on the vault's asset token.
     *      Issuer onboarding: call this before granting the shared router/engine `MINTER_ROLE`
     *      on the asset token so rogue vaults cannot use the global minter grant.
     */
    function authorizeVaultMint(uint256 vaultId) external {
        _requireExists(vaultId);
        if (mintAuthorized[vaultId]) revert MintAlreadyAuthorized(vaultId);

        address assetToken = _vaults[vaultId].assetToken;
        bytes32 minterRole = keccak256("MINTER_ROLE");

        bytes32 adminRole;
        try IAccessControl(assetToken).getRoleAdmin(minterRole) returns (bytes32 role) {
            adminRole = role;
        } catch {
            revert AssetTokenNotAccessControl(assetToken);
        }

        if (!IAccessControl(assetToken).hasRole(adminRole, msg.sender)) {
            revert NotAssetMinterAdmin(msg.sender, assetToken);
        }

        mintAuthorized[vaultId] = true;
        emit VaultMintAuthorized(vaultId, assetToken, msg.sender);
    }

    /// @notice Whether deposit approve-settle and revenue distribution may mint for `vaultId`.
    function isMintAuthorized(uint256 vaultId) external view returns (bool) {
        return mintAuthorized[vaultId];
    }

    // ─────────────────────────── PROTOCOL ADMIN ─────────────────────────────

    /**
     * @notice Activate or deactivate a vault (pauses new deposits and redemptions).
     * @dev A deactivated vault still allows existing RFQ fills and pending redemption
     *      claims to complete (consumers decide exact gates).
     */
    function setVaultActive(uint256 vaultId, bool active) external onlyOwner {
        _requireExists(vaultId);
        _vaults[vaultId].active = active;
        emit VaultStatusChanged(vaultId, active);
    }

    /**
     * @notice Replace the price oracle for a vault.
     * @dev Allows oracle migration without redeploying the vault. The new oracle must
     *      implement IAssetOracle and return prices with 8 decimal precision.
     */
    function setVaultOracle(uint256 vaultId, address newOracle) external onlyOwner {
        _requireExists(vaultId);
        if (newOracle == address(0)) revert ZeroAddress();

        address old = _vaults[vaultId].assetOracle;
        _vaults[vaultId].assetOracle = newOracle;
        emit VaultOracleUpdated(vaultId, old, newOracle);
    }

    /**
     * @notice Replace the epoch manager for a vault.
     * @dev Used when migrating to a new EpochManager implementation or adjusting
     *      settlement cycle parameters that require a fresh deployment.
     */
    function setVaultEpochManager(uint256 vaultId, address newEm) external onlyOwner {
        _requireExists(vaultId);
        if (newEm == address(0)) revert ZeroAddress();

        address old = _vaults[vaultId].epochManager;
        _vaults[vaultId].epochManager = newEm;
        emit VaultEpochManagerUpdated(vaultId, old, newEm);
    }

    /**
     * @notice Replace the custodian treasury for a vault.
     * @dev Receives USDC from deposit claims and serves as the fee-routing fallback
     *      for this vault in SharedSettlementEngine.
     */
    function setVaultTreasury(uint256 vaultId, address newTreasury) external onlyOwner {
        _requireExists(vaultId);
        if (newTreasury == address(0)) revert ZeroAddress();

        address old = _vaults[vaultId].treasury;
        _vaults[vaultId].treasury = newTreasury;
        emit VaultTreasuryUpdated(vaultId, old, newTreasury);
    }

    /// @notice Set protocol-wide default max oracle age (`0` disables freshness checks).
    function setDefaultMaxOracleAge(uint256 newAge) external onlyOwner {
        emit DefaultMaxOracleAgeUpdated(defaultMaxOracleAge, newAge);
        defaultMaxOracleAge = newAge;
    }

    /**
     * @notice Set per-vault max oracle age override.
     * @dev Pass `clear=true` to remove the override (falls back to default).
     *      Pass `clear=false, maxAge=0` to disable checks for this vault only.
     */
    function setVaultMaxOracleAge(uint256 vaultId, uint256 maxAge, bool clear) external onlyOwner {
        _requireExists(vaultId);
        if (clear) {
            delete _vaultMaxOracleAge[vaultId];
            delete _vaultMaxOracleAgeSet[vaultId];
            emit VaultMaxOracleAgeUpdated(vaultId, 0, false);
            return;
        }
        _vaultMaxOracleAge[vaultId] = maxAge;
        _vaultMaxOracleAgeSet[vaultId] = true;
        emit VaultMaxOracleAgeUpdated(vaultId, maxAge, true);
    }

    // ─────────────────────────── VIEWS ──────────────────────────────────────

    /// @notice Effective max oracle age for `vaultId` (per-vault override or default).
    function effectiveMaxOracleAge(uint256 vaultId) external view returns (uint256) {
        _requireExists(vaultId);
        if (_vaultMaxOracleAgeSet[vaultId]) return _vaultMaxOracleAge[vaultId];
        return defaultMaxOracleAge;
    }

    /// @notice Full registry record. Reverts if `vaultId` has never been registered.
    function getVault(uint256 vaultId) external view returns (VaultLib.VaultRecord memory) {
        _requireExists(vaultId);
        return _vaults[vaultId];
    }

    /**
     * @notice Whether the vault is marked active.
     * @dev Returns `false` for unregistered ids (default mapping value) without reverting.
     */
    function isActive(uint256 vaultId) external view returns (bool) {
        return _vaults[vaultId].active;
    }

    /// @notice Number of registered vaults (`nextVaultId - 1`).
    function totalVaults() external view returns (uint256) {
        return nextVaultId - 1;
    }

    // ─────────────────────────── INTERNAL ───────────────────────────────────

    function _requireExists(uint256 vaultId) internal view {
        if (_vaults[vaultId].vault == address(0)) revert VaultLib.VaultNotFound(vaultId);
    }

    function _authorizeUpgrade(address) internal override onlyOwner {}

    /**
     * @dev Storage gap for future variable additions. Reduce this size by the number
     *      of slots added in subsequent upgrades.
     */
    /// @dev Reduced by 3 for defaultMaxOracleAge + two oracle-age mappings.
    uint256[43] private __gap;
}
