// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";

import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";

import {IUniswapV2Router02} from "@uniswap/v2-periphery/contracts/interfaces/IUniswapV2Router02.sol";

import {ICopperPriceConsumer} from "./interfaces/ICopperPriceConsumer.sol";
import {IEpochManager} from "./interfaces/IEpochManager.sol";

import {console} from "hardhat/console.sol";

contract Silo {
    using SafeERC20 for IERC20;

    constructor(IERC20 token) {
        token.forceApprove(msg.sender, type(uint256).max);
    }
}

contract Zapper is AccessControl, Ownable, Pausable {
    using SafeERC20 for IERC20;

    bytes32 public constant VAULT_CURATOR_ROLE = keccak256("VAULT_CURATOR_ROLE");

    IERC20 private _cup;
    IERC20 private _usdc;

    IERC4626 private _vault;

    IUniswapV2Router02 private _router;

    ICopperPriceConsumer private _copperPriceConsumer;

    Silo private _silo;

    IEpochManager private _epochManager;

    mapping(bytes32 depositId => Deposit) private _approvedDeposits;

    bytes32[] private _pendingDepositIds;

    struct Deposit {
        address user;
        bytes32 depositId;
        uint256 amount;
        uint256 approvedAmount;
        bool approved;
    }

    struct PermitParams {
        uint256 value;
        uint256 deadline;
        uint8 v;
        bytes32 r;
        bytes32 s;
    }

    event DepositClaimed(bytes32 depositId, address user, uint256 shares);

    event DepositApproved(bytes32 depositId, uint256 approvedAmount);

    event DepositDeclined(bytes32 depositId, address user, uint256 refundAmount);

    event DepositWithdrawn(bytes32 depositId, address user, uint256 amount);

    event ProportionalApproval(uint256 totalApproved, uint256 totalDeposited, uint256 proportion);

    event Withdraw(address indexed user, uint256 amount);

    /**
     * @dev The `ZapAndDeposit` event is emitted when a user zaps in and
     * deposits
     * assets into a vault.
     */
    event ZapAndDeposit(address indexed router, address indexed tokenIn, uint256 amount);

    modifier whenEpochActive() {
        require(_epochManager.timeLeftInEpoch() > 0, "Epoch not active");
        _;
    }

    constructor(
        address cup,
        address usdc,
        address vault,
        address router,
        address copperPriceConsumer,
        address epochManager
    ) Ownable(_msgSender()) {
        require(cup != address(0), "Invalid CUP address");
        require(vault != address(0), "Invalid Vault address");
        require(router != address(0), "Invalid Router address");
        require(copperPriceConsumer != address(0), "Invalid Copper Price Consumer address");

        _grantRole(DEFAULT_ADMIN_ROLE, _msgSender());

        _cup = IERC20(cup);
        _usdc = IERC20(usdc);
        _vault = IERC4626(vault);
        _router = IUniswapV2Router02(router);
        _copperPriceConsumer = ICopperPriceConsumer(copperPriceConsumer);

        _silo = new Silo(_usdc);
        _epochManager = IEpochManager(epochManager);
    }

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

    function _removePendingDeposit(bytes32 depositId) internal {
        for (uint256 i = 0; i < _pendingDepositIds.length; i++) {
            if (_pendingDepositIds[i] == depositId) {
                _pendingDepositIds[i] = _pendingDepositIds[_pendingDepositIds.length - 1];
                _pendingDepositIds.pop();
                break;
            }
        }
    }

    function _recordDeposit(uint256 amount) internal returns (bytes32 depositId) {
        // Generate a unique deposit ID
        depositId = keccak256(abi.encodePacked(_msgSender(), block.timestamp, amount));
        _approvedDeposits[depositId] = Deposit({
            user: _msgSender(),
            depositId: depositId,
            amount: amount,
            approvedAmount: 0,
            approved: false
        });
        _pendingDepositIds.push(depositId);
    }

    function _zapIn(IERC20 tokenIn, uint256 amount) internal returns (uint256 depositValue) {
        uint256 initialTokenOutBalance = _usdc.balanceOf(address(_silo));

        if (msg.value == 0) {
            tokenIn.safeTransferFrom(_msgSender(), address(this), amount);
        }

        // WETH check
        if (address(tokenIn) != 0xfFf9976782d46CC05630D1f6eBAb18b2324d6B14) {
            tokenIn.forceApprove(router(), amount);
        } else {
            require(msg.value == amount, "Invalid ETH amount");
        }
        _tradeForToken(address(tokenIn), usdc(), amount);

        uint256 balanceAfterZap = _usdc.balanceOf(address(_silo));

        console.log("balanceAfterZap", balanceAfterZap);
        console.log("initialTokenOutBalance", initialTokenOutBalance);

        depositValue = balanceAfterZap - initialTokenOutBalance;
    }

    function zapAndDeposit(IERC20 tokenIn, uint256 amount) external payable whenNotPaused returns (bytes32 depositId) {
        require(address(tokenIn) != address(0), "Invalid token");
        require(amount != 0, "Invalid amount");

        uint256 depositValue = _processDeposit(tokenIn, amount);
        depositId = _recordDeposit(depositValue);

        emit ZapAndDeposit(router(), address(tokenIn), depositValue);
    }

    function _processDeposit(IERC20 tokenIn, uint256 amount) internal returns (uint256 depositValue) {
        if (tokenIn == _usdc) {
            tokenIn.safeTransferFrom(_msgSender(), address(_silo), amount);
            depositValue = amount;
        } else {
            depositValue = _zapIn(tokenIn, amount);
        }
    }

    function withdrawDeposit(bytes32 depositId) external whenNotPaused {
        Deposit storage deposit = _approvedDeposits[depositId];

        require(deposit.user == _msgSender(), "Invalid user");
        require(deposit.user != address(0), "Deposit not found");
        require(!deposit.approved, "Deposit already approved");

        uint256 refundAmount = deposit.amount;
        delete _approvedDeposits[depositId];
        _removePendingDeposit(depositId);

        // Return USDC to user
        require(_usdc.balanceOf(address(this)) >= refundAmount, "Insufficient USDC balance");
        _usdc.safeTransfer(_msgSender(), refundAmount);

        emit DepositWithdrawn(depositId, _msgSender(), refundAmount);
    }

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

    function approveDepositsProportionally(
        uint256 targetTotalAmount
    ) external whenNotPaused whenEpochActive onlyRole(VAULT_CURATOR_ROLE) {
        require(targetTotalAmount > 0, "Target amount must be greater than 0");
        require(_pendingDepositIds.length > 0, "No pending deposits");

        // Calculate total pending deposits
        uint256 totalPendingAmount = 0;
        uint256 validDeposits = 0;

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

        // Approve deposits proportionally
        for (uint256 i = 0; i < _pendingDepositIds.length; i++) {
            bytes32 depositId = _pendingDepositIds[i];
            Deposit storage deposit = _approvedDeposits[depositId];

            if (deposit.user != address(0) && !deposit.approved) {
                uint256 approvedAmount = (deposit.amount * proportion) / 1e18;
                if (approvedAmount > 0) {
                    deposit.approved = true;
                    deposit.approvedAmount = approvedAmount;
                    emit DepositApproved(depositId, approvedAmount);
                }
            }
        }

        emit ProportionalApproval(targetTotalAmount, totalPendingAmount, proportion);
    }

    function claimDeposit(bytes32 depositId) external whenNotPaused whenEpochActive returns (uint256 shares) {
        Deposit storage deposit = _approvedDeposits[depositId];
        uint256 currentCopperPrice = getCopperPrice();

        require(deposit.user == _msgSender(), "Invalid user");
        require(deposit.approved, "Deposit not approved");
        require(currentCopperPrice > 0, "Copper price is 0");
        require(deposit.approvedAmount > 0, "No approved amount");

        uint256 approvedAmount = deposit.approvedAmount;
        uint256 totalAmount = deposit.amount;

        // Calculate refund for unapproved portion
        uint256 refundAmount = totalAmount - approvedAmount;

        delete _approvedDeposits[depositId];

        // Convert approved USDC amount to CUP value using copper price
        uint256 cupValue = approvedAmount * currentCopperPrice;

        require(_cup.balanceOf(address(this)) >= cupValue, "Insufficient CUP balance");

        // Deposit CUP to vault and get xCUP shares
        _cup.approve(address(_vault), cupValue);
        shares = _vault.deposit(cupValue, _msgSender());

        // Refund unapproved portion to user
        if (refundAmount > 0) {
            require(_usdc.balanceOf(address(this)) >= refundAmount, "Insufficient USDC balance for refund");
            _usdc.safeTransfer(_msgSender(), refundAmount);
        }

        emit DepositClaimed(depositId, _msgSender(), shares);
    }

    function withdraw() external onlyOwner {
        require(_usdc.balanceOf(address(this)) > 0, "Insufficient USDC balance");

        uint256 balance = _usdc.balanceOf(address(this));

        _usdc.safeTransfer(owner(), balance);

        emit Withdraw(owner(), balance);
    }

    function redeem() external returns (uint256 usdcToWithdraw) {
        uint256 ownedShares = _vault.balanceOf(_msgSender());

        IERC20(address(_vault)).safeTransferFrom(_msgSender(), address(this), ownedShares);

        _vault.approve(address(_vault), ownedShares);

        uint256 withdrawnCup = _vault.redeem(ownedShares, address(this), address(this));

        uint256 copperPrice = getCopperPrice();

        require(copperPrice > 0, "Copper price is 0");

        usdcToWithdraw = withdrawnCup / copperPrice;

        require(_usdc.balanceOf(address(this)) >= usdcToWithdraw, "Insufficient USDC balance");

        _usdc.safeTransfer(_msgSender(), usdcToWithdraw);

        emit Withdraw(_msgSender(), usdcToWithdraw);
    }

    function getCopperPrice() public view returns (uint256 price) {
        price = _copperPriceConsumer.price() / 10 ** 8;
    }

    /**
     * @dev The `pause` function is used to pause the `VaultZapper` contract.
     */
    function pause() external onlyOwner {
        _pause();
    }

    /**
     * @dev The `unpause` function is used to unpause the `VaultZapper`
     * contract.
     */
    function unpause() external onlyOwner {
        _unpause();
    }

    function router() public view returns (address) {
        return address(_router);
    }

    function usdc() public view returns (address) {
        return address(_usdc);
    }

    function silo() public view returns (address) {
        return address(_silo);
    }

    // View functions for deposit management
    function getDeposit(bytes32 depositId) external view returns (Deposit memory) {
        return _approvedDeposits[depositId];
    }

    function getPendingDepositsCount() external view returns (uint256) {
        return _pendingDepositIds.length;
    }

    function getPendingDepositIds() external view returns (bytes32[] memory) {
        return _pendingDepositIds;
    }

    // ?????????
    function getTotalPendingAmount() external view returns (uint256 totalAmount) {
        for (uint256 i = 0; i < _pendingDepositIds.length; i++) {
            Deposit storage deposit = _approvedDeposits[_pendingDepositIds[i]];
            if (deposit.user != address(0) && !deposit.approved) {
                totalAmount += deposit.amount;
            }
        }
    }
}
