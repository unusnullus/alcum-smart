// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";

import {VaultLib} from "./libraries/VaultLib.sol";

/**
 * @title VaultRegistry
 * @notice Authoritative registry of every RWA vault deployed by VaultFactory.
 *
 * @dev Access control:
 *      FACTORY_ROLE   — granted to VaultFactory; the only address that may register new vaults.
 *      GOVERNOR_ROLE  — intended for an on-chain Timelock (AlcumGovernor); may toggle vault
 *                       activity and update per-vault oracle and epoch-manager references.
 *      owner          — protocol multisig; may also perform governance actions and grant roles.
 *
 *      Sequential vaultIds start at 1 (0 is reserved as "not found" in reverse lookups).
 */
contract VaultRegistry is Initializable, OwnableUpgradeable, AccessControlUpgradeable, UUPSUpgradeable {
    // ─────────────────────────── ROLES ──────────────────────────────────────

    bytes32 public constant FACTORY_ROLE = keccak256("FACTORY_ROLE");

    /**
     * @notice Role for on-chain governance proposals.
     *         Grants permission to:
     *           - toggle vault active/inactive
     *           - rotate the vault's price oracle
     *           - rotate the vault's epoch manager
     * @dev Assign to an AlcumGovernor Timelock contract.
     */
    bytes32 public constant GOVERNOR_ROLE = keccak256("GOVERNOR_ROLE");

    // ─────────────────────────── STATE ──────────────────────────────────────

    /// @notice Next vaultId to be assigned. Incremented after each registration.
    uint256 public nextVaultId;

    /// @notice vaultId → VaultRecord.
    mapping(uint256 => VaultLib.VaultRecord) private _vaults;

    /// @notice vault proxy address → vaultId (reverse lookup).
    mapping(address => uint256) public vaultIdByAddress;

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
    event GovernorGranted(address indexed account);

    // ─────────────────────────── ERRORS ─────────────────────────────────────

    error ZeroAddress();
    error VaultAlreadyRegistered(address vault);
    error Unauthorized();
    error ReportedInventoryRequiresEpochs();

    // ─────────────────────────── INIT ───────────────────────────────────────

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(address admin_) public initializer {
        require(admin_ != address(0), "VaultRegistry: zero admin");
        __Ownable_init(admin_);
        __AccessControl_init();
        __UUPSUpgradeable_init();
        _grantRole(DEFAULT_ADMIN_ROLE, admin_);
        nextVaultId = 1;
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

    // ─────────────────────────── GOVERNANCE ─────────────────────────────────

    /**
     * @notice Grant GOVERNOR_ROLE to a Timelock controller.
     * @dev Wire this after deploying the AlcumGovernor + Timelock pair.
     */
    function grantGovernorRole(address timelock) external onlyOwner {
        if (timelock == address(0)) revert ZeroAddress();
        _grantRole(GOVERNOR_ROLE, timelock);
        emit GovernorGranted(timelock);
    }

    /**
     * @notice Activate or deactivate a vault (pauses new deposits and redemptions).
     * @dev Callable by owner or GOVERNOR_ROLE. A deactivated vault still allows
     *      existing RFQ fills and pending redemption claims to complete.
     */
    function setVaultActive(uint256 vaultId, bool active) external {
        if (!hasRole(GOVERNOR_ROLE, msg.sender) && msg.sender != owner()) revert Unauthorized();
        _requireExists(vaultId);
        _vaults[vaultId].active = active;
        emit VaultStatusChanged(vaultId, active);
    }

    /**
     * @notice Replace the price oracle for a vault.
     * @dev Governance proposal target — allows oracle migration without redeploying
     *      the vault. The new oracle must implement IAssetOracle and return prices
     *      with 8 decimal precision.
     */
    function setVaultOracle(uint256 vaultId, address newOracle) external {
        if (!hasRole(GOVERNOR_ROLE, msg.sender) && msg.sender != owner()) revert Unauthorized();
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
    function setVaultEpochManager(uint256 vaultId, address newEm) external {
        if (!hasRole(GOVERNOR_ROLE, msg.sender) && msg.sender != owner()) revert Unauthorized();
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
    function setVaultTreasury(uint256 vaultId, address newTreasury) external {
        if (!hasRole(GOVERNOR_ROLE, msg.sender) && msg.sender != owner()) revert Unauthorized();
        _requireExists(vaultId);
        if (newTreasury == address(0)) revert ZeroAddress();

        address old = _vaults[vaultId].treasury;
        _vaults[vaultId].treasury = newTreasury;
        emit VaultTreasuryUpdated(vaultId, old, newTreasury);
    }

    // ─────────────────────────── VIEWS ──────────────────────────────────────

    function getVault(uint256 vaultId) external view returns (VaultLib.VaultRecord memory) {
        _requireExists(vaultId);
        return _vaults[vaultId];
    }

    function isActive(uint256 vaultId) external view returns (bool) {
        return _vaults[vaultId].active;
    }

    function totalVaults() external view returns (uint256) {
        return nextVaultId - 1;
    }

    // ─────────────────────────── INTERNAL ───────────────────────────────────

    function _requireExists(uint256 vaultId) internal view {
        if (_vaults[vaultId].vault == address(0)) revert VaultLib.VaultNotFound(vaultId);
    }

    function _authorizeUpgrade(address) internal override onlyOwner {}

    uint256[47] private __gap;
}
