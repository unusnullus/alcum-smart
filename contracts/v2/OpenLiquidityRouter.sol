// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import {ReentrancyGuardUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {IUniswapV2Router02} from "@uniswap/v2-periphery/contracts/interfaces/IUniswapV2Router02.sol";

import {IAssetOracle} from "./interfaces/IAssetOracle.sol";
import {IEpochManager} from "./interfaces/IEpochManager.sol";
import {ITokenVesting} from "./interfaces/ITokenVesting.sol";
import {IERC20Mintable} from "../interfaces/IERC20Mintable.sol";
import {SwapLib} from "../libraries/SwapLib.sol";

import {VaultLib} from "./libraries/VaultLib.sol";
import {VaultRegistry} from "./VaultRegistry.sol";

/**
 * @title OpenLiquidityRouter
 * @notice Asset-agnostic entry point for all vaults in the protocol.
 *
 * @dev All operations are keyed by vaultId (from VaultRegistry). The router
 *      holds REDEEMER_ROLE on each RWAVault and unlimited spender approval on
 *      each CapitalFacility — both granted automatically by VaultFactory.
 *
 *      Deposit path (curator-gated):
 *        zapAndDeposit  →  approveDeposit (curator)  →  claimDeposit
 *        or:
 *        registerExternalDeposit  →  approveExternalDeposit  →  claimDeposit
 *
 *      Queued redemption path (curator-gated, T+days):
 *        requestRedeem  →  approveRedeem (curator)  →  claimRedeem
 *
 *      For T+0 instant redemptions, users interact directly with RFQEngine —
 *      this router is not in that execution path.
 *
 *      Vesting path (optional per-vault):
 *        claimDepositWithVesting — delivers vault shares into a TokenVesting
 *        schedule instead of transferring them directly to the beneficiary.
 *
 *      Role layout:
 *        DEFAULT_ADMIN_ROLE    — protocol multisig
 *        VAULT_CURATOR_ROLE    — global super-curator (protocol admin); fallback for all vaults
 *        HOST_INTEGRATION_ROLE — global host integration (protocol admin); fallback for all vaults
 *        VAULT_FACTORY_ROLE    — VaultFactory; may register per-vault operators via setVaultOperator
 *
 *      Per-vault operator:
 *        vaultOperator[vaultId] — the issuer's own backend/hot-wallet; has curator + host rights
 *        only for that specific vault. Set atomically by VaultFactory on vault creation.
 */
contract OpenLiquidityRouter is
    Initializable,
    AccessControlUpgradeable,
    OwnableUpgradeable,
    PausableUpgradeable,
    ReentrancyGuardUpgradeable,
    UUPSUpgradeable
{
    using SafeERC20 for IERC20;
    using VaultLib for VaultLib.Deposit;

    // ─────────────────────────── ROLES ──────────────────────────────────────

    bytes32 public constant VAULT_CURATOR_ROLE    = keccak256("VAULT_CURATOR_ROLE");
    bytes32 public constant HOST_INTEGRATION_ROLE = keccak256("HOST_INTEGRATION_ROLE");
    /// @notice Granted to VaultFactory so it can register per-vault operators.
    bytes32 public constant VAULT_FACTORY_ROLE    = keccak256("VAULT_FACTORY_ROLE");

    // ─────────────────────────── STATE ──────────────────────────────────────

    VaultRegistry public registry;

    /// @notice Destination for USDC collected during deposit claims (custodian / treasury).
    address public treasury;

    /// @notice Per-vault operator: the issuer's backend hot-wallet for that specific vault.
    ///         Has curator + host-integration rights scoped exclusively to its vaultId.
    mapping(uint256 => address) public vaultOperator;

    // vaultId → depositId → Deposit
    mapping(uint256 => mapping(bytes32 => VaultLib.Deposit)) private _deposits;
    mapping(uint256 => bytes32[]) private _pendingDepositIds;
    mapping(uint256 => mapping(address => bytes32[])) private _userDeposits;
    mapping(uint256 => mapping(address => uint256)) private _userNonces;

    // vaultId → redeemId → RedeemRequest
    mapping(uint256 => mapping(bytes32 => VaultLib.RedeemRequest)) private _redeems;
    mapping(uint256 => bytes32[]) private _pendingRedeemIds;
    mapping(uint256 => mapping(address => bytes32[])) private _userRedeems;

    /**
     * @notice Optional per-vault vesting configuration.
     * @dev When vestingContract is non-zero, callers may use claimDepositWithVesting()
     *      to receive vault shares as a TokenVesting schedule rather than a direct transfer.
     */
    struct VaultVestingConfig {
        address vestingContract;
        uint256 defaultCliff; // seconds
        uint256 defaultDuration; // seconds
    }

    /// @notice vaultId → VaultVestingConfig.
    mapping(uint256 => VaultVestingConfig) public vestingConfigs;

    // ─────────────────────────── EVENTS ─────────────────────────────────────

    event TreasuryUpdated(address indexed oldTreasury, address indexed newTreasury);
    event VaultVestingConfigSet(uint256 indexed vaultId, address vestingContract, uint256 cliff, uint256 duration);
    event VaultOperatorSet(uint256 indexed vaultId, address indexed operator);

    event DepositCreated(uint256 indexed vaultId, bytes32 indexed depositId, address indexed user, uint256 tokenAmount);
    event DepositApproved(uint256 indexed vaultId, bytes32 indexed depositId, uint256 approvedTokenAmount);
    event DepositDeclined(uint256 indexed vaultId, bytes32 indexed depositId, address user, uint256 refund);
    event DepositClaimed(uint256 indexed vaultId, bytes32 indexed depositId, address beneficiary, uint256 shares);
    event ExternalDepositRegistered(
        uint256 indexed vaultId,
        bytes32 indexed depositId,
        address beneficiary,
        bytes32 tag
    );

    event RedeemRequested(uint256 indexed vaultId, bytes32 indexed redeemId, address indexed user, uint256 shares);
    event RedeemApproved(uint256 indexed vaultId, bytes32 indexed redeemId, uint256 tokenAmount);
    event RedeemClaimed(uint256 indexed vaultId, bytes32 indexed redeemId, address user, uint256 tokenAmount);
    event RedeemDeclined(uint256 indexed vaultId, bytes32 indexed redeemId, address user, uint256 shares);

    // ─────────────────────────── ERRORS ─────────────────────────────────────

    error ZeroAmount();
    error ZeroAddress();
    error VaultNotActive(uint256 vaultId);
    error InvalidSlippage();
    error InsufficientFacilityBalance();
    error NotRedeemOwner();
    error Unauthorized();
    error AlreadyClaimed();
    error VestingNotConfigured(uint256 vaultId);
    error TreasuryNotSet();
    error EpochNotActive(uint256 vaultId);

    // ─────────────────────────── INIT ───────────────────────────────────────

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(address registry_, address admin_, address treasury_) public initializer {
        if (registry_ == address(0)) revert ZeroAddress();
        if (admin_ == address(0)) revert ZeroAddress();
        if (treasury_ == address(0)) revert ZeroAddress();

        __AccessControl_init();
        __Ownable_init(admin_);
        __Pausable_init();
        __ReentrancyGuard_init();
        __UUPSUpgradeable_init();

        _grantRole(DEFAULT_ADMIN_ROLE, admin_);
        _grantRole(VAULT_CURATOR_ROLE, admin_);

        registry = VaultRegistry(registry_);
        treasury = treasury_;
    }

    // ─────────────────────────── DEPOSIT FLOW ───────────────────────────────

    /**
     * @notice Swap any ERC-20 (or native ETH) to USDC and register a pending deposit.
     * @dev USDC output is routed directly into the vault's CapitalFacility.
     *      The deposit enters a curator review queue; shares are issued only after approval.
     * @param vaultId     Target vault (from VaultRegistry).
     * @param tokenIn     Input token. Pass address(0) for native ETH.
     * @param amount      Amount of tokenIn (ignored when ETH is sent via msg.value).
     * @param depositId   Caller-supplied unique identifier for this deposit.
     * @param slippageBps Maximum acceptable swap slippage in basis points (max 1000 = 10%).
     */
    function zapAndDeposit(
        uint256 vaultId,
        IERC20 tokenIn,
        uint256 amount,
        bytes32 depositId,
        uint256 slippageBps
    ) external payable nonReentrant whenNotPaused {
        if (amount == 0) revert ZeroAmount();
        if (slippageBps > 1000) revert InvalidSlippage();

        VaultLib.VaultRecord memory v = _activeVault(vaultId);

        uint256 tokenReceived;

        // When the caller deposits the settlement token directly (e.g. USDC), skip the
        // Uniswap swap and transfer it straight into the CapitalFacility.
        if (address(tokenIn) != address(0) && address(tokenIn) == v.settlementToken) {
            IERC20(v.settlementToken).safeTransferFrom(msg.sender, v.capitalFacility, amount);
            tokenReceived = amount;
        } else {
            tokenReceived = SwapLib.zapIn(
                tokenIn,
                amount,
                slippageBps,
                IUniswapV2Router02(v.uniswapRouter),
                IERC20(v.settlementToken),
                v.capitalFacility,
                address(this),
                msg.sender,
                msg.value
            );
        }

        if (tokenReceived == 0) revert ZeroAmount();

        VaultLib.recordDeposit(
            _deposits[vaultId],
            _pendingDepositIds[vaultId],
            _userDeposits[vaultId],
            depositId,
            tokenReceived,
            msg.sender
        );

        emit DepositCreated(vaultId, depositId, msg.sender, tokenReceived);
    }

    /**
     * @notice Curator approves a standard deposit and locks the asset price.
     * @param assetPrice  Oracle price (8 decimal precision) used to calculate asset units.
     */
    function approveDeposit(
        uint256 vaultId,
        bytes32 depositId,
        uint256 approvedAmount,
        uint256 assetPrice
    ) external whenNotPaused {
        _checkCurator(vaultId);
        _requireActiveVault(vaultId);
        _checkEpochActive(vaultId);

        uint8 oracleDecimals = IAssetOracle(registry.getVault(vaultId).assetOracle).decimals();

        VaultLib.approveDeposit(_deposits[vaultId], depositId, approvedAmount, assetPrice, oracleDecimals);

        VaultLib.removeFromArray(_pendingDepositIds[vaultId], depositId);

        emit DepositApproved(vaultId, depositId, approvedAmount);
    }

    /// @notice Curator declines a pending deposit. Settlement tokens are refunded from CapitalFacility.
    function declineDeposit(
        uint256 vaultId,
        bytes32 depositId
    ) external nonReentrant whenNotPaused {
        _checkCurator(vaultId);
        _checkEpochActive(vaultId);
        VaultLib.VaultRecord memory v = _activeVault(vaultId);
        VaultLib.Deposit storage d = _deposits[vaultId][depositId];

        if (d.user == address(0)) revert VaultLib.DepositNotFound();
        if (d.approved) revert VaultLib.DepositAlreadyApproved();

        address user = d.user;
        uint256 refund = d.amount;

        delete _deposits[vaultId][depositId];
        VaultLib.removeFromArray(_pendingDepositIds[vaultId], depositId);
        VaultLib.removeUserEntry(_userDeposits[vaultId], user, depositId);

        IERC20(v.settlementToken).safeTransferFrom(v.capitalFacility, user, refund);

        emit DepositDeclined(vaultId, depositId, user, refund);
    }

    /**
     * @notice Claim an approved deposit: mint asset tokens, deposit into the vault, receive shares.
     * @return shares Vault shares minted for the beneficiary.
     */
    function claimDeposit(
        uint256 vaultId,
        bytes32 depositId
    ) external nonReentrant whenNotPaused returns (uint256 shares) {
        _checkEpochActive(vaultId);
        VaultLib.VaultRecord memory v = _activeVault(vaultId);
        VaultLib.Deposit storage d = _deposits[vaultId][depositId];

        if (d.user == address(0)) revert VaultLib.DepositNotFound();
        if (!d.approved) revert VaultLib.DepositNotApproved();
        if (d.claimedBy != address(0)) revert AlreadyClaimed();

        address beneficiary = d.beneficiary == address(0) ? d.user : d.beneficiary;
        if (treasury == address(0)) revert TreasuryNotSet();

        // Pull settlement tokens from CapitalFacility and forward to treasury (payment for custodied RWA).
        IERC20(v.settlementToken).safeTransferFrom(v.capitalFacility, treasury, d.approvedAmount);
        IERC20Mintable(v.assetToken).mint(address(this), d.approvedAssetAmount);
        IERC20(v.assetToken).forceApprove(v.vault, d.approvedAssetAmount);
        shares = IERC4626(v.vault).deposit(d.approvedAssetAmount, beneficiary);

        d.claimedBy = msg.sender;
        VaultLib.removeUserEntry(_userDeposits[vaultId], d.user, depositId);

        emit DepositClaimed(vaultId, depositId, beneficiary, shares);
    }

    /**
     * @notice Claim an approved deposit via a TokenVesting schedule.
     *
     * @dev Vault shares are minted to the vault's configured vestingContract rather
     *      than directly to the beneficiary. A linear vesting schedule is created for
     *      the beneficiary inside that contract.
     *
     *      Pre-conditions:
     *        1. Curator has approved the deposit.
     *        2. A VaultVestingConfig is set for this vault (setVaultVestingConfig).
     *        3. This router holds VESTING_CREATOR on the vestingContract.
     *
     * @param vaultId   Target vault.
     * @param depositId Approved deposit identifier.
     * @param cliff     Cliff override in seconds. 0 uses the vault's configured default.
     * @param duration  Duration override in seconds. 0 uses the vault's configured default.
     * @return shares   Vault shares locked inside the vesting contract.
     */
    function claimDepositWithVesting(
        uint256 vaultId,
        bytes32 depositId,
        uint256 cliff,
        uint256 duration
    ) external nonReentrant whenNotPaused returns (uint256 shares) {
        _checkEpochActive(vaultId);
        VaultLib.VaultRecord memory v = _activeVault(vaultId);
        VaultLib.Deposit storage d = _deposits[vaultId][depositId];
        VaultVestingConfig memory cfg = vestingConfigs[vaultId];

        if (d.user == address(0)) revert VaultLib.DepositNotFound();
        if (!d.approved) revert VaultLib.DepositNotApproved();
        if (d.claimedBy != address(0)) revert AlreadyClaimed();
        if (cfg.vestingContract == address(0)) revert VestingNotConfigured(vaultId);

        address beneficiary = d.beneficiary == address(0) ? d.user : d.beneficiary;
        uint256 effectiveCliff = cliff > 0 ? cliff : cfg.defaultCliff;
        uint256 effectiveDuration = duration > 0 ? duration : cfg.defaultDuration;
        if (treasury == address(0)) revert TreasuryNotSet();

        IERC20(v.settlementToken).safeTransferFrom(v.capitalFacility, treasury, d.approvedAmount);
        IERC20Mintable(v.assetToken).mint(address(this), d.approvedAssetAmount);
        IERC20(v.assetToken).forceApprove(v.vault, d.approvedAssetAmount);
        shares = IERC4626(v.vault).deposit(d.approvedAssetAmount, cfg.vestingContract);

        ITokenVesting(cfg.vestingContract).createVestingSchedule(
            beneficiary,
            block.timestamp,
            effectiveCliff,
            effectiveDuration,
            1, // 1-second slicePeriod = fully linear release
            false, // non-revocable by default
            shares
        );

        d.claimedBy = msg.sender;
        VaultLib.removeUserEntry(_userDeposits[vaultId], d.user, depositId);

        emit DepositClaimed(vaultId, depositId, beneficiary, shares);
    }

    // ─────────────────────────── EXTERNAL DEPOSITS ──────────────────────────

    /**
     * @notice Register an off-chain / host-to-host deposit. No settlement tokens move at this step.
     * @dev HOST_INTEGRATION_ROLE is required. The curator must subsequently call
     *      approveExternalDeposit before the beneficiary can claim.
     */
    function registerExternalDeposit(
        uint256 vaultId,
        address beneficiary,
        uint256 tokenAmount,
        bytes32 tag
    ) external whenNotPaused returns (bytes32 depositId) {
        _checkHostIntegration(vaultId);
        _requireActiveVault(vaultId);
        if (beneficiary == address(0)) revert ZeroAddress();
        if (tokenAmount == 0) revert ZeroAmount();

        uint256 nonce = _userNonces[vaultId][msg.sender]++;

        depositId = VaultLib.recordExternalDeposit(
            _deposits[vaultId],
            _pendingDepositIds[vaultId],
            _userDeposits[vaultId],
            tokenAmount,
            beneficiary,
            tag,
            msg.sender,
            nonce
        );

        emit ExternalDepositRegistered(vaultId, depositId, beneficiary, tag);
    }

    /// @notice Curator approves an external deposit with a specific asset price.
    function approveExternalDeposit(
        uint256 vaultId,
        bytes32 depositId,
        uint256 approvedTokenAmount,
        uint256 assetPrice
    ) external whenNotPaused {
        _checkCurator(vaultId);
        _requireActiveVault(vaultId);
        _checkEpochActive(vaultId);

        uint8 oracleDecimals = IAssetOracle(registry.getVault(vaultId).assetOracle).decimals();

        VaultLib.approveExternalDeposit(_deposits[vaultId], depositId, approvedTokenAmount, assetPrice, oracleDecimals);

        VaultLib.removeFromArray(_pendingDepositIds[vaultId], depositId);

        emit DepositApproved(vaultId, depositId, approvedTokenAmount);
    }

    // ─────────────────────────── QUEUED REDEEM FLOW ─────────────────────────

    /**
     * @notice Lock vault shares to queue a curator-approved redemption.
     * @dev For T+0 instant redemptions, use RFQEngine directly.
     */
    function requestRedeem(uint256 vaultId, uint256 shares, bytes32 redeemId) external nonReentrant whenNotPaused {
        _requireActiveVault(vaultId);
        if (shares == 0) revert ZeroAmount();

        VaultLib.VaultRecord memory v = _activeVault(vaultId);
        IERC20(v.vault).safeTransferFrom(msg.sender, address(this), shares);

        VaultLib.recordRedeemRequest(
            _redeems[vaultId],
            _pendingRedeemIds[vaultId],
            _userRedeems[vaultId],
            redeemId,
            msg.sender,
            shares
        );

        emit RedeemRequested(vaultId, redeemId, msg.sender, shares);
    }

    /**
     * @notice Curator approves a queued redemption with a settlement token payout amount.
     * @dev Verifies the vault's CapitalFacility holds sufficient idle settlement tokens before
     *      approving. Operators must recall any externally deployed capital first.
     */
    function approveRedeem(
        uint256 vaultId,
        bytes32 redeemId,
        uint256 tokenAmount
    ) external whenNotPaused {
        _checkCurator(vaultId);
        _requireActiveVault(vaultId);
        if (tokenAmount == 0) revert ZeroAmount();

        VaultLib.VaultRecord memory v = _activeVault(vaultId);
        VaultLib.RedeemRequest storage r = _redeems[vaultId][redeemId];

        if (r.user == address(0)) revert VaultLib.RedeemNotFound();
        if (r.approved) revert VaultLib.RedeemAlreadyApproved();
        if (r.claimed) revert VaultLib.RedeemAlreadyClaimed();

        if (IERC20(v.settlementToken).balanceOf(v.capitalFacility) < tokenAmount) revert InsufficientFacilityBalance();

        r.approved = true;
        r.tokenAmount = tokenAmount;

        VaultLib.removeFromArray(_pendingRedeemIds[vaultId], redeemId);

        emit RedeemApproved(vaultId, redeemId, tokenAmount);
    }

    /**
     * @notice Claim an approved redemption — burns shares and receives settlement tokens from CapitalFacility.
     * @return tokenAmount Settlement tokens transferred to the caller.
     */
    function claimRedeem(
        uint256 vaultId,
        bytes32 redeemId
    ) external nonReentrant whenNotPaused returns (uint256 tokenAmount) {
        VaultLib.VaultRecord memory v = _activeVault(vaultId);
        VaultLib.RedeemRequest storage r = _redeems[vaultId][redeemId];

        if (r.user == address(0)) revert VaultLib.RedeemNotFound();
        if (r.user != msg.sender) revert NotRedeemOwner();
        if (!r.approved) revert VaultLib.RedeemNotApproved();
        if (r.claimed) revert VaultLib.RedeemAlreadyClaimed();

        tokenAmount = r.tokenAmount;
        r.claimed = true;

        IERC4626(v.vault).redeem(r.shares, v.capitalFacility, address(this));
        IERC20(v.settlementToken).safeTransferFrom(v.capitalFacility, msg.sender, tokenAmount);

        VaultLib.removeUserEntry(_userRedeems[vaultId], msg.sender, redeemId);

        emit RedeemClaimed(vaultId, redeemId, msg.sender, tokenAmount);
    }

    /// @notice Curator declines a queued redemption — locked shares are returned to the user.
    function declineRedeem(
        uint256 vaultId,
        bytes32 redeemId
    ) external nonReentrant whenNotPaused {
        _checkCurator(vaultId);
        VaultLib.VaultRecord memory v = _activeVault(vaultId);
        VaultLib.RedeemRequest storage r = _redeems[vaultId][redeemId];

        if (r.user == address(0)) revert VaultLib.RedeemNotFound();
        if (r.approved) revert VaultLib.RedeemAlreadyApproved();
        if (r.claimed) revert VaultLib.RedeemAlreadyClaimed();

        address user = r.user;
        uint256 shares = r.shares;

        delete _redeems[vaultId][redeemId];
        VaultLib.removeFromArray(_pendingRedeemIds[vaultId], redeemId);
        VaultLib.removeUserEntry(_userRedeems[vaultId], user, redeemId);

        IERC20(v.vault).safeTransfer(user, shares);

        emit RedeemDeclined(vaultId, redeemId, user, shares);
    }

    // ─────────────────────────── ADMIN ──────────────────────────────────────

    /**
     * @notice Register the per-vault operator for a newly created vault.
     * @dev Called by VaultFactory atomically on createVault. May also be called by owner
     *      to rotate the operator. Pass address(0) to clear.
     */
    function setVaultOperator(uint256 vaultId, address operator) external {
        if (!hasRole(VAULT_FACTORY_ROLE, msg.sender) && msg.sender != owner()) revert Unauthorized();
        vaultOperator[vaultId] = operator;
        emit VaultOperatorSet(vaultId, operator);
    }

    function pause() external onlyOwner {
        _pause();
    }
    function unpause() external onlyOwner {
        _unpause();
    }

    /**
     * @notice Configure TokenVesting integration for a vault.
     * @dev The vestingContract must hold sufficient vault shares before any
     *      claimDepositWithVesting calls, and must recognise this router as a creator.
     * @param vestingContract TokenVesting contract address. Must not be zero.
     * @param defaultCliff    Default cliff in seconds (may be overridden per claim).
     * @param defaultDuration Default vesting duration in seconds.
     */
    function setVaultVestingConfig(
        uint256 vaultId,
        address vestingContract,
        uint256 defaultCliff,
        uint256 defaultDuration
    ) external onlyOwner {
        _requireActiveVault(vaultId);
        if (vestingContract == address(0)) revert ZeroAddress();
        vestingConfigs[vaultId] = VaultVestingConfig({
            vestingContract: vestingContract,
            defaultCliff: defaultCliff,
            defaultDuration: defaultDuration
        });
        emit VaultVestingConfigSet(vaultId, vestingContract, defaultCliff, defaultDuration);
    }

    function setRegistry(address newRegistry) external onlyOwner {
        if (newRegistry == address(0)) revert ZeroAddress();
        registry = VaultRegistry(newRegistry);
    }

    /// @notice Update the treasury address that receives USDC on deposit claims.
    function setTreasury(address newTreasury) external onlyOwner {
        if (newTreasury == address(0)) revert ZeroAddress();
        emit TreasuryUpdated(treasury, newTreasury);
        treasury = newTreasury;
    }

    /**
     * @notice Recover any ERC-20 token accidentally sent to this contract.
     * @dev Does not apply to vault shares locked for pending redeems — those are
     *      tracked in _redeems and must be released via declineRedeem / claimRedeem.
     */
    function rescueTokens(address token, address to, uint256 amount) external onlyOwner {
        if (to == address(0)) revert ZeroAddress();
        IERC20(token).safeTransfer(to, amount);
    }

    // ─────────────────────────── VIEWS ──────────────────────────────────────

    function getDeposit(uint256 vaultId, bytes32 depositId) external view returns (VaultLib.Deposit memory) {
        return _deposits[vaultId][depositId];
    }

    function getPendingDepositIds(uint256 vaultId) external view returns (bytes32[] memory) {
        return _pendingDepositIds[vaultId];
    }

    function getUserDeposits(uint256 vaultId, address user) external view returns (bytes32[] memory) {
        return _userDeposits[vaultId][user];
    }

    function getRedeem(uint256 vaultId, bytes32 redeemId) external view returns (VaultLib.RedeemRequest memory) {
        return _redeems[vaultId][redeemId];
    }

    function getPendingRedeemIds(uint256 vaultId) external view returns (bytes32[] memory) {
        return _pendingRedeemIds[vaultId];
    }

    function getUserRedeems(uint256 vaultId, address user) external view returns (bytes32[] memory) {
        return _userRedeems[vaultId][user];
    }

    function getAssetPrice(uint256 vaultId) external view returns (uint256) {
        return IAssetOracle(_activeVault(vaultId).assetOracle).price();
    }

    function getVestingConfig(uint256 vaultId) external view returns (VaultVestingConfig memory) {
        return vestingConfigs[vaultId];
    }

    // ─────────────────────────── INTERNAL ───────────────────────────────────

    function _activeVault(uint256 vaultId) internal view returns (VaultLib.VaultRecord memory v) {
        v = registry.getVault(vaultId);
        if (!v.active) revert VaultNotActive(vaultId);
    }

    function _requireActiveVault(uint256 vaultId) internal view {
        if (!registry.isActive(vaultId)) revert VaultNotActive(vaultId);
    }

    /// @dev Reverts unless caller is the per-vault operator OR holds global VAULT_CURATOR_ROLE.
    function _checkCurator(uint256 vaultId) internal view {
        if (msg.sender != vaultOperator[vaultId] && !hasRole(VAULT_CURATOR_ROLE, msg.sender))
            revert Unauthorized();
    }

    /// @dev Reverts unless caller is the per-vault operator OR holds global HOST_INTEGRATION_ROLE.
    function _checkHostIntegration(uint256 vaultId) internal view {
        if (msg.sender != vaultOperator[vaultId] && !hasRole(HOST_INTEGRATION_ROLE, msg.sender))
            revert Unauthorized();
    }

    /**
     * @dev When the vault has an EpochManager, reverts if the current epoch has ended.
     *      Mirrors the `whenEpochActive` behaviour from the v1 Zapper.
     *      Vaults created without an EpochManager (epochManager == address(0)) are always considered active.
     */
    function _checkEpochActive(uint256 vaultId) internal view {
        address em = registry.getVault(vaultId).epochManager;
        if (em != address(0) && IEpochManager(em).timeLeftInEpoch() == 0) {
            revert EpochNotActive(vaultId);
        }
    }

    function _authorizeUpgrade(address) internal override onlyOwner {}

    uint256[43] private __gap;
}
