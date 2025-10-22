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
import {Silo} from "./Silo.sol";

import {RedeemLib} from "./libraries/RedeemLib.sol";

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
    mapping(bytes32 depositId => Deposit) private _approvedDeposits;

    /// @notice Array of pending deposit IDs awaiting curator approval
    /// @dev Used to iterate over pending deposits for batch operations
    bytes32[] private _pendingDepositIds;

    /// @notice Mapping of user addresses to their deposit IDs
    /// @dev Allows users to query all their deposits
    mapping(address => bytes32[]) private _userDeposits;

    /// @notice Mapping of user addresses to their nonce for deposit ID generation
    /// @dev Ensures unique deposit IDs for each user
    mapping(address => uint256) private _userNonces;

    mapping(bytes32 => RedeemLib.RedeemRequest) private _redeems;

    /// @notice Commission percentage for direct redeem operations (in basis points, e.g., 200 = 2%)
    /// @dev Commission charged on direct redeem operations, with the remainder staying in silo
    uint256 private _redeemCommissionBps;

    // Reserve storage gap for future upgrades (to avoid storage collisions)
    uint256[43] private __gap;

    /**
     * @notice Struct representing a user deposit with comprehensive tracking
     * @dev Contains all necessary information for deposit lifecycle management
     * @param user The address of the user who made the deposit (originator/payer)
     * @param depositId Unique identifier for the deposit
     * @param amount Total amount deposited in USDC (6 decimals)
     * @param approvedAmount Amount approved by vault curators in USDC
     * @param approved Whether the deposit has been approved by curators
     * @param beneficiary Who will receive xCUP tokens on claim (for external deposits)
     * @param createdBy Who initiated the deposit (EOA or adapter contract)
     * @param claimedBy Who executed the claim transaction
     * @param isExternal True if created via external adapter flow
     * @param tag Integration-specific identifier for tracking
     * @param approvedCupAmount Fixed CUP amount approved (for external deposits with price snapshot)
     * @param priceSnapshot Copper price used for approval (for external deposits)
     */
    struct Deposit {
        address user; // originator (payer) for on-chain deposits
        bytes32 depositId; // unique identifier
        uint256 amount; // pending USDC value
        uint256 approvedAmount; // approved USDC value
        bool approved; // approved flag
        // Extended fields for host-to-host external deposits
        address beneficiary; // who will receive xCUP on claim
        address createdBy; // who initiated the deposit (EOA/adapter)
        address claimedBy; // who executed the claim
        bool isExternal; // true if created via external adapter flow
        bytes32 tag; // integration tag/ID for marking
        uint256 approvedCupAmount; // fixed CUP amount approved (for external)
        uint256 priceSnapshot; // price used for approval (for external)
    }

    /**
     * @notice Struct for ERC20 permit parameters to enable gasless approvals
     * @dev Used with ERC20Permit tokens to allow users to approve and deposit in one transaction
     * @param value The amount to approve for spending
     * @param deadline The timestamp after which the permit is no longer valid
     * @param v The recovery identifier of the signature (27 or 28)
     * @param r The first 32 bytes of the signature
     * @param s The second 32 bytes of the signature
     */
    struct PermitParams {
        uint256 value;
        uint256 deadline;
        uint8 v;
        bytes32 r;
        bytes32 s;
    }

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

    /// @dev Emitted when an external deposit is registered (no token movement)
    event ExternalDepositRegistered(
        address indexed createdBy,
        address indexed beneficiary,
        bytes32 indexed depositId,
        bytes32 tag,
        uint256 usdcAmount
    );

    /**
     * @notice Event emitted when redeem commission is updated
     */
    event RedeemCommissionUpdated(uint256 newCommissionBps);

    /**
     * @dev
     */
    error PermitFailed();

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
     * @notice Removes a deposit ID from the pending deposits array using swap-and-pop pattern
     * @dev This function maintains array integrity by swapping the target element with the last
     *      element and then removing the last element. This avoids gaps in the array but
     *      changes the order of elements.
     *
     * @param depositId The deposit ID to remove from pending deposits
     */
    function _removePendingDeposit(bytes32 depositId) internal {
        // Iterate through the pending deposits array to find the target depositId
        for (uint256 i = 0; i < _pendingDepositIds.length; i++) {
            if (_pendingDepositIds[i] == depositId) {
                _pendingDepositIds[i] = _pendingDepositIds[_pendingDepositIds.length - 1];

                // Remove the last element (which is now duplicated)
                _pendingDepositIds.pop();

                // Exit early once found and removed
                break;
            }
        }
    }

    /**
     * @notice Removes a deposit ID from a user's personal deposit tracking list
     * @dev Similar to _removePendingDeposit, this uses swap-and-pop pattern to maintain
     *      array efficiency while removing elements. This is called when deposits are
     *      claimed, withdrawn, or declined.
     *
     * @param user The user whose deposit list should be updated
     * @param depositId The deposit ID to remove from the user's list
     */
    function _removeUserDeposit(address user, bytes32 depositId) internal {
        // Get reference to user's deposit array for efficient access
        bytes32[] storage ids = _userDeposits[user];

        // Search for the depositId in user's personal deposit list
        for (uint256 i = 0; i < ids.length; i++) {
            if (ids[i] == depositId) {
                ids[i] = ids[ids.length - 1];

                // Remove the last element (now duplicated)
                ids.pop();

                // Exit immediately after successful removal
                break;
            }
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
        require(_approvedDeposits[depositId].user == address(0), "Deposit ID already exists");

        _approvedDeposits[depositId] = Deposit({
            user: _msgSender(),
            depositId: depositId,
            amount: amount,
            approvedAmount: 0,
            approved: false,
            beneficiary: address(0),
            createdBy: _msgSender(),
            claimedBy: address(0),
            isExternal: false,
            tag: bytes32(0),
            approvedCupAmount: 0,
            priceSnapshot: 0
        });
        _pendingDepositIds.push(depositId);
        _userDeposits[_msgSender()].push(depositId);
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
    function _recordExternalDeposit(uint256 usdcAmount, address beneficiary_, bytes32 tag_)
        internal
        returns (bytes32 depositId)
    {
        require(beneficiary_ != address(0), "Invalid beneficiary");
        depositId = keccak256(abi.encodePacked(_msgSender(), block.timestamp, usdcAmount, beneficiary_, tag_));
        _approvedDeposits[depositId] = Deposit({
            user: _msgSender(),
            depositId: depositId,
            amount: usdcAmount,
            approvedAmount: 0,
            approved: false,
            beneficiary: beneficiary_,
            createdBy: _msgSender(),
            claimedBy: address(0),
            isExternal: true,
            tag: tag_,
            approvedCupAmount: 0,
            priceSnapshot: 0
        });
        _pendingDepositIds.push(depositId);
        _userDeposits[beneficiary_].push(depositId);
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
        uint256 initialTokenOutBalance = _usdc.balanceOf(address(_silo));

        // Handle token transfer based on input type (ERC20 vs ETH)
        if (address(tokenIn) != address(0)) {
            // ERC20 token: Transfer from user to this contract for swap
            tokenIn.safeTransferFrom(_msgSender(), address(this), amount);
        }

        // Handle router approval based on input type
        if (address(tokenIn) != address(0)) {
            // ERC20 token: Approve Uniswap router to spend tokens
            // Use forceApprove to handle tokens with non-standard approval behavior
            IERC20(address(tokenIn)).forceApprove(router(), amount);
        } else {
            // ETH case: Validate that msg.value matches the specified amount
            require(msg.value == amount, "Invalid ETH amount");
        }

        _tradeForToken(address(tokenIn), usdc(), amount, slippageBps);

        uint256 balanceAfterZap = _usdc.balanceOf(address(_silo));

        depositValue = balanceAfterZap - initialTokenOutBalance;
    }

    /**
     * @notice Executes a token swap on Uniswap V2 with automatic path routing
     * @dev This function handles the low-level DEX interaction including path construction,
     *      slippage calculation, and swap execution. It automatically handles ETH/WETH
     *      conversion and applies slippage protection.
     *
     * @param tokenIn The address of the input token (address(0) for ETH)
     * @param tokenOut The address of the output token (typically USDC)
     * @param amountIn The amount of input tokens to swap
     * @param slippageBps The slippage tolerance in basis points (100 = 1%)
     */
    function _tradeForToken(address tokenIn, address tokenOut, uint256 amountIn, uint256 slippageBps) internal {
        // Construct trading path for Uniswap V2 (direct pair assumed)
        address[] memory path = new address[](2);

        // Handle ETH representation in trading path
        if (tokenIn == address(0)) {
            // ETH case: Use WETH address for Uniswap routing
            path[0] = _router.WETH();
        } else {
            // ERC20 token case: Use token address directly
            path[0] = tokenIn;
        }
        path[1] = tokenOut;

        // Query expected output amounts from Uniswap router
        uint256[] memory amountsOut = _router.getAmountsOut(amountIn, path);

        // Handle ETH swaps specially (require ETH to be sent with transaction)
        if (tokenIn == address(0) || tokenIn == _router.WETH()) {
            // send ETH along
            _router.swapExactETHForTokens{value: amountIn}(amountsOut[1], path, address(_silo), block.timestamp);
            return;
        }

        // Calculate minimum output with custom slippage tolerance
        uint256 minOutput = (amountsOut[1] * (10000 - slippageBps)) / 10000;

        _router.swapExactTokensForTokens(amountIn, minOutput, path, address(_silo), block.timestamp);
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
    function _execPermit(IERC20 token, address owner, address spender, PermitParams calldata permitParams) internal {
        ERC20Permit(address(token))
            .permit(
                owner,
                spender,
                permitParams.value,
                permitParams.deadline,
                permitParams.v,
                permitParams.r,
                permitParams.s
            );
        if (token.allowance(owner, spender) != permitParams.value) {
            revert PermitFailed();
        }
    }

    /**
     * @dev Processes a deposit by either transferring USDC directly or zapping other tokens
     * @param tokenIn The token being deposited (address(0) == ETH)
     * @param amount The amount of tokens to deposit
     * @param slippageBps The slippage tolerance in basis points (e.g., 100 = 1%)
     * @return depositValue The final USDC value of the deposit
     */
    function _processDeposit(IERC20 tokenIn, uint256 amount, uint256 slippageBps)
        internal
        returns (uint256 depositValue)
    {
        if (address(tokenIn) == address(_usdc)) {
            tokenIn.safeTransferFrom(_msgSender(), address(_silo), amount);
            depositValue = amount;
        } else {
            depositValue = _zapIn(tokenIn, amount, slippageBps);
        }
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
        PermitParams calldata permitParams,
        bytes32 depositId,
        uint256 slippageBps
    ) external payable whenNotPaused {
        // allow address(0) for ETH
        require(amount != 0, "Invalid amount");

        // Use default slippage of 1% (100 basis points) if 0 is passed
        uint256 actualSlippage = slippageBps == 0 ? 100 : slippageBps;

        if (address(tokenIn) != address(0)) {
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
    function zapAndDeposit(IERC20 tokenIn, uint256 amount, bytes32 depositId, uint256 slippageBps)
        external
        payable
        whenNotPaused
    {
        // allow address(0) for ETH
        require(amount != 0, "Invalid amount");

        // Use default slippage of 1% (100 basis points) if 0 is passed
        uint256 actualSlippage = slippageBps == 0 ? 100 : slippageBps;

        if (address(tokenIn) == address(0)) {
            require(msg.value == amount, "Invalid ETH amount");
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
    function registerExternalDepositFor(address beneficiary_, uint256 usdcAmount, bytes32 tag_)
        external
        whenNotPaused
        onlyRole(HOST_INTEGRATION_ROLE)
        returns (bytes32 depositId)
    {
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
    function setDepositBeneficiary(bytes32 depositId, address beneficiary_)
        external
        whenNotPaused
        onlyRole(HOST_INTEGRATION_ROLE)
    {
        require(beneficiary_ != address(0), "Invalid beneficiary");
        Deposit storage d = _approvedDeposits[depositId];
        require(d.user != address(0) && !d.approved, "Not pending");
        d.beneficiary = beneficiary_;
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
        Deposit storage deposit = _approvedDeposits[depositId];

        require(deposit.user == _msgSender(), "Invalid user");
        require(deposit.user != address(0), "Deposit not found");
        require(!deposit.approved, "Deposit already approved");

        uint256 refundAmount = deposit.amount;
        delete _approvedDeposits[depositId];
        _removePendingDeposit(depositId);
        _removeUserDeposit(_msgSender(), depositId);

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
            Deposit storage deposit = _approvedDeposits[depositId];

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
            Deposit storage deposit = _approvedDeposits[depositId];

            // Clean up the deposit
            delete _approvedDeposits[depositId];
            _removePendingDeposit(depositId);
            _removeUserDeposit(_msgSender(), depositId);
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
    function approveDeposit(bytes32 depositId, uint256 approvedAmount)
        external
        whenNotPaused
        whenEpochActive
        onlyRole(VAULT_CURATOR_ROLE)
    {
        Deposit storage deposit = _approvedDeposits[depositId];

        require(deposit.user != address(0), "Deposit not found");
        require(!deposit.approved, "Deposit already approved");
        require(approvedAmount > 0, "Approved amount must be greater than 0");
        require(approvedAmount <= deposit.amount, "Approved amount exceeds deposit amount");

        deposit.approved = true;
        deposit.approvedAmount = approvedAmount;

        emit DepositApproved(depositId, approvedAmount);
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
    function approveExternalDepositWithPrice(bytes32 depositId, uint256 approvedUsdc, uint256 price)
        external
        whenNotPaused
        whenEpochActive
        onlyRole(VAULT_CURATOR_ROLE)
    {
        Deposit storage deposit = _approvedDeposits[depositId];
        require(deposit.user != address(0), "Deposit not found");
        require(deposit.isExternal, "Not external deposit");
        require(!deposit.approved, "Deposit already approved");
        require(approvedUsdc > 0, "Approved amount must be greater than 0");
        require(approvedUsdc <= deposit.amount, "Approved amount exceeds deposit amount");
        require(price > 0, "Invalid price");

        deposit.approved = true;
        deposit.approvedAmount = approvedUsdc;
        deposit.priceSnapshot = price;
        // Calculate CUP amount using the same formula as in claimDeposit
        deposit.approvedCupAmount = (approvedUsdc * (10 ** 8)) / price;

        emit DepositApproved(depositId, approvedUsdc);
    }

    /**
     * @notice Allows vault curators to decline a deposit and issue a full refund
     * @dev This function enables curators to reject deposits that don't meet criteria
     *      and automatically refund the full amount to the user. This provides a
     *      mechanism for regulatory compliance and risk management.
     *
     * @param depositId The unique identifier of the deposit to decline
     */
    function declineDeposit(bytes32 depositId)
        external
        whenNotPaused
        whenEpochActive
        onlyRole(VAULT_CURATOR_ROLE)
        nonReentrant
    {
        Deposit storage deposit = _approvedDeposits[depositId];

        require(deposit.user != address(0), "Deposit not found");
        require(!deposit.approved, "Deposit already approved");

        uint256 refundAmount = deposit.amount;
        address user = deposit.user;

        delete _approvedDeposits[depositId];
        _removePendingDeposit(depositId);
        _removeUserDeposit(user, depositId);

        // Return USDC to user
        require(_usdc.balanceOf(address(_silo)) >= refundAmount, "Insufficient USDC balance");
        _usdc.safeTransferFrom(address(_silo), user, refundAmount);

        emit DepositDeclined(depositId, user, refundAmount);
    }

    /**
     * @notice Allows vault curators to approve multiple deposits proportionally
     * @dev This function enables curators to approve a specific total amount across
     *      all pending deposits, with each deposit receiving a proportional share.
     *      This is useful for managing vault capacity and fair distribution.
     *
     * @param targetTotalAmount The total USDC amount to approve across all deposits
     */
    function approveDepositsProportionally(uint256 targetTotalAmount)
        external
        whenNotPaused
        whenEpochActive
        onlyRole(VAULT_CURATOR_ROLE)
    {
        require(targetTotalAmount > 0, "Target amount must be greater than 0");
        require(_pendingDepositIds.length > 0, "No pending deposits");

        // Calculate total pending deposits
        uint256 totalPendingAmount;
        uint256 validDeposits;

        for (uint256 i = 0; i < _pendingDepositIds.length; i++) {
            Deposit storage deposit = _approvedDeposits[_pendingDepositIds[i]];
            if (deposit.user != address(0) && !deposit.approved) {
                totalPendingAmount += deposit.amount;
                validDeposits++;
            }
        }

        require(totalPendingAmount > 0, "No valid pending deposits");
        require(targetTotalAmount <= totalPendingAmount, "Target amount exceeds total pending");

        // Calculate proportion (scaled by 1e18 for precision)
        uint256 proportion = (targetTotalAmount * 1e18) / totalPendingAmount;

        bytes32 depositId;
        uint256 approvedAmount;

        // Approve deposits proportionally
        for (uint256 i = 0; i < _pendingDepositIds.length; i++) {
            depositId = _pendingDepositIds[i];
            Deposit storage deposit = _approvedDeposits[depositId];

            if (deposit.user != address(0) && !deposit.approved) {
                approvedAmount = (deposit.amount * proportion) / 1e18;
                if (approvedAmount > 0) {
                    deposit.approved = true;
                    deposit.approvedAmount = approvedAmount;
                    emit DepositApproved(depositId, approvedAmount);
                }
            }
        }

        emit ProportionalApproval(targetTotalAmount, totalPendingAmount, proportion);
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
        require(_pendingDepositIds.length > 0, "No pending deposits");

        bytes32 depositId;

        // Approve all pending deposits in full
        for (uint256 i = 0; i < _pendingDepositIds.length; i++) {
            depositId = _pendingDepositIds[i];
            Deposit storage deposit = _approvedDeposits[depositId];

            if (deposit.user != address(0) && !deposit.approved) {
                deposit.approved = true;
                deposit.approvedAmount = deposit.amount;
                totalApproved += deposit.amount;
                depositsApproved++;

                emit DepositApproved(depositId, deposit.amount);
            }
        }

        require(depositsApproved > 0, "No valid pending deposits to approve");

        emit ProportionalApproval(totalApproved, totalApproved, 1e18); // 100% proportion
    }

    /**
     * @dev Allows users to claim their approved deposits and receive vault shares
     * @param depositId The unique identifier of the deposit to claim
     * @return shares The number of vault shares received
     */
    function claimDeposit(bytes32 depositId) public whenNotPaused whenEpochActive returns (uint256 shares) {
        Deposit storage deposit = _approvedDeposits[depositId];

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

        // Determine CUP amount to deposit and get shares
        uint256 cupValue;
        if (isExternal) {
            // For external deposits, use pre-approved CUP amount and price snapshot
            require(deposit.approvedCupAmount > 0 && deposit.priceSnapshot > 0, "No snapshot");
            cupValue = deposit.approvedCupAmount;
        } else {
            // For regular deposits, convert approved USDC amount to CUP value using current copper price
            uint256 currentCopperPrice = getCopperPrice();
            require(currentCopperPrice > 0, "Copper price is 0");
            cupValue = (approvedAmount * (10 ** 8)) / currentCopperPrice;
        }

        uint256 currentCupBalance = _cup.balanceOf(address(this));
        if (currentCupBalance < cupValue) {
            // Mint the missing CUP tokens
            uint256 missingAmount = cupValue - currentCupBalance;

            // Cast to IERC20Mintable to access mint function
            // This requires the contract to have MINTER_ROLE on CUP token
            try IERC20Mintable(address(_cup)).mint(address(this), missingAmount) {
            // Minting successful
            }
            catch {
                revert("Failed to mint CUP tokens - check MINTER_ROLE");
            }
        }

        // Deposit CUP to vault and get xCUP shares
        _cup.approve(address(_vault), cupValue);
        address sharesRecipient = isExternal ? beneficiary_ : _msgSender();
        shares = _vault.deposit(cupValue, sharesRecipient);

        // Emit appropriate events
        emit DepositClaimed(depositId, sharesRecipient, shares);

        // For external deposits, emit additional detailed event
        if (isExternal) {
            emit DepositClaimedFor(depositId, user, beneficiary_, _msgSender(), deposit.tag, shares);
        }

        // If the deposit is fully approved, remove it from the pending deposits and user's list
        if (deposit.amount - approvedAmount == 0) {
            delete _approvedDeposits[depositId];
            _removePendingDeposit(depositId);
            _removeUserDeposit(user, depositId);
        } else {
            deposit.amount = deposit.amount - approvedAmount;
            deposit.approvedAmount = 0;
            deposit.approved = false;
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
            Deposit storage deposit = _approvedDeposits[id];

            if (
                (deposit.user == _msgSender() || (deposit.isExternal && deposit.beneficiary == _msgSender()))
                    && deposit.approved && deposit.approvedAmount > 0
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
     * @notice Allows the contract owner to withdraw USDC from the Silo for management purposes
     * @dev This function provides the owner with the ability to withdraw USDC from the Silo
     *      for operational purposes such as rebalancing, emergency management, or protocol
     *      maintenance. This is an administrative function with significant privileges.
     *
     * @param amount The amount of USDC to withdraw from the Silo (6 decimals)
     */
    function withdraw(uint256 amount) external nonReentrant onlyRole(VAULT_CURATOR_ROLE) {
        require(_usdc.balanceOf(address(silo())) >= amount, "Insufficient USDC balance");

        _usdc.safeTransferFrom(silo(), owner(), amount);

        emit Withdraw(owner(), amount);
    }

    /**
     * @notice Allows users to redeem their xCUP vault shares for USDC
     * @dev This function enables users to exit their vault position by redeeming xCUP
     *      shares for the underlying CUP tokens, then converting them back to USDC
     *      using the current copper price. This provides liquidity for vault investors.
     *
     * @param sharesToRedeem The number of xCUP vault shares to redeem
     * @return usdcToWithdraw The amount of USDC received from redemption
     */
    function redeem(uint256 sharesToRedeem) external nonReentrant returns (uint256 usdcToWithdraw) {
        require(sharesToRedeem > 0, "Shares to redeem must be greater than 0");

        uint256 ownedShares = _vault.balanceOf(_msgSender());
        require(ownedShares >= sharesToRedeem, "Insufficient shares to redeem");

        IERC20(address(_vault)).safeTransferFrom(_msgSender(), address(this), sharesToRedeem);

        _vault.approve(address(_vault), sharesToRedeem);

        uint256 withdrawnCup = _vault.redeem(sharesToRedeem, address(this), address(this));

        uint256 copperPrice = getCopperPrice();
        require(copperPrice > 0, "Copper price is 0");

        // Convert CUP back to USDC using copper price
        uint256 totalUsdcAmount = (withdrawnCup * copperPrice) / (10 ** 8);

        // Apply commission - commission stays in silo, user gets the remainder
        uint256 commissionAmount = (totalUsdcAmount * _redeemCommissionBps) / 10000;
        usdcToWithdraw = totalUsdcAmount - commissionAmount;

        _usdc.safeTransferFrom(address(_silo), address(this), usdcToWithdraw);

        require(_usdc.balanceOf(address(this)) >= usdcToWithdraw, "Insufficient USDC balance");

        _usdc.safeTransfer(_msgSender(), usdcToWithdraw);

        emit Withdraw(_msgSender(), usdcToWithdraw);
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
    function getDeposit(bytes32 depositId) external view returns (Deposit memory) {
        return _approvedDeposits[depositId];
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
        return _pendingDepositIds;
    }

    /**
     * @notice Returns all pending deposits with complete information
     * @dev This function provides detailed information about all pending deposits,
     *      including full Deposit structs. It filters out invalid entries and
     *      returns only valid, unapproved deposits.
     *
     * @return deposits Array of complete Deposit structs for all pending deposits
     */
    function getPendingDeposits() external view returns (Deposit[] memory deposits) {
        // First, count valid pending deposits
        uint256 validCount = 0;
        for (uint256 i = 0; i < _pendingDepositIds.length; i++) {
            Deposit storage deposit = _approvedDeposits[_pendingDepositIds[i]];
            if (deposit.user != address(0) && !deposit.approved) {
                validCount++;
            }
        }

        // Create array with exact size needed
        deposits = new Deposit[](validCount);
        uint256 currentIndex = 0;

        // Fill array with valid pending deposits
        for (uint256 i = 0; i < _pendingDepositIds.length; i++) {
            bytes32 depositId = _pendingDepositIds[i];
            Deposit storage deposit = _approvedDeposits[depositId];

            if (deposit.user != address(0) && !deposit.approved) {
                deposits[currentIndex] = deposit;
                currentIndex++;
            }
        }
    }

    /**
     * @dev Returns all deposit IDs for a given user
     */
    function getUserDepositIds(address user) external view returns (bytes32[] memory) {
        return _userDeposits[user];
    }

    /**
     * @dev Returns all deposits for a given user
     */
    function getUserDeposits(address user) external view returns (Deposit[] memory) {
        bytes32[] storage ids = _userDeposits[user];
        Deposit[] memory deposits = new Deposit[](ids.length);

        for (uint256 i = 0; i < ids.length; i++) {
            deposits[i] = _approvedDeposits[ids[i]];
        }

        return deposits;
    }

    /**
     * @dev Returns the total amount of all pending deposits
     * @return totalAmount The total amount of pending deposits in USDC
     */
    function getTotalPendingAmount() external view returns (uint256 totalAmount) {
        for (uint256 i = 0; i < _pendingDepositIds.length; i++) {
            Deposit storage deposit = _approvedDeposits[_pendingDepositIds[i]];
            if (deposit.user != address(0) && !deposit.approved) {
                totalAmount += deposit.amount;
            }
        }
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
    receive() external payable whenNotPaused {
        require(msg.value > 0, "No ETH sent");
        uint256 depositValue = _processDeposit(IERC20(address(0)), msg.value, 100); // Default 1% slippage
        uint256 nonce = _userNonces[msg.sender]++;
        bytes32 depositId = keccak256(abi.encodePacked(msg.sender, nonce, msg.value, block.timestamp));
        _recordDeposit(depositId, depositValue);
        emit ZapAndDeposit(router(), address(0), depositValue);
    }

    /**
     * @notice Fallback function to handle ETH sent with data or unknown function calls
     * @dev This fallback function provides a safety net for ETH sent to the contract
     *      with data or when calling non-existent functions. It processes any ETH
     *      value as a deposit, similar to the receive function.
     */
    fallback() external payable whenNotPaused {
        if (msg.value > 0) {
            uint256 depositValue = _processDeposit(IERC20(address(0)), msg.value, 100); // Default 1% slippage
            uint256 nonce = _userNonces[msg.sender]++;
            bytes32 depositId = keccak256(abi.encodePacked(msg.sender, nonce, msg.value, block.timestamp));
            _recordDeposit(depositId, depositValue);
            emit ZapAndDeposit(router(), address(0), depositValue);
        }
    }

    function requestRedeem(uint256 shares) external whenNotPaused returns (bytes32 redeemId) {
        redeemId = RedeemLib.requestRedeem(_redeems, msg.sender, shares);
    }

    function approveRedeem(bytes32 redeemId, uint256 usdcAmount) external whenNotPaused onlyRole(VAULT_CURATOR_ROLE) {
        RedeemLib.approveRedeem(_redeems, redeemId, usdcAmount);
    }

    function claimRedeem(bytes32 redeemId) external nonReentrant whenNotPaused returns (uint256 usdcAmount) {
        usdcAmount = RedeemLib.claimRedeem(
            _redeems, redeemId, msg.sender, _vault, _cup, _usdc, address(_silo), address(_copperPriceConsumer)
        );
    }

    /**
     * @notice Returns full redeem request information by ID
     * @param redeemId The unique identifier of the redeem request
     * @return RedeemRequest struct containing user, shares, usdcAmount, approved, and claimed status
     */
    function getRedeem(bytes32 redeemId) external view returns (RedeemLib.RedeemRequest memory) {
        return RedeemLib.getRedeem(_redeems, redeemId);
    }

    /**
     * @notice Sets the commission rate for direct redeem operations
     * @dev Commission is charged on direct redeem operations, with the remainder staying in silo
     * @param commissionBps Commission rate in basis points (e.g., 200 = 2%)
     */
    function setRedeemCommission(uint256 commissionBps) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(commissionBps <= 10000, "Commission cannot exceed 100%");
        _redeemCommissionBps = commissionBps;
        emit RedeemCommissionUpdated(commissionBps);
    }

    /**
     * @notice Returns the current commission rate for direct redeem operations
     * @return Commission rate in basis points
     */
    function getRedeemCommission() external view returns (uint256) {
        return _redeemCommissionBps;
    }
}
