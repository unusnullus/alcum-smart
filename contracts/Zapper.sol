// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {ReentrancyGuardUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";

import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";

import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";

import {IUniswapV2Router02} from "@uniswap/v2-periphery/contracts/interfaces/IUniswapV2Router02.sol";

import {ICopperPriceConsumer} from "./interfaces/ICopperPriceConsumer.sol";
import {IEpochManager} from "./interfaces/IEpochManager.sol";
import {IERC20Mintable} from "./interfaces/IERC20Mintable.sol";
import {ITokenVesting} from "./interfaces/ITokenVesting.sol";
import {Silo} from "./Silo.sol";

import {DepositLib} from "./libraries/DepositLib.sol";
import {SwapLib} from "./libraries/SwapLib.sol";
import {DepositViewLib} from "./libraries/DepositViewLib.sol";
import {PermitLib} from "./libraries/PermitLib.sol";
/**
 * @title Zapper
 * @notice A DeFi protocol contract that allows users to zap various tokens into the xCUP vault
 * @dev This contract enables users to deposit various tokens (USDC, ETH, etc.) which are converted
 *      to USDC and then processed through an approval system. Vault curators can approve or decline
 *      deposits before they are converted to CUP tokens and deposited into the xCUP vault.
 *
 *      The contract supports both direct deposits and external deposits (for host-to-host integrations).
 *      It integrates with Uniswap for token swaps and uses a Silo contract for USDC management.
 */
contract Zapper is
    Initializable,
    AccessControlUpgradeable,
    OwnableUpgradeable,
    PausableUpgradeable,
    ReentrancyGuardUpgradeable
{
    using SafeERC20 for IERC20;

    /// @notice Role identifier for vault curators who can approve/decline deposits
    /// @dev Granted to addresses that can approve user deposits for vault entry
    bytes32 public constant VAULT_CURATOR_ROLE = keccak256("VAULT_CURATOR_ROLE");

    /// @notice Role identifier for host-to-host integrations (e.g., backend adapter)
    /// @dev Granted to external systems that can register deposits on behalf of users
    bytes32 public constant HOST_INTEGRATION_ROLE = keccak256("HOST_INTEGRATION_ROLE");

    /// @notice CUP token contract for vault deposits
    /// @dev The underlying asset of the xCUP vault
    IERC20 private _cup;

    /// @notice USDC token contract for deposit processing
    /// @dev Primary stablecoin used for deposit value calculations
    IERC20 private _usdc;

    /// @notice xCUP vault contract (ERC4626 compliant)
    /// @dev The target vault where approved deposits are sent
    IERC4626 private _vault;

    /// @notice Uniswap V2 router for token swaps
    /// @dev Used to convert various tokens to USDC during zapping
    IUniswapV2Router02 private _router;

    /// @notice Copper price oracle consumer
    /// @dev Provides copper spot prices for CUP token conversions
    ICopperPriceConsumer private _copperPriceConsumer;

    /// @notice Silo contract that holds USDC during operations
    /// @dev Temporary storage for USDC tokens with pre-approved spending
    Silo private _silo;

    /// @notice Epoch manager for time-based operations
    /// @dev Controls when deposits can be made based on epoch timing
    IEpochManager private _epochManager;

    /// @notice Mapping of deposit IDs to deposit information
    /// @dev Stores all deposit data indexed by unique deposit ID
    mapping(bytes32 depositId => DepositLib.Deposit) private _approvedDeposits;

    /// @notice Array of pending deposit IDs awaiting curator approval
    /// @dev Used to iterate over pending deposits for batch operations
    bytes32[] private _pendingDepositIds;

    /// @notice Mapping of user addresses to their deposit IDs
    /// @dev Allows users to query all their deposits
    mapping(address => bytes32[]) private _userDeposits;

    /// @notice Mapping of user addresses to their nonce for deposit ID generation
    /// @dev Ensures unique deposit IDs for each user (used for receive/fallback and external deposits)
    mapping(address => uint256) private _userNonces;

    /// @notice TokenVesting contract for automatic governance token vesting on deposit claims
    ITokenVesting private _tokenVesting;

    /// @notice Governance token (ERC20Votes) to be vested upon deposit claim
    IERC20Mintable private _governanceToken;

    /// @notice Cliff duration in seconds for auto-created vesting schedules
    uint256 private _vestingCliff;

    /// @notice Total vesting duration in seconds for auto-created vesting schedules
    uint256 private _vestingDuration;

    /// @notice Slice period in seconds for vesting release granularity
    uint256 private _vestingSlicePeriod;

    /// @notice Whether auto-created vesting schedules are revocable by the vesting owner
    bool private _vestingRevocable;

    /// @notice Ratio (in basis points) of governance tokens to xCUP shares. 10000 = 1:1.
    uint256 private _vestingRatioBps;

    /// @notice Allowlist of ERC20 tokens that may be used as `tokenIn` for zapAndDeposit
    /// @dev Does NOT gate USDC (always allowed, direct-transfer path) or native ETH
    ///      (address(0), no arbitrary contract code involved). Only applies to the
    ///      "swap arbitrary ERC20 -> USDC via router" path, which is the path that can
    ///      invoke attacker-controlled code (a malicious token's transferFrom/approve hooks).
    mapping(address => bool) private _allowedTokens;

    /// @notice Enumerable list of currently allowlisted tokens (for curator UIs / off-chain indexing)
    address[] private _allowedTokensList;

    // Reserve storage gap for future upgrades (to avoid storage collisions)
    // Reduced from 38 to 36 after adding the token allowlist (mapping + array = 2 slots)
    uint256[36] private __gap;

    /**
     * @notice Emitted when a user claims their approved deposit and receives vault shares
     * @param depositId The unique identifier of the deposit
     * @param user The address of the user claiming the deposit
     * @param shares The number of vault shares received
     */
    event DepositClaimed(bytes32 indexed depositId, address indexed user, uint256 shares);

    /**
     * @notice Emitted when an external deposit is claimed with beneficiary details
     * @dev Provides comprehensive tracking for external/host-to-host deposit flows
     * @param depositId The unique identifier of the deposit
     * @param user The original user who initiated the deposit
     * @param beneficiary The address that received the xCUP tokens
     * @param claimedBy The address that executed the claim transaction
     * @param tag The integration-specific identifier
     * @param shares The number of vault shares received
     */
    event DepositClaimedFor(
        bytes32 indexed depositId,
        address indexed user,
        address indexed beneficiary,
        address claimedBy,
        bytes32 tag,
        uint256 shares
    );

    /**
     * @notice Emitted when a vault curator approves a deposit
     * @param depositId The unique identifier of the deposit
     * @param approvedAmount The amount approved for the deposit in USDC
     */
    event DepositApproved(bytes32 indexed depositId, uint256 approvedAmount);

    /**
     * @notice Emitted when a vault curator declines a deposit and refunds the user
     * @param depositId The unique identifier of the deposit
     * @param user The address of the user whose deposit was declined
     * @param refundAmount The amount refunded to the user in USDC
     */
    event DepositDeclined(bytes32 indexed depositId, address indexed user, uint256 refundAmount);

    /**
     * @notice Emitted when a user withdraws their deposit before approval
     * @param depositId The unique identifier of the deposit (bytes32(0) for batch withdrawals)
     * @param user The address of the user withdrawing the deposit
     * @param amount The amount withdrawn in USDC
     */
    event DepositWithdrawn(bytes32 indexed depositId, address indexed user, uint256 amount);

    /**
     * @notice Emitted when deposits are approved proportionally
     * @param totalApproved Total amount approved across all deposits in USDC
     * @param totalDeposited Total amount deposited across all pending deposits in USDC
     * @param proportion The proportion used for approval (scaled by 1e18, where 1e18 = 100%)
     */
    event ProportionalApproval(uint256 totalApproved, uint256 totalDeposited, uint256 proportion);

    /**
     * @dev Emitted when USDC is withdrawn from the contract
     * @param user The address of the user withdrawing USDC
     * @param amount The amount of USDC withdrawn
     */
    event Withdraw(address indexed user, uint256 amount);

    /**
     * @dev Emitted when a user zaps tokens and deposits them
     * @param router The address of the Uniswap router used
     * @param tokenIn The address of the input token (address(0) == ETH)
     * @param amount The amount of tokens zapped and deposited (in USDC)
     */
    event ZapAndDeposit(address indexed router, address indexed tokenIn, uint256 amount);

    /**
     * @notice Emitted when a token's allowlist status for zapAndDeposit `tokenIn` changes
     * @param token The ERC20 token address affected
     * @param allowed Whether the token is now allowed (true) or disallowed (false)
     */
    event TokenAllowlistUpdated(address indexed token, bool allowed);

    /**
     * @notice Emitted when the Silo contract is migrated to a new instance
     * @param oldSilo The address of the previous Silo contract
     * @param newSilo The address of the newly deployed Silo contract
     * @param migratedAmount The amount of USDC transferred from old to new Silo
     */
    event SiloMigrated(address indexed oldSilo, address indexed newSilo, uint256 migratedAmount);

    /// @dev Emitted when an external deposit is registered (no token movement)
    event ExternalDepositRegistered(
        address indexed createdBy,
        address indexed beneficiary,
        bytes32 indexed depositId,
        bytes32 tag,
        uint256 usdcAmount
    );

    /**
     * @notice Emitted when a governance token vesting schedule is created for a deposit claim
     * @param depositId The unique identifier of the claimed deposit
     * @param beneficiary The address receiving the vesting schedule
     * @param governanceTokenAmount The amount of governance tokens vested
     */
    event VestingCreatedForDeposit(
        bytes32 indexed depositId,
        address indexed beneficiary,
        uint256 governanceTokenAmount
    );

    /**
     * @notice Emitted when the vesting configuration is updated
     * @param tokenVesting The address of the TokenVesting contract
     * @param governanceToken The address of the governance token
     * @param vestingCliff Cliff duration in seconds
     * @param vestingDuration Total vesting duration in seconds
     * @param vestingSlicePeriod Slice period in seconds
     * @param vestingRevocable Whether vestings are revocable
     * @param vestingRatioBps Ratio of governance tokens to xCUP shares (10000 = 1:1)
     */
    event VestingConfigUpdated(
        address indexed tokenVesting,
        address indexed governanceToken,
        uint256 vestingCliff,
        uint256 vestingDuration,
        uint256 vestingSlicePeriod,
        bool vestingRevocable,
        uint256 vestingRatioBps
    );

    /**
     *
     * @notice Modifier that ensures the epoch is active for time-sensitive operations
     * @dev Prevents operations that require active epoch timing from executing when epoch has ended.
     *      This is critical for maintaining the protocol's time-based deposit and approval cycles.
     *
     * Requirements:
     * - Current epoch must have time remaining (timeLeftInEpoch() > 0)
     *
     * @custom:security This modifier protects against operations outside of valid epoch windows
     * @custom:revert "Epoch not active" if the epoch has ended
     */
    modifier whenEpochActive() {
        require(_epochManager.timeLeftInEpoch() > 0, "Epoch not active");
        _;
    }

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /**
     * @notice Initializes the Zapper contract with all required dependencies and configurations
     * @dev This function sets up the complete Zapper ecosystem including token contracts,
     *      DEX integration, price oracles, and timing mechanisms. It also creates the Silo
     *      contract for USDC management and establishes proper access controls.
     *
     * @param cup_ The address of the CUP token contract (underlying vault asset)
     * @param usdc_ The address of the USDC token contract (primary stablecoin for deposits)
     * @param vault_ The address of the xCUP vault contract (ERC4626 compliant)
     * @param router_ The address of the Uniswap V2 router (for token swaps)
     * @param copperPriceConsumer_ The address of the copper price oracle consumer
     * @param epochManager_ The address of the epoch manager contract (timing control)
     */
    function initialize(
        address cup_,
        address usdc_,
        address vault_,
        address router_,
        address copperPriceConsumer_,
        address epochManager_
    ) public initializer {
        require(cup_ != address(0), "Invalid CUP address");
        require(usdc_ != address(0), "Invalid USDC address");
        require(vault_ != address(0), "Invalid Vault address");
        require(router_ != address(0), "Invalid Router address");
        require(copperPriceConsumer_ != address(0), "Invalid Copper Price Consumer address");
        require(epochManager_ != address(0), "Invalid Epoch Manager address");

        __AccessControl_init();
        __Ownable_init(_msgSender());
        __Pausable_init();
        __ReentrancyGuard_init();

        _grantRole(DEFAULT_ADMIN_ROLE, _msgSender());

        _cup = IERC20(cup_);
        _usdc = IERC20(usdc_);
        _vault = IERC4626(vault_);
        _router = IUniswapV2Router02(router_);
        _copperPriceConsumer = ICopperPriceConsumer(copperPriceConsumer_);

        _silo = new Silo(_usdc);
        _epochManager = IEpochManager(epochManager_);
    }

    /**
     * @notice One-time upgrade initializer that seeds the zap token allowlist
     * @dev Uses `reinitializer(2)` so it can only ever be called once, immediately
     *      after upgrading an already-initialized proxy to this implementation.
     *      Safe to pass an empty array (e.g. if the allowlist should start empty and
     *      be populated later via setTokenAllowed/setTokensAllowed).
     *
     * @param initialAllowedTokens Tokens to seed into the allowlist on upgrade
     */
    function initializeTokenAllowlistV2(address[] calldata initialAllowedTokens) external reinitializer(2) {
        for (uint256 i = 0; i < initialAllowedTokens.length; i++) {
            _setTokenAllowed(initialAllowedTokens[i], true);
        }
    }

    /**
     * @notice Records a new deposit in the system with comprehensive tracking
     * @dev Creates a new Deposit struct and adds it to all relevant tracking mappings.
     *      This function is the core deposit registration mechanism for regular user deposits.
     *
     * @param depositId The unique identifier for the deposit (must be unique)
     * @param amount The amount of the deposit in USDC (6 decimals)
     */
    function _recordDeposit(bytes32 depositId, uint256 amount) internal {
        DepositLib.recordDeposit(_approvedDeposits, _pendingDepositIds, _userDeposits, depositId, amount, _msgSender());
    }

    /**
     * @notice Records a new external deposit for host-to-host integrations
     * @dev Creates a deposit record without any token transfers. This is used for external
     *      integrations where tokens are managed off-chain or by external systems.
     *      The deposit includes beneficiary and tag information for integration tracking.
     *
     * @param usdcAmount The notional USDC amount for the deposit
     * @param beneficiary_ The address that will receive xCUP tokens upon claim
     * @param tag_ Integration-specific identifier for tracking
     * @return depositId The generated unique identifier for this deposit
     */
    function _recordExternalDeposit(
        uint256 usdcAmount,
        address beneficiary_,
        bytes32 tag_
    ) internal returns (bytes32 depositId) {
        uint256 nonce = _userNonces[_msgSender()];

        depositId = DepositLib.recordExternalDeposit(
            _approvedDeposits,
            _pendingDepositIds,
            _userDeposits,
            usdcAmount,
            beneficiary_,
            tag_,
            _msgSender(),
            nonce
        );

        // Increment nonce after successful deposit creation
        // If collision occurred in library, nonce was already incremented there
        // We increment here to ensure next call uses a fresh nonce
        _userNonces[_msgSender()] = nonce + 1;
    }

    /**
     * @notice Swaps input tokens for USDC using Uniswap V2 with slippage protection
     * @dev This function handles the complete token-to-USDC conversion process including
     *      token transfers, approvals, and DEX interactions. It supports both ERC20 tokens
     *      and native ETH (represented as address(0)).
     *
     * @param tokenIn The token to swap from (address(0) for ETH)
     * @param amount The amount of tokens to swap (in token's native decimals)
     * @param slippageBps The slippage tolerance in basis points (100 = 1%, 1000 = 10%)
     * @return depositValue The net amount of USDC received from the swap (6 decimals)
     */
    function _zapIn(IERC20 tokenIn, uint256 amount, uint256 slippageBps) internal returns (uint256 depositValue) {
        depositValue = SwapLib.zapIn(
            tokenIn,
            amount,
            slippageBps,
            _router,
            _usdc,
            address(_silo),
            address(this),
            _msgSender(),
            msg.value
        );
    }

    /**
     * @notice Executes an ERC20 permit for gasless token approvals
     * @dev This function enables users to approve token spending without a separate transaction
     *      by using EIP-2612 permit functionality. It validates the permit signature and
     *      ensures the approval was successful.
     *
     * @param token The ERC20Permit token contract
     * @param owner The token owner granting the approval
     * @param spender The address receiving the approval (typically this contract)
     * @param permitParams The permit signature components and parameters
     */
    function _execPermit(
        IERC20 token,
        address owner,
        address spender,
        PermitLib.PermitParams calldata permitParams
    ) internal {
        PermitLib.execPermit(token, owner, spender, permitParams);
    }

    /**
     * @dev Processes a deposit by either transferring USDC directly or zapping other tokens
     * @param tokenIn The token being deposited (address(0) == ETH)
     * @param amount The amount of tokens to deposit
     * @param slippageBps The slippage tolerance in basis points (e.g., 100 = 1%)
     * @return depositValue The final USDC value of the deposit
     */
    function _processDeposit(
        IERC20 tokenIn,
        uint256 amount,
        uint256 slippageBps
    ) internal returns (uint256 depositValue) {
        if (address(tokenIn) == address(_usdc)) {
            tokenIn.safeTransferFrom(_msgSender(), address(_silo), amount);
            depositValue = amount;
        } else {
            // Native ETH (address(0)) never runs arbitrary token contract code, so it
            // is not subject to the allowlist. Any other ERC20 must be curator-approved
            // before it can be swapped via the router (see TokenAllowlistUpdated).
            if (address(tokenIn) != address(0)) {
                require(_allowedTokens[address(tokenIn)], "Token not allowlisted");
            }
            depositValue = _zapIn(tokenIn, amount, slippageBps);
        }
    }

    /**
     * @notice Internal helper to add/remove a token from the zap allowlist
     * @dev No-op if the token is already in the requested state (keeps the list clean
     *      and avoids duplicate entries / redundant events)
     */
    function _setTokenAllowed(address token, bool allowed) internal {
        require(token != address(0), "Invalid token");
        require(token != address(_usdc), "USDC is always allowed");

        if (_allowedTokens[token] == allowed) return;
        _allowedTokens[token] = allowed;

        if (allowed) {
            _allowedTokensList.push(token);
        } else {
            uint256 len = _allowedTokensList.length;
            for (uint256 i = 0; i < len; i++) {
                if (_allowedTokensList[i] == token) {
                    _allowedTokensList[i] = _allowedTokensList[len - 1];
                    _allowedTokensList.pop();
                    break;
                }
            }
        }

        emit TokenAllowlistUpdated(token, allowed);
    }

    /**
     * @notice Allows a vault curator to allow/disallow a single token for zapAndDeposit
     * @dev USDC does not need to be (and cannot be) added — it always uses the direct
     *      transfer path and is never subject to the allowlist.
     * @param token The ERC20 token address to update
     * @param allowed Whether the token should be allowed as `tokenIn`
     */
    function setTokenAllowed(address token, bool allowed) external onlyRole(VAULT_CURATOR_ROLE) {
        _setTokenAllowed(token, allowed);
    }

    /**
     * @notice Allows a vault curator to allow/disallow multiple tokens in one call
     * @param tokens The ERC20 token addresses to update
     * @param allowed Whether the tokens should be allowed as `tokenIn`
     */
    function setTokensAllowed(address[] calldata tokens, bool allowed) external onlyRole(VAULT_CURATOR_ROLE) {
        for (uint256 i = 0; i < tokens.length; i++) {
            _setTokenAllowed(tokens[i], allowed);
        }
    }

    /**
     * @notice Returns whether a token is currently allowed as `tokenIn` for zapAndDeposit
     * @dev USDC is always implicitly allowed (direct-transfer path) even though it is
     *      never added to `_allowedTokens`.
     */
    function isTokenAllowed(address token) public view returns (bool) {
        if (token == address(_usdc)) return true;
        return _allowedTokens[token];
    }

    /**
     * @notice Returns the full list of currently allowlisted (non-USDC) tokens
     */
    function getAllowedTokens() external view returns (address[] memory) {
        return _allowedTokensList;
    }

    /**
     * @notice Allows users to zap tokens into USDC and create a deposit using gasless permit
     * @dev This function combines ERC20 permit functionality with the zapping process,
     *      enabling users to approve and deposit in a single transaction. It handles
     *      both ERC20 tokens (with permit) and native ETH deposits.
     *
     * @param tokenIn The token to zap (ERC20 address or address(0) for ETH)
     * @param amount The amount of tokens to zap (in token's native decimals)
     * @param permitParams The ERC20 permit signature components
     * @param depositId The unique identifier for the created deposit
     * @param slippageBps The slippage tolerance in basis points (0 = use default 100)
     */
    function zapAndDepositWithPermit(
        IERC20 tokenIn,
        uint256 amount,
        PermitLib.PermitParams calldata permitParams,
        bytes32 depositId,
        uint256 slippageBps
    ) external payable whenNotPaused nonReentrant {
        // allow address(0) for ETH
        require(amount != 0, "Invalid amount");

        // Use default slippage of 1% (100 basis points) if 0 is passed
        uint256 actualSlippage = slippageBps == 0 ? 100 : slippageBps;

        if (address(tokenIn) != address(0)) {
            // ERC20 token: msg.value must be 0 to prevent ETH loss
            require(msg.value == 0, "Cannot send ETH with ERC20 token");
            if (tokenIn.allowance(_msgSender(), address(this)) < amount) {
                _execPermit(tokenIn, _msgSender(), address(this), permitParams);
            }
        } else {
            // ETH: require msg.value
            require(msg.value == amount, "Invalid ETH amount");
        }

        uint256 depositValue = _processDeposit(tokenIn, amount, actualSlippage);
        _recordDeposit(depositId, depositValue);

        emit ZapAndDeposit(router(), address(tokenIn), depositValue);
    }

    /**
     * @notice Allows users to zap tokens into USDC and create a deposit
     * @dev This is the primary entry point for user deposits. It handles token swapping,
     *      USDC conversion, and deposit registration in a single transaction. Supports
     *      any ERC20 token or native ETH with configurable slippage protection.
     *
     * @param tokenIn The token to zap (ERC20 address or address(0) for ETH)
     * @param amount The amount of tokens to zap (in token's native decimals)
     * @param depositId The unique identifier for the created deposit
     * @param slippageBps The slippage tolerance in basis points (0 = use default 100)
     */
    function zapAndDeposit(
        IERC20 tokenIn,
        uint256 amount,
        bytes32 depositId,
        uint256 slippageBps
    ) external payable whenNotPaused nonReentrant {
        // allow address(0) for ETH
        require(amount != 0, "Invalid amount");

        // Use default slippage of 1% (100 basis points) if 0 is passed
        uint256 actualSlippage = slippageBps == 0 ? 100 : slippageBps;

        if (address(tokenIn) == address(0)) {
            require(msg.value == amount, "Invalid ETH amount");
        } else {
            // ERC20 token: msg.value must be 0 to prevent ETH loss
            require(msg.value == 0, "Cannot send ETH with ERC20 token");
        }

        uint256 depositValue = _processDeposit(tokenIn, amount, actualSlippage);
        _recordDeposit(depositId, depositValue);

        emit ZapAndDeposit(router(), address(tokenIn), depositValue);
    }

    /**
     * @notice Registers an external deposit for host-to-host integrations
     * @dev This function enables external systems (like backend adapters) to register
     *      deposits on behalf of users without any token transfers. The deposit is
     *      purely informational until approved and claimed.
     *
     * @param beneficiary_ The address that will receive xCUP tokens upon claim
     * @param usdcAmount The notional USDC amount for the deposit
     * @param tag_ Integration-specific identifier for tracking and reconciliation
     * @return depositId The generated unique identifier for this deposit
     */
    function registerExternalDepositFor(
        address beneficiary_,
        uint256 usdcAmount,
        bytes32 tag_
    ) external whenNotPaused onlyRole(HOST_INTEGRATION_ROLE) returns (bytes32 depositId) {
        require(usdcAmount > 0, "Invalid amount");
        depositId = _recordExternalDeposit(usdcAmount, beneficiary_, tag_);
        emit ExternalDepositRegistered(_msgSender(), beneficiary_, depositId, tag_, usdcAmount);
    }

    /**
     * @notice Allows host integrations to update the beneficiary of a pending deposit
     * @dev This function provides flexibility for external integrations to modify
     *      the beneficiary address before the deposit is approved by curators.
     *      This is useful for correcting errors or handling dynamic beneficiary assignment.
     *
     * @param depositId The unique identifier of the deposit to update
     * @param beneficiary_ The new beneficiary address for the deposit
     */
    function setDepositBeneficiary(
        bytes32 depositId,
        address beneficiary_
    ) external whenNotPaused onlyRole(HOST_INTEGRATION_ROLE) {
        DepositLib.setDepositBeneficiary(_approvedDeposits, depositId, beneficiary_);
    }

    /**
     * @notice Allows users to withdraw their deposit before curator approval
     * @dev This function enables users to cancel their pending deposits and receive
     *      a full refund of their USDC. This provides an exit mechanism before the
     *      approval process is complete.
     *
     * @param depositId The unique identifier of the deposit to withdraw
     */
    function withdrawDeposit(bytes32 depositId) external whenNotPaused nonReentrant {
        DepositLib.Deposit storage deposit = _approvedDeposits[depositId];

        require(deposit.user == _msgSender(), "Invalid user");
        require(deposit.user != address(0), "Deposit not found");
        require(!deposit.approved, "Deposit already approved");

        uint256 refundAmount = deposit.amount;
        delete _approvedDeposits[depositId];
        DepositLib.removePendingDeposit(_pendingDepositIds, depositId);
        DepositLib.removeUserDeposit(_userDeposits, _msgSender(), depositId);

        // Return USDC to user
        require(_usdc.balanceOf(address(silo())) >= refundAmount, "Insufficient USDC balance");
        _usdc.safeTransferFrom(address(silo()), _msgSender(), refundAmount);

        emit DepositWithdrawn(depositId, _msgSender(), refundAmount);
    }

    /**
     * @notice Allows users to withdraw all their pending deposits in a single transaction
     * @dev This function provides a convenient way for users to cancel all their pending
     *      deposits at once, receiving a full refund for all unapproved deposits.
     *      It uses a two-pass algorithm to safely handle array modifications.
     *
     * @return totalRefunded The total amount of USDC refunded to the user
     */
    function withdrawAllDeposits() external whenNotPaused nonReentrant returns (uint256 totalRefunded) {
        bytes32[] storage userDepositIds = _userDeposits[_msgSender()];
        require(userDepositIds.length > 0, "No deposits found");

        // Create a copy of deposit IDs to iterate over, since we'll be modifying the original array
        bytes32[] memory depositIds = new bytes32[](userDepositIds.length);
        uint256 validDepositsCount = 0;

        // First pass: collect valid pending deposits
        for (uint256 i = 0; i < userDepositIds.length; i++) {
            bytes32 depositId = userDepositIds[i];
            DepositLib.Deposit storage deposit = _approvedDeposits[depositId];

            if (deposit.user == _msgSender() && !deposit.approved && deposit.user != address(0)) {
                depositIds[validDepositsCount] = depositId;
                totalRefunded += deposit.amount;
                validDepositsCount++;
            }
        }

        require(validDepositsCount > 0, "No pending deposits to withdraw");
        require(_usdc.balanceOf(address(silo())) >= totalRefunded, "Insufficient USDC balance");

        // Second pass: actually withdraw the deposits
        for (uint256 i = 0; i < validDepositsCount; i++) {
            bytes32 depositId = depositIds[i];
            DepositLib.Deposit storage deposit = _approvedDeposits[depositId];

            // Clean up the deposit
            delete _approvedDeposits[depositId];
            DepositLib.removePendingDeposit(_pendingDepositIds, depositId);
            DepositLib.removeUserDeposit(_userDeposits, _msgSender(), depositId);
        }

        // Transfer total refund to user
        _usdc.safeTransferFrom(address(silo()), _msgSender(), totalRefunded);

        emit DepositWithdrawn(bytes32(0), _msgSender(), totalRefunded); // Use bytes32(0) to indicate batch withdrawal
    }

    /**
     * @notice Allows vault curators to approve a specific deposit for vault entry
     * @dev This function enables curators to review and approve individual deposits,
     *      potentially for partial amounts. Approved deposits can then be claimed by
     *      users to receive xCUP vault shares.
     *
     * @param depositId The unique identifier of the deposit to approve
     * @param approvedAmount The amount to approve in USDC (must be <= total deposit)
     */
    function approveDeposit(
        bytes32 depositId,
        uint256 approvedAmount
    ) external whenNotPaused whenEpochActive onlyRole(VAULT_CURATOR_ROLE) {
        uint256 price = getCopperPrice();
        require(price > 0, "Copper price is 0");
        uint256 approvedCupAmount = (approvedAmount * 1e8) / price;
        DepositLib.approveDeposit(_approvedDeposits, depositId, approvedAmount, price, approvedCupAmount);
        DepositLib.mintCupTokens(IERC20Mintable(address(_cup)), address(this), approvedCupAmount);
    }

    /**
     * @notice Approves an external deposit with a fixed copper price snapshot
     * @dev This function is specifically designed for external deposits where the
     *      copper price needs to be locked at approval time rather than claim time.
     *      This provides price certainty for external integrations.
     *
     * @param depositId The unique identifier of the external deposit
     * @param approvedUsdc The USDC amount to approve
     * @param price The copper price to use for CUP calculation (with 8 decimals)
     */
    function approveExternalDepositWithPrice(
        bytes32 depositId,
        uint256 approvedUsdc,
        uint256 price
    ) external whenNotPaused whenEpochActive onlyRole(VAULT_CURATOR_ROLE) {
        DepositLib.approveExternalDepositWithPrice(_approvedDeposits, depositId, approvedUsdc, price);
        uint256 cupAmount = _approvedDeposits[depositId].approvedCupAmount;
        DepositLib.mintCupTokens(IERC20Mintable(address(_cup)), address(this), cupAmount);
    }

    /**
     * @notice Allows vault curators to decline a deposit and issue a full refund
     * @dev This function enables curators to reject deposits that don't meet criteria
     *      and automatically refund the full amount to the user. This provides a
     *      mechanism for regulatory compliance and risk management.
     *
     * @param depositId The unique identifier of the deposit to decline
     */
    function declineDeposit(
        bytes32 depositId
    ) external whenNotPaused whenEpochActive onlyRole(VAULT_CURATOR_ROLE) nonReentrant {
        (address user, uint256 refundAmount) = DepositLib.declineDeposit(
            _approvedDeposits,
            _pendingDepositIds,
            _userDeposits,
            depositId
        );

        // Return USDC to user
        require(_usdc.balanceOf(address(_silo)) >= refundAmount, "Insufficient USDC balance");
        _usdc.safeTransferFrom(address(_silo), user, refundAmount);
    }

    /**
     * @notice Allows vault curators to approve multiple deposits proportionally
     * @dev This function enables curators to approve a specific total amount across
     *      all pending deposits, with each deposit receiving a proportional share.
     *      This is useful for managing vault capacity and fair distribution.
     *
     * @param targetTotalAmount The total USDC amount to approve across all deposits
     */
    function approveDepositsProportionally(
        uint256 targetTotalAmount
    ) external whenNotPaused whenEpochActive onlyRole(VAULT_CURATOR_ROLE) {
        uint256 price = getCopperPrice();
        require(price > 0, "Copper price is 0");
        uint256 totalCup = DepositLib.approveDepositsProportionally(
            _approvedDeposits,
            _pendingDepositIds,
            targetTotalAmount,
            price
        );
        DepositLib.mintCupTokens(IERC20Mintable(address(_cup)), address(this), totalCup);
    }

    /**
     * @notice Allows vault curators to approve all pending deposits in full
     * @dev This function provides a convenient way to approve all pending deposits
     *      for their complete amounts. This is useful when vault has sufficient
     *      capacity and all deposits meet approval criteria.
     *
     * @return totalApproved The total USDC amount approved across all deposits
     * @return depositsApproved The number of individual deposits that were approved
     */
    function approveAllDeposits()
        external
        whenNotPaused
        whenEpochActive
        onlyRole(VAULT_CURATOR_ROLE)
        returns (uint256 totalApproved, uint256 depositsApproved)
    {
        uint256 price = getCopperPrice();
        require(price > 0, "Copper price is 0");
        uint256 totalCup;
        (totalApproved, depositsApproved, totalCup) = DepositLib.approveAllDeposits(
            _approvedDeposits,
            _pendingDepositIds,
            price
        );
        DepositLib.mintCupTokens(IERC20Mintable(address(_cup)), address(this), totalCup);
    }

    /**
     * @dev Allows users to claim their approved deposits and receive vault shares
     * @param depositId The unique identifier of the deposit to claim
     * @return shares The number of vault shares received
     */
    function claimDeposit(bytes32 depositId) public whenNotPaused whenEpochActive returns (uint256 shares) {
        DepositLib.Deposit storage deposit = _approvedDeposits[depositId];

        // For external deposits, allow both user and beneficiary to claim
        // For regular deposits, only the user can claim
        address beneficiary_ = deposit.beneficiary == address(0) ? deposit.user : deposit.beneficiary;
        if (deposit.isExternal) {
            require(_msgSender() == deposit.user || _msgSender() == beneficiary_, "Not authorized to claim");
        } else {
            require(deposit.user == _msgSender(), "Invalid user");
        }

        require(deposit.approved, "Deposit not approved");
        require(deposit.approvedAmount > 0, "No approved amount");

        // Store critical values before potential deletion
        uint256 approvedAmount = deposit.approvedAmount;
        address user = deposit.user;
        bool isExternal = deposit.isExternal;

        // Mark who claimed the deposit before potential deletion
        deposit.claimedBy = _msgSender();

        // CUP is minted at approval time; use the fixed amount.
        // Legacy: deposits approved before the mint-at-approve upgrade have no snapshot — compute from oracle.
        uint256 cupValue;
        if (deposit.approvedCupAmount > 0 && deposit.priceSnapshot > 0) {
            cupValue = deposit.approvedCupAmount;
        } else {
            uint256 currentCopperPrice = getCopperPrice();
            require(currentCopperPrice > 0, "Copper price is 0");
            cupValue = (approvedAmount * 1e8) / currentCopperPrice;
        }

        // Deposit CUP to vault and get xCUP shares
        _cup.approve(address(_vault), cupValue);
        address sharesRecipient = isExternal ? beneficiary_ : _msgSender();
        shares = _vault.deposit(cupValue, sharesRecipient);

        // Auto-create governance token vesting schedule
        if (address(_tokenVesting) != address(0) && address(_governanceToken) != address(0) && _vestingDuration > 0) {
            DepositLib.createGovernanceVesting(
                DepositLib.VestingParams({
                    governanceToken: _governanceToken,
                    tokenVesting: _tokenVesting,
                    depositId: depositId,
                    beneficiary: sharesRecipient,
                    shares: shares,
                    ratioBps: _vestingRatioBps,
                    vestingCliff: _vestingCliff,
                    vestingDuration: _vestingDuration,
                    vestingSlicePeriod: _vestingSlicePeriod,
                    vestingRevocable: _vestingRevocable
                })
            );
        }

        // Emit appropriate events
        emit DepositClaimed(depositId, sharesRecipient, shares);

        // For external deposits, emit additional detailed event
        if (isExternal) {
            emit DepositClaimedFor(depositId, user, beneficiary_, _msgSender(), deposit.tag, shares);
        }

        // If the deposit is fully approved, remove it from the pending deposits and user's list
        if (deposit.amount - approvedAmount == 0) {
            delete _approvedDeposits[depositId];
            DepositLib.removePendingDeposit(_pendingDepositIds, depositId);
            DepositLib.removeUserDeposit(_userDeposits, user, depositId);
        } else {
            deposit.amount = deposit.amount - approvedAmount;
            deposit.approvedAmount = 0;
            deposit.approved = false;
            deposit.approvedCupAmount = 0;
            deposit.priceSnapshot = 0;
        }
    }

    /**
     * @dev Claim all approved deposits for msg.sender and receive vault shares.
     * Iterates over user's deposit IDs and claims those which are approved.
     * @return totalShares total number of shares received for all claimed deposits
     */
    function claimAllDeposits() external whenNotPaused whenEpochActive returns (uint256 totalShares) {
        bytes32[] storage ids = _userDeposits[_msgSender()];

        // iterate over a copy of ids length because claimDeposit may remove some entries
        uint256 len = ids.length;
        for (uint256 i = 0; i < len; i++) {
            // If array shortened because of removals, protect against OOB
            if (i >= _userDeposits[_msgSender()].length) {
                break;
            }

            bytes32 id = _userDeposits[_msgSender()][i];
            DepositLib.Deposit storage deposit = _approvedDeposits[id];

            if (
                (deposit.user == _msgSender() || (deposit.isExternal && deposit.beneficiary == _msgSender())) &&
                deposit.approved &&
                deposit.approvedAmount > 0
            ) {
                // call claimDeposit which handles removal / partial approvals
                uint256 shares = claimDeposit(id);
                totalShares += shares;
                // after claimDeposit, the id may be removed from _userDeposits and _pendingDepositIds
                // we continue loop — because we indexed by i and re-fetched length at top, it's safe
                // to continue; this loop may skip some newly shifted elements but those will be
                // processed in next iterations since we re-check bounds.
            }
        }
    }

    /**
     * @notice Configures the automatic governance token vesting for deposit claims
     * @dev Sets all parameters for auto-vesting. Pass tokenVesting_ = address(0) to disable.
     *      The Zapper must have MINTER_ROLE on the governance token and vestingCreator role
     *      on the TokenVesting contract for auto-vesting to work.
     *
     * @param tokenVesting_ The address of the TokenVesting contract (address(0) to disable)
     * @param governanceToken_ The address of the governance token to be vested
     * @param vestingCliff_ Cliff duration in seconds before tokens start vesting
     * @param vestingDuration_ Total vesting duration in seconds (must be >= cliff)
     * @param vestingSlicePeriod_ Release granularity in seconds (e.g. 1 day = 86400)
     * @param vestingRevocable_ Whether the owner can revoke auto-created vestings
     * @param vestingRatioBps_ Ratio of governance tokens to xCUP shares in basis points (10000 = 1:1)
     */
    function setVestingConfig(
        address tokenVesting_,
        address governanceToken_,
        uint256 vestingCliff_,
        uint256 vestingDuration_,
        uint256 vestingSlicePeriod_,
        bool vestingRevocable_,
        uint256 vestingRatioBps_
    ) external onlyRole(VAULT_CURATOR_ROLE) {
        if (tokenVesting_ != address(0)) {
            require(governanceToken_ != address(0), "Governance token required when vesting enabled");
            require(vestingDuration_ > 0, "Vesting duration must be > 0");
            require(vestingSlicePeriod_ >= 1, "Slice period must be >= 1");
            require(vestingDuration_ >= vestingCliff_, "Duration must be >= cliff");
            require(vestingRatioBps_ > 0, "Ratio must be > 0");
        }

        _tokenVesting = ITokenVesting(tokenVesting_);
        _governanceToken = IERC20Mintable(governanceToken_);
        _vestingCliff = vestingCliff_;
        _vestingDuration = vestingDuration_;
        _vestingSlicePeriod = vestingSlicePeriod_;
        _vestingRevocable = vestingRevocable_;
        _vestingRatioBps = vestingRatioBps_;

        emit VestingConfigUpdated(
            tokenVesting_,
            governanceToken_,
            vestingCliff_,
            vestingDuration_,
            vestingSlicePeriod_,
            vestingRevocable_,
            vestingRatioBps_
        );
    }

    /**
     * @notice Returns the current governance vesting configuration
     * @return tokenVesting The address of the TokenVesting contract
     * @return governanceToken The address of the governance token
     * @return vestingCliff Cliff duration in seconds
     * @return vestingDuration Total vesting duration in seconds
     * @return vestingSlicePeriod Slice period in seconds
     * @return vestingRevocable Whether vestings are revocable
     * @return vestingRatioBps Ratio of governance tokens to xCUP shares (10000 = 1:1)
     */
    function getVestingConfig()
        external
        view
        returns (
            address tokenVesting,
            address governanceToken,
            uint256 vestingCliff,
            uint256 vestingDuration,
            uint256 vestingSlicePeriod,
            bool vestingRevocable,
            uint256 vestingRatioBps
        )
    {
        tokenVesting = address(_tokenVesting);
        governanceToken = address(_governanceToken);
        vestingCliff = _vestingCliff;
        vestingDuration = _vestingDuration;
        vestingSlicePeriod = _vestingSlicePeriod;
        vestingRevocable = _vestingRevocable;
        vestingRatioBps = _vestingRatioBps;
    }

    /**
     * @notice Allows vault curators to withdraw USDC from the Silo to a specified address
     * @dev This function provides curators with the ability to withdraw USDC from the Silo
     *      for operational purposes such as rebalancing, emergency management, or protocol
     *      maintenance. This is an administrative function with significant privileges.
     *
     * @param amount The amount of USDC to withdraw from the Silo (6 decimals)
     * @param to The address to receive the withdrawn USDC
     */
    function withdraw(uint256 amount, address to) external nonReentrant onlyRole(VAULT_CURATOR_ROLE) {
        require(to != address(0), "Invalid recipient address");
        require(_usdc.balanceOf(address(silo())) >= amount, "Insufficient USDC balance");

        _usdc.safeTransferFrom(silo(), to, amount);

        emit Withdraw(to, amount);
    }

    /**
     * @notice Returns the current copper price from the oracle
     * @dev This function provides access to the current copper spot price used for
     *      CUP token conversions. The price is fetched from the configured copper
     *      price consumer contract which may use Chainlink or other oracle sources.
     *
     * @return price The current copper price with 8 decimal places
     */
    function getCopperPrice() public view returns (uint256 price) {
        price = _copperPriceConsumer.price();
    }

    /**
     * @notice Returns complete deposit information for a given deposit ID
     * @dev This function provides access to all stored information about a specific
     *      deposit, including user details, amounts, approval status, and metadata.
     *      Useful for frontend interfaces and integration systems.
     *
     * @param depositId The unique identifier of the deposit to query
     * @return The complete Deposit struct with all information
     */
    function getDeposit(bytes32 depositId) external view returns (DepositLib.Deposit memory) {
        return DepositViewLib.getDeposit(_approvedDeposits, depositId);
    }

    /**
     * @notice Returns all pending deposit IDs awaiting curator approval
     * @dev This function provides a list of all deposit IDs that are currently
     *      pending curator review and approval. Useful for curator interfaces
     *      and batch processing operations.
     *
     * @return Array of bytes32 deposit IDs currently pending approval
     */
    function getPendingDepositIds() external view returns (bytes32[] memory) {
        return DepositViewLib.getPendingDepositIds(_pendingDepositIds);
    }

    /**
     * @notice Returns all pending deposits with complete information
     * @dev This function provides detailed information about all pending deposits,
     *      including full Deposit structs. It filters out invalid entries and
     *      returns only valid, unapproved deposits.
     *
     * @return deposits Array of complete Deposit structs for all pending deposits
     */
    function getPendingDeposits() external view returns (DepositLib.Deposit[] memory) {
        return DepositViewLib.getPendingDeposits(_approvedDeposits, _pendingDepositIds);
    }

    /**
     * @dev Returns all deposit IDs for a given user
     */
    function getUserDepositIds(address user) external view returns (bytes32[] memory) {
        return DepositViewLib.getUserDepositIds(_userDeposits, user);
    }

    /**
     * @dev Returns all deposits for a given user
     */
    function getUserDeposits(address user) external view returns (DepositLib.Deposit[] memory) {
        return DepositViewLib.getUserDeposits(_approvedDeposits, _userDeposits, user);
    }

    /**
     * @dev Returns the total amount of all pending deposits
     * @return totalAmount The total amount of pending deposits in USDC
     */
    function getTotalPendingAmount() external view returns (uint256) {
        return DepositViewLib.getTotalPendingAmount(_approvedDeposits, _pendingDepositIds);
    }

    /**
     * @notice Migrates USDC from the current Silo to a newly deployed Silo
     * @dev Deploys a new Silo contract (which auto-approves this contract for unlimited USDC),
     *      transfers all USDC from the old Silo to the new one, and updates the internal reference.
     *      Must be called while the contract is paused to prevent deposit/withdraw race conditions.
     *      Only callable by the contract owner.
     *
     *      Migration flow:
     *      1. Snapshot old Silo address and USDC balance
     *      2. Deploy new Silo (constructor grants unlimited USDC approval to this contract)
     *      3. Pull all USDC from old Silo to this contract (using existing approval)
     *      4. Push all USDC from this contract to new Silo
     *      5. Update _silo reference and emit event
     */
    function migrateSilo() external onlyOwner nonReentrant whenPaused {
        Silo oldSilo = _silo;
        uint256 balance = _usdc.balanceOf(address(oldSilo));

        _silo = new Silo(_usdc);

        if (balance > 0) {
            _usdc.safeTransferFrom(address(oldSilo), address(this), balance);
            _usdc.safeTransfer(address(_silo), balance);
        }

        emit SiloMigrated(address(oldSilo), address(_silo), balance);
    }

    /**
     * @dev Pauses the contract, preventing new deposits and withdrawals
     */
    function pause() external onlyOwner {
        _pause();
    }

    /**
     * @dev Unpauses the contract, allowing new deposits and withdrawals
     */
    function unpause() external onlyOwner {
        _unpause();
    }

    /**
     * @dev Returns the address of the Uniswap V2 router
     * @return The router address
     */
    function router() public view returns (address) {
        return address(_router);
    }

    /**
     * @dev Returns the address of the USDC token contract
     * @return The USDC token address
     */
    function usdc() public view returns (address) {
        return address(_usdc);
    }

    /**
     * @dev Returns the address of the silo contract
     * @return The silo contract address
     */
    function silo() public view returns (address) {
        return address(_silo);
    }

    /**
     * @notice Automatically processes ETH sent directly to the contract as a deposit
     * @dev This receive function enables users to simply send ETH to the contract
     *      address and have it automatically processed as a deposit. It provides
     *      a convenient way to deposit ETH without calling specific functions.
     */
    receive() external payable whenNotPaused nonReentrant {
        require(msg.value > 0, "No ETH sent");
        uint256 depositValue = _processDeposit(IERC20(address(0)), msg.value, 100); // Default 1% slippage

        // Generate unique deposit ID with nonce to prevent collisions
        // With nonce, collision is extremely rare, so we check once and increment if needed
        uint256 nonce = _userNonces[msg.sender];
        bytes32 depositId = keccak256(abi.encodePacked(msg.sender, nonce, msg.value, block.timestamp));

        // If collision detected (extremely rare), increment nonce and regenerate once
        if (_approvedDeposits[depositId].user != address(0)) {
            nonce++;
            depositId = keccak256(abi.encodePacked(msg.sender, nonce, msg.value, block.timestamp));
            // Final check - if still collision, revert (should never happen)
            if (_approvedDeposits[depositId].user != address(0)) {
                revert("Deposit ID collision");
            }
        }

        // Update nonce after successful generation
        _userNonces[msg.sender] = nonce + 1;

        _recordDeposit(depositId, depositValue);
        emit ZapAndDeposit(router(), address(0), depositValue);
    }

    /**
     * @notice Fallback function to handle ETH sent with data or unknown function calls
     * @dev This fallback function provides a safety net for ETH sent to the contract
     *      with data or when calling non-existent functions. It processes any ETH
     *      value as a deposit, similar to the receive function.
     */
    fallback() external payable whenNotPaused nonReentrant {
        if (msg.value > 0) {
            uint256 depositValue = _processDeposit(IERC20(address(0)), msg.value, 100); // Default 1% slippage

            // Generate unique deposit ID with nonce to prevent collisions
            // With nonce, collision is extremely rare, so we check once and increment if needed
            uint256 nonce = _userNonces[msg.sender];
            bytes32 depositId = keccak256(abi.encodePacked(msg.sender, nonce, msg.value, block.timestamp));

            // If collision detected (extremely rare), increment nonce and regenerate once
            if (_approvedDeposits[depositId].user != address(0)) {
                nonce++;
                depositId = keccak256(abi.encodePacked(msg.sender, nonce, msg.value, block.timestamp));
                // Final check - if still collision, revert (should never happen)
                if (_approvedDeposits[depositId].user != address(0)) {
                    revert("Deposit ID collision");
                }
            }

            // Update nonce after successful generation
            _userNonces[msg.sender] = nonce + 1;

            _recordDeposit(depositId, depositValue);
            emit ZapAndDeposit(router(), address(0), depositValue);
        }
    }
}
