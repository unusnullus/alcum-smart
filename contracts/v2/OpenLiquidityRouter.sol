// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import {ReentrancyGuardUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/interfaces/IERC20Metadata.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {IUniswapV2Router02} from "@uniswap/v2-periphery/contracts/interfaces/IUniswapV2Router02.sol";

import {IAssetOracle} from "./interfaces/IAssetOracle.sol";
import {IEpochManager} from "./interfaces/IEpochManager.sol";
import {IERC20Mintable} from "../interfaces/IERC20Mintable.sol";
import {SwapLib} from "../libraries/SwapLib.sol";

import {VaultLib} from "./libraries/VaultLib.sol";
import {OracleLib} from "./libraries/OracleLib.sol";
import {VaultRegistry} from "./VaultRegistry.sol";
import {RWAVault} from "./RWAVault.sol";

/**
 * @title OpenLiquidityRouter
 * @notice Asset-agnostic entry point for all vaults in the protocol.
 *
 * @dev All operations are keyed by vaultId (from VaultRegistry). The router
 *      holds REDEEMER_ROLE on each RWAVault and unlimited spender approval on
 *      each CapitalFacility — both granted automatically by VaultFactory.
 *
 *      Deposit path (curator-gated):
 *        zapAndDeposit  →  approveDeposit (curator settles)  →  claimDeposit (user)
 *
 *      On approve the curator moves USDC to treasury, mints asset tokens if needed,
 *      and deposits into the RWAVault — vault shares are escrowed on this router until claim.
 *
 *      Queued redemption path (curator-gated, T+days):
 *        requestRedeem  →  approveRedeem (curator)  →  claimRedeem
 *
 *      For T+0 instant redemptions, users interact directly with RFQEngine —
 *      this router is not in that execution path.
 *
 *      Role layout:
 *        DEFAULT_ADMIN_ROLE    — protocol multisig
 *        VAULT_CURATOR_ROLE    — global super-curator (protocol admin); fallback for all vaults
 *        VAULT_FACTORY_ROLE    — VaultFactory; may register per-vault operators via setVaultOperator
 *
 *      Per-vault operator:
 *        vaultOperator[vaultId] — the issuer's own backend/hot-wallet; has curator rights
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

    bytes32 public constant VAULT_CURATOR_ROLE = keccak256("VAULT_CURATOR_ROLE");
    /// @notice Granted to VaultFactory so it can register per-vault operators.
    bytes32 public constant VAULT_FACTORY_ROLE    = keccak256("VAULT_FACTORY_ROLE");

    // ─────────────────────────── STATE ──────────────────────────────────────

    VaultRegistry public registry;

    /// @notice Unused — slot retained for UUPS layout compatibility. Per-vault treasury is in VaultRegistry.
    address public treasury;

    /// @notice Per-vault operator: the issuer's backend hot-wallet for that specific vault.
    ///         Has curator rights scoped exclusively to its vaultId.
    mapping(uint256 => address) public vaultOperator;

    // vaultId → depositId → Deposit
    mapping(uint256 => mapping(bytes32 => VaultLib.Deposit)) private _deposits;
    mapping(uint256 => bytes32[]) private _pendingDepositIds;
    /// @dev 1-based index into `_pendingDepositIds` for O(1) removal (FIND-020).
    mapping(uint256 => mapping(bytes32 => uint256)) private _pendingDepositIndex;
    mapping(uint256 => mapping(address => bytes32[])) private _userDeposits;
    mapping(uint256 => mapping(address => mapping(bytes32 => uint256))) private _userDepositIndex;

    // vaultId → redeemId → RedeemRequest
    mapping(uint256 => mapping(bytes32 => VaultLib.RedeemRequest)) private _redeems;
    mapping(uint256 => bytes32[]) private _pendingRedeemIds;
    mapping(uint256 => mapping(bytes32 => uint256)) private _pendingRedeemIndex;
    mapping(uint256 => mapping(address => bytes32[])) private _userRedeems;
    mapping(uint256 => mapping(address => mapping(bytes32 => uint256))) private _userRedeemIndex;

    /// @notice Per-vault ERC-20 allowlist for zap `tokenIn` (swap path only).
    ///         Settlement token and native ETH are always allowed and never stored here.
    mapping(uint256 => mapping(address => bool)) private _zapTokenAllowed;
    mapping(uint256 => address[]) private _zapTokenAllowedList;

    /// @dev Settlement tokens reserved for pending deposits and approved unclaimed redeems.
    mapping(uint256 => uint256) private _committedLiability;

    /// @dev Count of unapproved pending deposits per user (FIND-020 spam bound).
    mapping(uint256 => mapping(address => uint256)) private _openPendingDeposits;

    /// @notice Max unapproved pending deposits a single address may hold per vault.
    uint256 public constant MAX_PENDING_DEPOSITS_PER_USER = 50;

    // ─────────────────────────── EVENTS ─────────────────────────────────────

    event VaultOperatorSet(uint256 indexed vaultId, address indexed operator);

    event DepositCreated(uint256 indexed vaultId, bytes32 indexed depositId, address indexed user, uint256 tokenAmount);
    event DepositApproved(
        uint256 indexed vaultId,
        bytes32 indexed depositId,
        uint256 approvedTokenAmount,
        uint256 approvedShares
    );
    event DepositDeclined(uint256 indexed vaultId, bytes32 indexed depositId, address user, uint256 refund);
    event DepositClaimed(uint256 indexed vaultId, bytes32 indexed depositId, address beneficiary, uint256 shares);
    event AssetInventoryToppedUp(uint256 indexed vaultId, uint256 amount);
    event ZapTokenAllowlistUpdated(uint256 indexed vaultId, address indexed token, bool allowed);

    event RedeemRequested(uint256 indexed vaultId, bytes32 indexed redeemId, address indexed user, uint256 shares);
    event RedeemApproved(uint256 indexed vaultId, bytes32 indexed redeemId, uint256 tokenAmount);
    event RedeemClaimed(uint256 indexed vaultId, bytes32 indexed redeemId, address user, uint256 tokenAmount);
    event RedeemDeclined(uint256 indexed vaultId, bytes32 indexed redeemId, address user, uint256 shares);
    event RegistryUpdated(address indexed previous, address indexed current);

    // ─────────────────────────── ERRORS ─────────────────────────────────────

    error ZeroAmount();
    error ZeroAddress();
    error VaultNotActive(uint256 vaultId);
    error InvalidSlippage();
    error InsufficientFacilityBalance();
    error InsufficientCommittedCoverage(uint256 idle, uint256 committed, uint256 requested);
    error NotRedeemOwner();
    error NotDepositOwner();
    error Unauthorized();
    error AlreadyClaimed();
    error EpochNotActive(uint256 vaultId);
    error RedeemPayoutTooHigh(uint256 requested, uint256 maxAllowed);
    error CannotRescueVaultShares(address vaultShareToken);
    error InvalidAssetPrice();
    error TokenNotAllowlisted(address token);
    error SettlementTokenAlwaysAllowed();
    error EthAlwaysAllowed();
    error TooManyPendingDeposits(address user, uint256 current, uint256 maxAllowed);
    error UnexpectedETH();

    // ─────────────────────────── INIT ───────────────────────────────────────

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /**
     * @notice Initialize the router proxy. Can be called only once.
     * @param registry_ VaultRegistry used to resolve per-vault addresses.
     * @param admin_    Owner, DEFAULT_ADMIN_ROLE and VAULT_CURATOR_ROLE holder.
     */
    function initialize(address registry_, address admin_) public initializer {
        if (registry_ == address(0)) revert ZeroAddress();
        if (admin_ == address(0)) revert ZeroAddress();

        __AccessControl_init();
        __Ownable_init(admin_);
        __Pausable_init();
        __ReentrancyGuard_init();
        __UUPSUpgradeable_init();

        _grantRole(DEFAULT_ADMIN_ROLE, admin_);
        _grantRole(VAULT_CURATOR_ROLE, admin_);

        registry = VaultRegistry(registry_);
    }

    // ─────────────────────────── DEPOSIT FLOW ───────────────────────────────

    /**
     * @notice Swap any ERC-20 (or native ETH) to USDC and register a pending deposit.
     * @dev USDC output is routed directly into the vault's CapitalFacility.
     *      The deposit enters a curator review queue; shares are issued only after approval.
     * @param vaultId      Target vault (from VaultRegistry).
     * @param tokenIn      Input token. Pass address(0) for native ETH.
     * @param amount       Amount of tokenIn (ignored when ETH is sent via msg.value).
     * @param depositId    Caller-supplied unique identifier for this deposit.
     * @param slippageBps  Fallback swap slippage in basis points when `minAmountOut` is 0 (max 1000 = 10%).
     * @param minAmountOut Minimum settlement tokens from swap (FIND-022). Ignored on direct settlement deposit.
     */
    function zapAndDeposit(
        uint256 vaultId,
        IERC20 tokenIn,
        uint256 amount,
        bytes32 depositId,
        uint256 slippageBps,
        uint256 minAmountOut
    ) external payable nonReentrant whenNotPaused {
        if (amount == 0) revert ZeroAmount();
        if (slippageBps > 1000) revert InvalidSlippage();

        VaultLib.VaultRecord memory v = _activeVault(vaultId);

        uint256 tokenReceived;

        // When the caller deposits the settlement token directly (e.g. USDC), skip the
        // Uniswap swap and transfer it straight into the CapitalFacility.
        // Reject attached ETH so it cannot be silently stranded on the router (FIND-033).
        // Credit the measured facility balance delta so fee-on-transfer tokens cannot
        // over-credit the pending deposit (FIND-015).
        if (address(tokenIn) != address(0) && address(tokenIn) == v.settlementToken) {
            if (msg.value != 0) revert UnexpectedETH();
            uint256 balBefore = IERC20(v.settlementToken).balanceOf(v.capitalFacility);
            IERC20(v.settlementToken).safeTransferFrom(msg.sender, v.capitalFacility, amount);
            tokenReceived = IERC20(v.settlementToken).balanceOf(v.capitalFacility) - balBefore;
        } else {
            if (!_isZapSwapTokenAllowed(vaultId, address(tokenIn), v.settlementToken)) {
                revert TokenNotAllowlisted(address(tokenIn));
            }
            tokenReceived = SwapLib.zapIn(
                tokenIn,
                amount,
                slippageBps,
                minAmountOut,
                IUniswapV2Router02(v.uniswapRouter),
                IERC20(v.settlementToken),
                v.capitalFacility,
                address(this),
                msg.sender,
                msg.value,
                RWAVault(v.vault).swapIntermediary()
            );
        }

        if (tokenReceived == 0) revert ZeroAmount();

        uint256 openPending = _openPendingDeposits[vaultId][msg.sender];
        if (openPending >= MAX_PENDING_DEPOSITS_PER_USER) {
            revert TooManyPendingDeposits(msg.sender, openPending, MAX_PENDING_DEPOSITS_PER_USER);
        }

        VaultLib.recordDeposit(
            _deposits[vaultId],
            _pendingDepositIds[vaultId],
            _pendingDepositIndex[vaultId],
            _userDeposits[vaultId],
            _userDepositIndex[vaultId],
            depositId,
            tokenReceived,
            msg.sender
        );
        _openPendingDeposits[vaultId][msg.sender] = openPending + 1;

        _increaseCommitted(vaultId, tokenReceived);

        emit DepositCreated(vaultId, depositId, msg.sender, tokenReceived);
    }

    /**
     * @notice Optional pre-mint of asset tokens onto this router for upcoming approvals.
     * @dev Curator may top up inventory to avoid auto-mint during approveDeposit.
     *      Leftover balance rolls forward to future deposits.
     */
    function curatorTopUpAsset(uint256 vaultId, uint256 amount) external nonReentrant whenNotPaused {
        _checkCurator(vaultId);
        _requireActiveVault(vaultId);
        if (amount == 0) revert ZeroAmount();

        VaultLib.VaultRecord memory v = _activeVault(vaultId);
        IERC20Mintable(v.assetToken).mint(address(this), amount);

        emit AssetInventoryToppedUp(vaultId, amount);
    }

    /**
     * @notice Curator approves a deposit, settles USDC, mints/deposits asset tokens, and escrows shares.
     * @param approvedAmount Must equal the full deposit amount.
     * @param assetPrice     Oracle price (8 decimal precision) used to calculate asset units.
     */
    function approveDeposit(
        uint256 vaultId,
        bytes32 depositId,
        uint256 approvedAmount,
        uint256 assetPrice
    ) external nonReentrant whenNotPaused {
        _checkCurator(vaultId);
        _requireActiveVault(vaultId);
        _checkEpochActive(vaultId);

        VaultLib.VaultRecord memory vRecord = registry.getVault(vaultId);
        _requireFreshOracle(vaultId, vRecord.assetOracle);

        uint8 oracleDecimals = IAssetOracle(vRecord.assetOracle).decimals();
        uint8 assetDecimals = IERC20Metadata(vRecord.assetToken).decimals();
        uint8 settlementDecimals = IERC20Metadata(vRecord.settlementToken).decimals();

        VaultLib.approveDeposit(
            _deposits[vaultId],
            depositId,
            approvedAmount,
            assetPrice,
            oracleDecimals,
            assetDecimals,
            settlementDecimals
        );

        VaultLib.VaultRecord memory v = _activeVault(vaultId);
        VaultLib.Deposit storage d = _deposits[vaultId][depositId];

        if (!registry.isMintAuthorized(vaultId)) revert VaultRegistry.MintNotAuthorized(vaultId);

        uint256 shares = _settleApprovedDeposit(v, d);
        _decreaseCommitted(vaultId, d.approvedAmount);

        VaultLib.removeFromArray(
            _pendingDepositIds[vaultId],
            _pendingDepositIndex[vaultId],
            depositId
        );
        _decrementOpenPending(vaultId, d.user);

        emit DepositApproved(vaultId, depositId, approvedAmount, shares);
    }

    /// @notice Curator declines a pending deposit. USDC is refunded from CapitalFacility.
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
        VaultLib.removeFromArray(
            _pendingDepositIds[vaultId],
            _pendingDepositIndex[vaultId],
            depositId
        );
        VaultLib.removeUserEntry(
            _userDeposits[vaultId],
            _userDepositIndex[vaultId],
            user,
            depositId
        );
        _decrementOpenPending(vaultId, user);

        if (refund > 0) {
            _decreaseCommitted(vaultId, refund);
            IERC20(v.settlementToken).safeTransferFrom(v.capitalFacility, user, refund);
        }

        emit DepositDeclined(vaultId, depositId, user, refund);
    }

    /**
     * @notice Claim an approved deposit — transfers escrowed vault shares to the depositor.
     * @return shares Vault shares transferred to the depositor.
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
        if (msg.sender != d.user) revert NotDepositOwner();

        shares = d.approvedShares;
        if (shares == 0) revert ZeroAmount();

        d.claimedBy = msg.sender;
        VaultLib.removeUserEntry(
            _userDeposits[vaultId],
            _userDepositIndex[vaultId],
            d.user,
            depositId
        );

        IERC20(v.vault).safeTransfer(d.user, shares);

        emit DepositClaimed(vaultId, depositId, d.user, shares);
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
            _pendingRedeemIndex[vaultId],
            _userRedeems[vaultId],
            _userRedeemIndex[vaultId],
            redeemId,
            msg.sender,
            shares
        );

        emit RedeemRequested(vaultId, redeemId, msg.sender, shares);
    }

    /**
     * @notice Curator approves a queued redemption with a settlement token payout amount.
     * @dev `tokenAmount` must not exceed the oracle-implied settlement value of the locked
     *      shares. Operators must recall externally deployed capital first.
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
        _requireFreshOracle(vaultId, v.assetOracle);

        VaultLib.RedeemRequest storage r = _redeems[vaultId][redeemId];

        if (r.user == address(0)) revert VaultLib.RedeemNotFound();
        if (r.approved) revert VaultLib.RedeemAlreadyApproved();
        if (r.claimed) revert VaultLib.RedeemAlreadyClaimed();

        uint256 maxPayout = _maxRedeemPayout(v, r.shares);
        if (tokenAmount > maxPayout) revert RedeemPayoutTooHigh(tokenAmount, maxPayout);

        uint256 idle = IERC20(v.settlementToken).balanceOf(v.capitalFacility);
        uint256 committed = _committedLiability[vaultId];
        if (idle < committed + tokenAmount) {
            revert InsufficientCommittedCoverage(idle, committed, tokenAmount);
        }

        _increaseCommitted(vaultId, tokenAmount);

        r.approved = true;
        r.tokenAmount = tokenAmount;

        VaultLib.removeFromArray(
            _pendingRedeemIds[vaultId],
            _pendingRedeemIndex[vaultId],
            redeemId
        );

        emit RedeemApproved(vaultId, redeemId, tokenAmount);
    }

    /**
     * @notice Claim an approved redemption — burns shares and receives settlement tokens from CapitalFacility.
     * @dev Redeemed RWA is sent to the vault treasury; settlement tokens are pulled from CapitalFacility.
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

        _decreaseCommitted(vaultId, tokenAmount);

        IERC4626(v.vault).redeem(r.shares, v.treasury, address(this));
        IERC20(v.settlementToken).safeTransferFrom(v.capitalFacility, msg.sender, tokenAmount);

        VaultLib.removeUserEntry(
            _userRedeems[vaultId],
            _userRedeemIndex[vaultId],
            msg.sender,
            redeemId
        );

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
        VaultLib.removeFromArray(
            _pendingRedeemIds[vaultId],
            _pendingRedeemIndex[vaultId],
            redeemId
        );
        VaultLib.removeUserEntry(
            _userRedeems[vaultId],
            _userRedeemIndex[vaultId],
            user,
            redeemId
        );

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

    /**
     * @notice Allow or disallow an ERC-20 as `tokenIn` for zap swaps on a vault.
     * @dev Settlement token and native ETH are always allowed and cannot be toggled.
     *      Callable by the per-vault operator or global `VAULT_CURATOR_ROLE`.
     */
    function setZapTokenAllowed(uint256 vaultId, address token, bool allowed) external {
        _checkCurator(vaultId);
        _setZapTokenAllowed(vaultId, token, allowed);
    }

    /// @notice Batch variant of {setZapTokenAllowed}.
    function setZapTokensAllowed(uint256 vaultId, address[] calldata tokens, bool allowed) external {
        _checkCurator(vaultId);
        uint256 len = tokens.length;
        for (uint256 i; i < len; ++i) {
            _setZapTokenAllowed(vaultId, tokens[i], allowed);
        }
    }

    function pause() external onlyOwner {
        _pause();
    }
    function unpause() external onlyOwner {
        _unpause();
    }

    function setRegistry(address newRegistry) external onlyOwner {
        if (newRegistry == address(0)) revert ZeroAddress();
        emit RegistryUpdated(address(registry), newRegistry);
        registry = VaultRegistry(newRegistry);
    }

    /**
     * @notice Recover ERC-20 tokens accidentally sent to this contract.
     * @dev Cannot rescue registered vault share tokens (ERC-4626 share addresses).
     */
    function rescueTokens(address token, address to, uint256 amount) external onlyOwner nonReentrant {
        if (to == address(0)) revert ZeroAddress();
        if (registry.vaultIdByAddress(token) != 0) revert CannotRescueVaultShares(token);
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

    /// @notice Number of unapproved pending deposits for `user` on `vaultId`.
    function getOpenPendingDeposits(uint256 vaultId, address user) external view returns (uint256) {
        return _openPendingDeposits[vaultId][user];
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

    /// @notice Whether `token` may be used as zap `tokenIn` for `vaultId`.
    /// @dev Native ETH (`address(0)`) and the vault settlement token are always true.
    function isZapTokenAllowed(uint256 vaultId, address token) external view returns (bool) {
        address settlementToken = registry.getVault(vaultId).settlementToken;
        return _isZapSwapTokenAllowed(vaultId, token, settlementToken);
    }

    /// @notice ERC-20 tokens explicitly allowlisted for zap swaps (excludes settlement token and ETH).
    function getZapAllowedTokens(uint256 vaultId) external view returns (address[] memory) {
        return _zapTokenAllowedList[vaultId];
    }

    /// @notice Settlement tokens reserved for pending deposits and approved unclaimed redeems.
    function getCommittedLiability(uint256 vaultId) external view returns (uint256) {
        return _committedLiability[vaultId];
    }

    /// @notice Idle facility balance minus committed liability (floored at zero).
    function getAvailableIdle(uint256 vaultId) external view returns (uint256) {
        VaultLib.VaultRecord memory v = registry.getVault(vaultId);
        uint256 idle = IERC20(v.settlementToken).balanceOf(v.capitalFacility);
        uint256 committed = _committedLiability[vaultId];
        return idle > committed ? idle - committed : 0;
    }

    function getAssetPrice(uint256 vaultId) external view returns (uint256) {
        return IAssetOracle(_activeVault(vaultId).assetOracle).price();
    }

    // ─────────────────────────── INTERNAL ───────────────────────────────────

    function _activeVault(uint256 vaultId) internal view returns (VaultLib.VaultRecord memory v) {
        v = registry.getVault(vaultId);
        if (!v.active) revert VaultNotActive(vaultId);
    }

    function _requireActiveVault(uint256 vaultId) internal view {
        if (!registry.isActive(vaultId)) revert VaultNotActive(vaultId);
    }

    /// @dev FIND-029: revert on state-changing paths when the vault oracle is stale.
    function _requireFreshOracle(uint256 vaultId, address oracle) internal view {
        OracleLib.requireFresh(oracle, registry.effectiveMaxOracleAge(vaultId));
    }

    /// @dev Reverts unless caller is the per-vault operator OR holds global VAULT_CURATOR_ROLE.
    function _checkCurator(uint256 vaultId) internal view {
        if (msg.sender != vaultOperator[vaultId] && !hasRole(VAULT_CURATOR_ROLE, msg.sender))
            revert Unauthorized();
    }

    function _setZapTokenAllowed(uint256 vaultId, address token, bool allowed) private {
        if (token == address(0)) revert EthAlwaysAllowed();

        address settlementToken = registry.getVault(vaultId).settlementToken;
        if (token == settlementToken) revert SettlementTokenAlwaysAllowed();

        if (_zapTokenAllowed[vaultId][token] == allowed) return;

        _zapTokenAllowed[vaultId][token] = allowed;

        if (allowed) {
            _zapTokenAllowedList[vaultId].push(token);
        } else {
            address[] storage list = _zapTokenAllowedList[vaultId];
            uint256 len = list.length;
            for (uint256 i; i < len; ++i) {
                if (list[i] == token) {
                    list[i] = list[len - 1];
                    list.pop();
                    break;
                }
            }
        }

        emit ZapTokenAllowlistUpdated(vaultId, token, allowed);
    }

    function _isZapSwapTokenAllowed(
        uint256 vaultId,
        address token,
        address settlementToken
    ) internal view returns (bool) {
        if (token == address(0) || token == settlementToken) return true;
        return _zapTokenAllowed[vaultId][token];
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

    function _increaseCommitted(uint256 vaultId, uint256 amount) internal {
        _committedLiability[vaultId] += amount;
    }

    function _decreaseCommitted(uint256 vaultId, uint256 amount) internal {
        _committedLiability[vaultId] -= amount;
    }

    function _decrementOpenPending(uint256 vaultId, address user) internal {
        uint256 openPending = _openPendingDeposits[vaultId][user];
        if (openPending > 0) {
            _openPendingDeposits[vaultId][user] = openPending - 1;
        }
    }

    /**
     * @dev Pull approved USDC to treasury, mint asset shortfall if needed, deposit into vault.
     *      Vault shares are escrowed on this router until claimDeposit.
     */
    function _settleApprovedDeposit(
        VaultLib.VaultRecord memory v,
        VaultLib.Deposit storage d
    ) internal returns (uint256 shares) {
        uint256 need = d.approvedAssetAmount;
        if (need == 0) revert ZeroAmount();

        IERC20(v.settlementToken).safeTransferFrom(v.capitalFacility, v.treasury, d.approvedAmount);

        uint256 pool = IERC20(v.assetToken).balanceOf(address(this));
        if (pool < need) {
            IERC20Mintable(v.assetToken).mint(address(this), need - pool);
        }

        IERC20(v.assetToken).forceApprove(v.vault, need);
        shares = IERC4626(v.vault).deposit(need, address(this));
        // FIND-031: ERC-4626 can round a non-zero asset amount down to zero shares.
        if (shares == 0) revert ZeroAmount();
        d.approvedShares = shares;
    }

    /// @dev Oracle-implied settlement payout for `shares` locked in a redeem request.
    function _maxRedeemPayout(VaultLib.VaultRecord memory v, uint256 shares) internal view returns (uint256) {
        uint256 assetAmount = IERC4626(v.vault).convertToAssets(shares);
        uint256 assetPrice = IAssetOracle(v.assetOracle).price();
        if (assetPrice == 0) revert InvalidAssetPrice();

        uint8 oracleDecimals = IAssetOracle(v.assetOracle).decimals();
        uint8 assetDecimals = IERC20Metadata(v.assetToken).decimals();
        uint8 settlementDecimals = IERC20Metadata(v.settlementToken).decimals();

        return VaultLib.assetToSettlementAmount(
            assetAmount,
            assetPrice,
            assetDecimals,
            oracleDecimals,
            settlementDecimals
        );
    }

    function _authorizeUpgrade(address) internal override onlyOwner {}

    /// @dev Reduced by 5 for FIND-020 index maps + open-pending counter.
    uint256[39] private __gap;
}
