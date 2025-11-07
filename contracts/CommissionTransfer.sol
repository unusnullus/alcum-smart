// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {ReentrancyGuardUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {IERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Permit.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IUniswapRouterV2} from "./interfaces/IUniswapRouterV2.sol";
import {IXCUPRatePool} from "./interfaces/IXCUPRatePool.sol";

/**
 * @title Commission Transfer
 *
 * The contract which represents a custom commission transfer mechanism.
 */

contract CommissionTransfer is Initializable, OwnableUpgradeable, ReentrancyGuardUpgradeable {
    using SafeERC20 for IERC20;

    // --- Constants / Multipliers ---
    uint256 private constant PERCENTAGE_MULTIPLIER = 1000; // commissionPercentage is in 1/1000 units (20 => 2.0%)
    uint256 private constant SLIPPAGE_MULTIPLIER = 10000; // slippageTolerance is in 1/10000 units (50 => 0.5%)
    uint256 public constant MAX_COMMISSION_PERCENTAGE = 1000; // 100% max (expressed in same units as commissionPercentage)

    // --- State ---
    address private commissionReceiver;
    uint256 private commissionPercentage;

    // Swap related variables
    IUniswapRouterV2 public uniswapRouter;
    IERC20 public usdt;
    IERC20 public xcup;
    IERC20 public usdc;
    uint256 public slippageTolerance;
    IXCUPRatePool public xcupPool;

    // --- Events ---
    event CommissionReceiverChanged(address indexed previousReceiver, address indexed newReceiver);
    event CommissionPercentageChanged(uint256 previousPercentage, uint256 newPercentage);
    event TransferWithCommission(
        address indexed token,
        address indexed to,
        uint256 totalAmount,
        uint256 commissionAmount,
        uint256 transferredAmount
    );
    event EmergencyWithdraw(address indexed token, uint256 amount);
    event EmergencyWithdrawETH(uint256 amount);
    event SwapConfigUpdated(address uniswapRouter, address usdt, address xcup, address usdc);
    event XCUPPoolUpdated(address indexed pool);
    event SlippageToleranceUpdated(uint256 oldTolerance, uint256 newTolerance);
    event TokenSwapped(address indexed fromToken, address indexed toToken, uint256 amountIn, uint256 amountOut);
    event ETHReceived(address indexed sender, uint256 amount);

    // --- Errors ---
    error InvalidAddress();
    error InvalidAmount();
    error InsufficientAllowance();
    error TransferFailed();
    error NoBalance();
    error UseTransferETHWithCommission();
    error SwapFailed();
    error UnsupportedToken();

    // --- Initializer ---
    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(address initialCommissionReceiver) public initializer {
        if (initialCommissionReceiver == address(0)) revert InvalidAddress();

        __Ownable_init(msg.sender);
        __ReentrancyGuard_init();

        commissionReceiver = initialCommissionReceiver;
        commissionPercentage = 20; // default 2.0%
        slippageTolerance = 50; // default 0.5%
    }

    // --- Admin Functions ---

    function setCommissionReceiver(address newReceiver) external onlyOwner {
        if (newReceiver == address(0)) revert InvalidAddress();
        emit CommissionReceiverChanged(commissionReceiver, newReceiver);
        commissionReceiver = newReceiver;
    }

    function setCommissionPercentage(uint256 newPercentage) external onlyOwner {
        if (newPercentage > MAX_COMMISSION_PERCENTAGE) revert InvalidAmount();
        emit CommissionPercentageChanged(commissionPercentage, newPercentage);
        commissionPercentage = newPercentage;
    }

    function setSwapConfig(address _uniswapRouter, address _usdt, address _xcup, address _usdc) external onlyOwner {
        if (_uniswapRouter == address(0) || _usdt == address(0) || _xcup == address(0) || _usdc == address(0)) {
            revert InvalidAddress();
        }

        uniswapRouter = IUniswapRouterV2(_uniswapRouter);
        usdt = IERC20(_usdt);
        xcup = IERC20(_xcup);
        usdc = IERC20(_usdc);

        emit SwapConfigUpdated(_uniswapRouter, _usdt, _xcup, _usdc);
    }

    function setXCUPPool(address _pool) external onlyOwner {
        if (_pool == address(0)) revert InvalidAddress();
        xcupPool = IXCUPRatePool(_pool);
        emit XCUPPoolUpdated(_pool);
    }

    function setSlippageTolerance(uint256 newTolerance) external onlyOwner {
        if (newTolerance > 1000) revert InvalidAmount(); // Max 10%
        emit SlippageToleranceUpdated(slippageTolerance, newTolerance);
        slippageTolerance = newTolerance;
    }

    // --- ETH Transfer ---

    function transferETHWithCommission(address payable to) external payable nonReentrant {
        if (to == address(0)) revert InvalidAddress();
        if (msg.value == 0) revert InvalidAmount();

        uint256 commissionAmount = (msg.value * commissionPercentage) / PERCENTAGE_MULTIPLIER;
        uint256 transferAmount = msg.value - commissionAmount;

        (bool successCommission, ) = payable(commissionReceiver).call{value: commissionAmount}("");
        if (!successCommission) revert TransferFailed();

        (bool successTransfer, ) = to.call{value: transferAmount}("");
        if (!successTransfer) revert TransferFailed();

        emit TransferWithCommission(address(0), to, msg.value, commissionAmount, transferAmount);
    }

    // --- Private Swap Functions ---

    function _swapUSDTToUSDC(uint256 amount) private returns (uint256) {
        if (address(uniswapRouter) == address(0) || address(usdt) == address(0) || address(usdc) == address(0)) {
            revert UnsupportedToken();
        }

        // Approve USDT to Uniswap router
        usdt.forceApprove(address(uniswapRouter), amount);

        // Build path USDT -> USDC
        address[] memory path = new address[](2);
        path[0] = address(usdt);
        path[1] = address(usdc);

        uint256[] memory amountsOut = uniswapRouter.getAmountsOut(amount, path);
        uint256 expectedOut = amountsOut[1];
        uint256 minOut = (expectedOut * (SLIPPAGE_MULTIPLIER - slippageTolerance)) / SLIPPAGE_MULTIPLIER;

        uint256 balanceBefore = usdc.balanceOf(address(this));

        // Perform swap (supporting fee-on-transfer tokens)
        uniswapRouter.swapExactTokensForTokensSupportingFeeOnTransferTokens(
            amount,
            minOut,
            path,
            address(this),
            block.timestamp + 300 // 5 minutes deadline
        );

        uint256 balanceAfter = usdc.balanceOf(address(this));
        uint256 usdcReceived = balanceAfter - balanceBefore;

        // Must receive at least minOut
        if (usdcReceived < minOut) revert SwapFailed();

        emit TokenSwapped(address(usdt), address(usdc), amount, usdcReceived);
        return usdcReceived;
    }

    function _swapXCUPToUSDC(uint256 amount) private returns (uint256) {
        if (address(xcupPool) == address(0) || address(xcup) == address(0) || address(usdc) == address(0)) {
            revert UnsupportedToken();
        }

        (uint256 rX, uint256 rU) = xcupPool.getReserves();
        if (rX == 0 || rU == 0) revert SwapFailed();

        uint16 feeBps = xcupPool.swapFee();
        uint256 amountInWithFee = (amount * (10000 - feeBps)) / 10000;
        uint256 expectedOut = (amountInWithFee * rU) / (rX + amountInWithFee);
        if (expectedOut == 0) revert SwapFailed();
        uint256 minOut = (expectedOut * (SLIPPAGE_MULTIPLIER - slippageTolerance)) / SLIPPAGE_MULTIPLIER;

        uint256 balanceBefore = usdc.balanceOf(address(this));

        // approve pool to pull xCUP and execute swap
        IERC20(address(xcup)).forceApprove(address(xcupPool), amount);
        xcupPool.swapExactXCUPToUSDC(amount, minOut);

        uint256 balanceAfter = usdc.balanceOf(address(this));
        uint256 usdcReceived = balanceAfter - balanceBefore;
        if (usdcReceived < minOut) revert SwapFailed();

        emit TokenSwapped(address(xcup), address(usdc), amount, usdcReceived);
        return usdcReceived;
    }

    // --- ERC20 Transfer with prior approval ---

    function transferTokenWithCommission(IERC20 token, address to, uint256 amount) public nonReentrant {
        if (to == address(0)) revert InvalidAddress();
        if (amount == 0) revert InvalidAmount();

        // Transfer tokens from sender to this contract
        token.safeTransferFrom(msg.sender, address(this), amount);

        uint256 finalAmount = amount;
        address finalToken = address(token);

        // Check if token needs to be swapped to USDC
        if (address(token) == address(usdt)) {
            // Swap USDT to USDC via Uniswap
            finalAmount = _swapUSDTToUSDC(amount);
            finalToken = address(usdc);
        } else if (address(token) == address(xcup)) {
            // Swap xCUP to USDC via internal pool
            finalAmount = _swapXCUPToUSDC(amount);
            finalToken = address(usdc);
        }

        // Calculate commission on final amount
        uint256 commissionAmount = (finalAmount * commissionPercentage) / PERCENTAGE_MULTIPLIER;
        uint256 transferAmount = finalAmount - commissionAmount;

        // Safety: if commission is more than final amount (shouldn't happen due to checks), cap it
        if (commissionAmount > finalAmount) commissionAmount = finalAmount;

        // Transfer commission and final amount
        if (finalToken == address(usdc)) {
            usdc.safeTransfer(commissionReceiver, commissionAmount);
            usdc.safeTransfer(to, transferAmount);
        } else {
            // For other tokens (direct transfers without swap)
            token.safeTransfer(commissionReceiver, commissionAmount);
            token.safeTransfer(to, transferAmount);
        }

        emit TransferWithCommission(finalToken, to, finalAmount, commissionAmount, transferAmount);
    }

    // --- ERC20 Transfer with Permit (EIP-2612) ---

    function transferTokenWithCommissionWithPermit(
        IERC20Permit token,
        address to,
        uint256 amount,
        uint256 deadline,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) external {
        // Permit (gasless approval)
        token.permit(msg.sender, address(this), amount, deadline, v, r, s);

        // Proceed with standard transfer
        transferTokenWithCommission(IERC20(address(token)), to, amount);
    }

    // --- View Functions ---

    function getCommissionReceiver() external view returns (address) {
        return commissionReceiver;
    }

    function getCommissionPercentage() external view returns (uint256) {
        return commissionPercentage;
    }

    function getSwapConfig()
        external
        view
        returns (address _uniswapRouter, address _usdt, address _xcup, address _usdc)
    {
        return (address(uniswapRouter), address(usdt), address(xcup), address(usdc));
    }

    function getSlippageTolerance() external view returns (uint256) {
        return slippageTolerance;
    }

    function isSwapSupportedToken(address token) external view returns (bool) {
        return token == address(usdt) || token == address(xcup);
    }

    // --- Emergency Withdrawals ---

    function emergencyWithdraw(IERC20 token) external onlyOwner nonReentrant {
        uint256 balance = token.balanceOf(address(this));
        if (balance == 0) revert NoBalance();

        token.safeTransfer(owner(), balance);
        emit EmergencyWithdraw(address(token), balance);
    }

    function emergencyWithdrawETH() external onlyOwner nonReentrant {
        uint256 balance = address(this).balance;
        if (balance == 0) revert NoBalance();

        (bool success, ) = owner().call{value: balance}("");
        if (!success) revert TransferFailed();
        emit EmergencyWithdrawETH(balance);
    }

    receive() external payable {
        revert UseTransferETHWithCommission();
    }

    // --- Storage Gap ---
    /**
     * @dev This empty reserved space is put in place to allow future versions to add new
     * variables without shifting down storage in the inheritance chain.
     * See https://docs.openzeppelin.com/contracts/4.x/upgradeable#storage_gaps
     */
    uint256[50] private __gap;
}
