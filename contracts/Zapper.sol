// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

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

import {console} from "hardhat/console.sol";

/**
 * @title Silo
 * @dev A simple contract that holds USDC tokens and provides unlimited approval to the Zapper contract.
 * This contract acts as a vault for USDC tokens during the zapping process.
 */
contract Silo {
    using SafeERC20 for IERC20;

    constructor(IERC20 token) {
        token.forceApprove(msg.sender, type(uint256).max);
    }
}

/**
 * @title Zapper
 * @dev A DeFi protocol contract that allows users to zap (swap) various tokens into USDC and deposit them into a vault.
 * The contract manages deposits through an approval system where vault curators can approve or decline deposits.
 */
contract Zapper is
    Initializable,
    AccessControlUpgradeable,
    OwnableUpgradeable,
    PausableUpgradeable,
    ReentrancyGuardUpgradeable
{
    using SafeERC20 for IERC20;

    /// @dev Role identifier for vault curators who can approve/decline deposits
    bytes32 public constant VAULT_CURATOR_ROLE = keccak256("VAULT_CURATOR_ROLE");
    /// @dev Role identifier for host-to-host integrations (e.g., backend adapter)
    bytes32 public constant HOST_INTEGRATION_ROLE = keccak256("HOST_INTEGRATION_ROLE");

    /// @dev CUP token contract address
    IERC20 private _cup;
    /// @dev USDC token contract address
    IERC20 private _usdc;
    /// @dev xCUP vault contract (ERC4626 compliant)
    IERC4626 private _vault;
    /// @dev Uniswap V2 router for token swaps
    IUniswapV2Router02 private _router;
    /// @dev Copper price oracle consumer
    ICopperPriceConsumer private _copperPriceConsumer;
    /// @dev Silo contract that holds USDC during operations
    Silo private _silo;
    /// @dev Epoch manager for time-based operations
    IEpochManager private _epochManager;

    /// @dev Mapping of deposit IDs to deposit information
    mapping(bytes32 depositId => Deposit) private _approvedDeposits;
    /// @dev Array of pending deposit IDs
    bytes32[] private _pendingDepositIds;

    /**
     * @dev Struct representing a user deposit
     * @param user The address of the user who made the deposit
     * @param depositId Unique identifier for the deposit
     * @param amount Total amount deposited in USDC
     * @param approvedAmount Amount approved by vault curators
     * @param approved Whether the deposit has been approved
     */
    struct Deposit {
        address user;            // originator (payer) for on-chain deposits
        bytes32 depositId;       // unique identifier
        uint256 amount;          // pending USDC value
        uint256 approvedAmount;  // approved USDC value
        bool approved;           // approved flag

        // Extended fields for host-to-host external deposits
        address beneficiary;     // who will receive xCUP on claim
        address createdBy;       // who initiated the deposit (EOA/adapter)
        address claimedBy;       // who executed the claim
        bool isExternal;         // true if created via external adapter flow
        bytes32 tag;             // integration tag/ID for marking
        uint256 approvedCupAmount; // fixed CUP amount approved (for external)
        uint256 priceSnapshot;     // price used for approval (for external)
    }

    /**
     * @dev Struct for permit parameters (currently unused but reserved for future use)
     * @param value The permit value
     * @param deadline The permit deadline
     * @param v The v component of the signature
     * @param r The r component of the signature
     * @param s The s component of the signature
     */
    struct PermitParams {
        uint256 value;
        uint256 deadline;
        uint8 v;
        bytes32 r;
        bytes32 s;
    }

    /**
     * @dev Emitted when a user claims their approved deposit and receives vault shares
     * @param depositId The unique identifier of the deposit
     * @param user The address of the user claiming the deposit
     * @param shares The number of vault shares received
     */
    event DepositClaimed(bytes32 depositId, address user, uint256 shares);

    /// @dev Richer claim event for external/beneficiary based flows
    event DepositClaimedFor(
        bytes32 indexed depositId,
        address indexed user,
        address indexed beneficiary,
        address claimedBy,
        bytes32 tag,
        uint256 shares
    );

    /**
     * @dev Emitted when a vault curator approves a deposit
     * @param depositId The unique identifier of the deposit
     * @param approvedAmount The amount approved for the deposit
     */
    event DepositApproved(bytes32 depositId, uint256 approvedAmount);

    /**
     * @dev Emitted when a vault curator declines a deposit and refunds the user
     * @param depositId The unique identifier of the deposit
     * @param user The address of the user whose deposit was declined
     * @param refundAmount The amount refunded to the user
     */
    event DepositDeclined(bytes32 depositId, address user, uint256 refundAmount);

    /**
     * @dev Emitted when a user withdraws their deposit before approval
     * @param depositId The unique identifier of the deposit
     * @param user The address of the user withdrawing the deposit
     * @param amount The amount withdrawn
     */
    event DepositWithdrawn(bytes32 depositId, address user, uint256 amount);

    /**
     * @dev Emitted when deposits are approved proportionally
     * @param totalApproved Total amount approved across all deposits
     * @param totalDeposited Total amount deposited across all pending deposits
     * @param proportion The proportion used for approval (scaled by 1e18)
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
     * @param tokenIn The address of the input token
     * @param amount The amount of tokens zapped and deposited
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
     * @dev
     */
    error PermitFailed();

    /**
     * @dev Modifier that ensures the epoch is active
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
     * @dev Initializes the Zapper contract with required addresses and configurations
     * @param cup The address of the CUP token contract
     * @param usdc The address of the USDC token contract
     * @param vault The address of the xCUP vault contract (ERC4626)
     * @param router The address of the Uniswap V2 router
     * @param copperPriceConsumer The address of the copper price oracle consumer
     * @param epochManager The address of the epoch manager contract
     */
    function initialize(
        address cup,
        address usdc,
        address vault,
        address router,
        address copperPriceConsumer,
        address epochManager
    ) public initializer {
        require(cup != address(0), "Invalid CUP address");
        require(usdc != address(0), "Invalid USDC address");
        require(vault != address(0), "Invalid Vault address");
        require(router != address(0), "Invalid Router address");
        require(copperPriceConsumer != address(0), "Invalid Copper Price Consumer address");
        require(epochManager != address(0), "Invalid Epoch Manager address");

        __AccessControl_init();
        __Ownable_init(_msgSender());
        __Pausable_init();
        __ReentrancyGuard_init();

        _grantRole(DEFAULT_ADMIN_ROLE, _msgSender());

        _cup = IERC20(cup);
        _usdc = IERC20(usdc);
        _vault = IERC4626(vault);
        _router = IUniswapV2Router02(router);
        _copperPriceConsumer = ICopperPriceConsumer(copperPriceConsumer);

        _silo = new Silo(_usdc);
        _epochManager = IEpochManager(epochManager);
    }

    /**
     * @dev Removes a deposit ID from the pending deposits array
     * @param depositId The deposit ID to remove
     */
    function _removePendingDeposit(bytes32 depositId) internal {
        for (uint256 i = 0; i < _pendingDepositIds.length; i++) {
            if (_pendingDepositIds[i] == depositId) {
                _pendingDepositIds[i] = _pendingDepositIds[_pendingDepositIds.length - 1];
                _pendingDepositIds.pop();
                break;
            }
        }
    }

    /**
     * @dev Records a new deposit in the system
     * @param amount The amount of the deposit in USDC
     * @return depositId The unique identifier for the deposit
     */
    function _recordDeposit(uint256 amount) internal returns (bytes32 depositId) {
        // Generate a unique deposit ID
        depositId = keccak256(abi.encodePacked(_msgSender(), block.timestamp, amount));
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
    }

    /**
     * @dev Records a new external deposit (no token transfer) with beneficiary and tag
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
    }

    /**
     * @dev Swaps input tokens for USDC using Uniswap V2
     * @param tokenIn The token to swap from
     * @param amount The amount of tokens to swap
     * @return depositValue The amount of USDC received from the swap
     */
    function _zapIn(IERC20 tokenIn, uint256 amount) internal returns (uint256 depositValue) {
        uint256 initialTokenOutBalance = _usdc.balanceOf(address(_silo));

        if (msg.value == 0) {
            tokenIn.safeTransferFrom(_msgSender(), address(this), amount);
        }

        // WETH check
        if (address(tokenIn) != _router.WETH()) {
            tokenIn.forceApprove(router(), amount);
        } else {
            require(msg.value == amount, "Invalid ETH amount");
        }
        _tradeForToken(address(tokenIn), usdc(), amount);

        uint256 balanceAfterZap = _usdc.balanceOf(address(_silo));

        depositValue = balanceAfterZap - initialTokenOutBalance;
    }

    /**
     * @dev Executes a token swap on Uniswap V2
     * @param tokenIn The address of the input token
     * @param tokenOut The address of the output token
     * @param amountIn The amount of input tokens to swap
     */
    function _tradeForToken(address tokenIn, address tokenOut, uint256 amountIn) internal {
        address[] memory path = new address[](2);
        path[0] = tokenIn;
        path[1] = tokenOut;

        // Get the amount of tokens out for the given amount in
        uint256[] memory amountsOut = _router.getAmountsOut(amountIn, path);

        // If the token in is ETH, swap ETH for USDC
        if (address(tokenIn) == _router.WETH()) {
            _router.swapExactETHForTokens{value: amountIn}(amountsOut[1], path, address(_silo), block.timestamp);
            return;
        }

        // Calculate minimum output with 1% slippage tolerance
        uint256 minOutput = (amountsOut[1] * 99) / 100;

        _router.swapExactTokensForTokens(amountIn, minOutput, path, address(_silo), block.timestamp);
    }

    /**
     * @dev The `_executePermit` function is used to execute a permit.
     */
    function _execPermit(IERC20 token, address owner, address spender, PermitParams calldata permitParams) internal {
        ERC20Permit(address(token)).permit(
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
     * @param tokenIn The token being deposited
     * @param amount The amount of tokens to deposit
     * @return depositValue The final USDC value of the deposit
     */
    function _processDeposit(IERC20 tokenIn, uint256 amount) internal returns (uint256 depositValue) {
        if (tokenIn == _usdc) {
            tokenIn.safeTransferFrom(_msgSender(), address(_silo), amount);
            depositValue = amount;
        } else {
            depositValue = _zapIn(tokenIn, amount);
        }
    }

    /**
     * @dev Allows users to zap tokens into USDC and create a deposit
     * @param tokenIn The token to zap (can be any ERC20 or ETH)
     * @param amount The amount of tokens to zap
     * @return depositId The unique identifier for the created deposit
     */
    function zapAndDepositWithPermit(
        IERC20 tokenIn,
        uint256 amount,
        PermitParams calldata permitParams
    ) external payable whenNotPaused returns (bytes32 depositId) {
        require(address(tokenIn) != address(0), "Invalid token");
        require(amount != 0, "Invalid amount");

        if (tokenIn.allowance(_msgSender(), address(this)) < amount) {
            _execPermit(tokenIn, _msgSender(), address(this), permitParams);
        }

        uint256 depositValue = _processDeposit(tokenIn, amount);
        depositId = _recordDeposit(depositValue);

        emit ZapAndDeposit(router(), address(tokenIn), depositValue);
    }

    /**
     * @dev Allows users to zap tokens into USDC and create a deposit
     * @param tokenIn The token to zap (can be any ERC20 or ETH)
     * @param amount The amount of tokens to zap
     * @return depositId The unique identifier for the created deposit
     */
    function zapAndDeposit(IERC20 tokenIn, uint256 amount) external payable whenNotPaused returns (bytes32 depositId) {
        require(address(tokenIn) != address(0), "Invalid token");
        require(amount != 0, "Invalid amount");

        uint256 depositValue = _processDeposit(tokenIn, amount);
        depositId = _recordDeposit(depositValue);

        emit ZapAndDeposit(router(), address(tokenIn), depositValue);
    }

    /**
     * @dev Host-to-host integration: register an external deposit for a beneficiary with a tag
     * No token movement occurs here; values are informational until approval/claim.
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
     * @dev Optional: allow host to update beneficiary before approval
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
     * @dev Allows users to withdraw their deposit before it's approved
     * @param depositId The unique identifier of the deposit to withdraw
     */
    function withdrawDeposit(bytes32 depositId) external whenNotPaused {
        Deposit storage deposit = _approvedDeposits[depositId];

        require(deposit.user == _msgSender(), "Invalid user");
        require(deposit.user != address(0), "Deposit not found");
        require(!deposit.approved, "Deposit already approved");

        uint256 refundAmount = deposit.amount;
        delete _approvedDeposits[depositId];
        _removePendingDeposit(depositId);

        // Return USDC to user
        require(_usdc.balanceOf(address(silo())) >= refundAmount, "Insufficient USDC balance");
        _usdc.safeTransferFrom(address(silo()), _msgSender(), refundAmount);

        emit DepositWithdrawn(depositId, _msgSender(), refundAmount);
    }

    /**
     * @dev Allows vault curators to approve a specific deposit
     * @param depositId The unique identifier of the deposit to approve
     * @param approvedAmount The amount to approve (must be <= total deposit amount)
     */
    function approveDeposit(
        bytes32 depositId,
        uint256 approvedAmount
    ) external whenNotPaused whenEpochActive onlyRole(VAULT_CURATOR_ROLE) {
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
     * @dev Approve an external deposit with an explicit price snapshot.
     * Records a fixed CUP amount to be used on claim.
     */
    function approveExternalDepositWithPrice(
        bytes32 depositId,
        uint256 approvedUsdc,
        uint256 price
    ) external whenNotPaused whenEpochActive onlyRole(VAULT_CURATOR_ROLE) {
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
        deposit.approvedCupAmount = approvedUsdc * price;

        emit DepositApproved(depositId, approvedUsdc);
    }

    /**
     * @dev Allows vault curators to decline a deposit and refund the user
     * @param depositId The unique identifier of the deposit to decline
     */
    function declineDeposit(bytes32 depositId) external whenNotPaused whenEpochActive onlyRole(VAULT_CURATOR_ROLE) {
        Deposit storage deposit = _approvedDeposits[depositId];

        require(deposit.user != address(0), "Deposit not found");
        require(!deposit.approved, "Deposit already approved");

        uint256 refundAmount = deposit.amount;
        address user = deposit.user;

        delete _approvedDeposits[depositId];
        _removePendingDeposit(depositId);

        // Return USDC to user
        require(_usdc.balanceOf(address(_silo)) >= refundAmount, "Insufficient USDC balance");
        _usdc.safeTransferFrom(address(_silo), user, refundAmount);

        emit DepositDeclined(depositId, user, refundAmount);
    }

    /**
     * @dev Allows vault curators to approve multiple deposits proportionally
     * @param targetTotalAmount The total amount to approve across all pending deposits
     */
    function approveDepositsProportionally(
        uint256 targetTotalAmount
    ) external whenNotPaused whenEpochActive onlyRole(VAULT_CURATOR_ROLE) {
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
     * @dev Allows users to claim their approved deposits and receive vault shares
     * @param depositId The unique identifier of the deposit to claim
     * @return shares The number of vault shares received
     */
    function claimDeposit(bytes32 depositId) external whenNotPaused whenEpochActive returns (uint256 shares) {
        Deposit storage deposit = _approvedDeposits[depositId];
        uint256 currentCopperPrice = getCopperPrice();

        // Allow either original user or designated beneficiary to claim
        address beneficiary_ = deposit.beneficiary == address(0) ? deposit.user : deposit.beneficiary;
        require(_msgSender() == deposit.user || _msgSender() == beneficiary_, "Not authorized to claim");
        require(deposit.approved, "Deposit not approved");
        require(deposit.approvedAmount > 0, "No approved amount");

        uint256 approvedAmount = deposit.approvedAmount;
        uint256 totalAmount = deposit.amount;

        // If the deposit is fully approved, remove it from the pending deposits
        if (totalAmount - approvedAmount == 0) {
            delete _approvedDeposits[depositId];
            _removePendingDeposit(depositId);
        } else {
            deposit.amount = totalAmount - approvedAmount;
            deposit.approvedAmount = 0;
            deposit.approved = false;
        }

        // Determine CUP amount to deposit
        uint256 cupValue;
        if (deposit.isExternal) {
            require(deposit.approvedCupAmount > 0 && deposit.priceSnapshot > 0, "No snapshot");
            cupValue = deposit.approvedCupAmount;
        } else {
            require(currentCopperPrice > 0, "Copper price is 0");
            cupValue = approvedAmount * currentCopperPrice;
        }

        console.log("cupValue", cupValue);

        require(_cup.balanceOf(address(this)) >= cupValue, "Insufficient CUP balance");

        // Deposit CUP to vault and get xCUP shares
        _cup.approve(address(_vault), cupValue);
        shares = _vault.deposit(cupValue, beneficiary_);

        // mark claimer and emit events
        deposit.claimedBy = _msgSender();
        emit DepositClaimed(depositId, beneficiary_, shares);
        emit DepositClaimedFor(depositId, deposit.user, beneficiary_, _msgSender(), deposit.tag, shares);
    }

    /**
     * @dev Allows the contract owner to withdraw USDC from the silo
     * @param amount The amount of USDC to withdraw
     */
    function withdraw(uint256 amount) external onlyOwner {
        require(_usdc.balanceOf(address(silo())) >= amount, "Insufficient USDC balance");

        _usdc.safeTransferFrom(silo(), owner(), amount);

        emit Withdraw(owner(), amount);
    }

    /**
     * @dev Allows users to redeem their vault shares for USDC
     * @param sharesToRedeem The number of vault shares to redeem
     * @return usdcToWithdraw The amount of USDC received
     */
    function redeem(uint256 sharesToRedeem) external returns (uint256 usdcToWithdraw) {
        require(sharesToRedeem > 0, "Shares to redeem must be greater than 0");

        uint256 ownedShares = _vault.balanceOf(_msgSender());
        require(ownedShares >= sharesToRedeem, "Insufficient shares to redeem");

        IERC20(address(_vault)).safeTransferFrom(_msgSender(), address(this), sharesToRedeem);

        _vault.approve(address(_vault), sharesToRedeem);

        uint256 withdrawnCup = _vault.redeem(sharesToRedeem, address(this), address(this));

        uint256 copperPrice = getCopperPrice();
        require(copperPrice > 0, "Copper price is 0");

        usdcToWithdraw = withdrawnCup / copperPrice;

        _usdc.safeTransferFrom(address(_silo), address(this), usdcToWithdraw);

        require(_usdc.balanceOf(address(this)) >= usdcToWithdraw, "Insufficient USDC balance");

        _usdc.safeTransfer(_msgSender(), usdcToWithdraw);

        emit Withdraw(_msgSender(), usdcToWithdraw);
    }

    /**
     * @dev Returns the current copper price from the oracle
     * @return price The copper price (scaled down by 10^8)
     */
    function getCopperPrice() public view returns (uint256 price) {
        price = _copperPriceConsumer.price() / 10 ** 8;
    }

    /**
     * @dev Returns the deposit information for a given deposit ID
     * @param depositId The unique identifier of the deposit
     * @return The deposit information
     */
    function getDeposit(bytes32 depositId) external view returns (Deposit memory) {
        return _approvedDeposits[depositId];
    }

    /**
     * @dev Returns all pending deposit IDs
     * @return Array of pending deposit IDs
     */
    function getPendingDepositIds() external view returns (bytes32[] memory) {
        return _pendingDepositIds;
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
}
