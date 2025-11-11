// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IUniswapV2Router02} from "@uniswap/v2-periphery/contracts/interfaces/IUniswapV2Router02.sol";

/**
 * @title SwapLib
 * @notice External library for handling token swaps via Uniswap V2 in Zapper.
 * @dev Keeps Zapper bytecode small by moving swap logic here.
 *      Handles token-to-USDC conversion with slippage protection.
 */
library SwapLib {
    using SafeERC20 for IERC20;

    // ───────────────────────────── ERRORS ─────────────────────────────

    error InvalidETHAmount();

    // ───────────────────────────── SWAP OPERATIONS ─────────────────────────────

    /**
     * @notice Swaps input tokens for USDC using Uniswap V2 with slippage protection
     * @param tokenIn The token to swap from (address(0) for ETH)
     * @param amount The amount of tokens to swap (in token's native decimals)
     * @param slippageBps The slippage tolerance in basis points (100 = 1%, 1000 = 10%)
     * @param router The Uniswap V2 router contract
     * @param usdc The USDC token contract
     * @param silo The Silo contract that receives USDC
     * @param zapperContract The Zapper contract address (for receiving tokens)
     * @param msgSender The address sending the transaction
     * @param msgValue The ETH value sent with the transaction
     * @return depositValue The net amount of USDC received from the swap (6 decimals)
     */
    function zapIn(
        IERC20 tokenIn,
        uint256 amount,
        uint256 slippageBps,
        IUniswapV2Router02 router,
        IERC20 usdc,
        address silo,
        address zapperContract,
        address msgSender,
        uint256 msgValue
    ) external returns (uint256 depositValue) {
        uint256 initialTokenOutBalance = usdc.balanceOf(silo);

        // Handle token transfer based on input type (ERC20 vs ETH)
        if (address(tokenIn) != address(0)) {
            // ERC20 token: Transfer from user to zapper contract for swap
            tokenIn.safeTransferFrom(msgSender, zapperContract, amount);
        }

        // Handle router approval based on input type
        if (address(tokenIn) != address(0)) {
            // ERC20 token: Approve Uniswap router to spend tokens
            // Use forceApprove to handle tokens with non-standard approval behavior
            IERC20(address(tokenIn)).forceApprove(address(router), amount);
        } else {
            // ETH case: Validate that msg.value matches the specified amount
            if (msgValue != amount) {
                revert InvalidETHAmount();
            }
        }

        tradeForToken(address(tokenIn), address(usdc), amount, slippageBps, router, silo, zapperContract, msgValue);

        uint256 balanceAfterZap = usdc.balanceOf(silo);

        depositValue = balanceAfterZap - initialTokenOutBalance;
    }

    /**
     * @notice Executes a token swap on Uniswap V2 with automatic path routing
     * @param tokenIn The address of the input token (address(0) for ETH)
     * @param tokenOut The address of the output token (typically USDC)
     * @param amountIn The amount of input tokens to swap
     * @param slippageBps The slippage tolerance in basis points (100 = 1%)
     * @param router The Uniswap V2 router contract
     * @param silo The Silo contract that receives the output tokens
     * @param zapperContract The Zapper contract address (for approving tokens)
     * @param msgValue The ETH value sent with the transaction
     */
    function tradeForToken(
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 slippageBps,
        IUniswapV2Router02 router,
        address silo,
        address zapperContract,
        uint256 msgValue
    ) public {
        // Construct trading path for Uniswap V2 (direct pair assumed)
        address[] memory path = new address[](2);

        // Handle ETH representation in trading path
        if (tokenIn == address(0)) {
            // ETH case: Use WETH address for Uniswap routing
            path[0] = router.WETH();
        } else {
            // ERC20 token case: Use token address directly
            path[0] = tokenIn;
        }
        path[1] = tokenOut;

        // Query expected output amounts from Uniswap router
        uint256[] memory amountsOut = router.getAmountsOut(amountIn, path);

        // Calculate minimum output with custom slippage tolerance
        // Formula: minOutput = amountsOut[1] * (10000 - slippageBps) / 10000
        // To prevent overflow with very large values, use unchecked arithmetic
        // since we're dividing by 10000 which ensures the result fits in uint256
        uint256 minOutput;
        unchecked {
            minOutput = (amountsOut[1] * (10000 - slippageBps)) / 10000;
        }

        // Handle ETH swaps specially (require ETH to be sent with transaction)
        if (tokenIn == address(0) || tokenIn == router.WETH()) {
            // send ETH along with slippage protection
            router.swapExactETHForTokens{value: msgValue}(minOutput, path, silo, block.timestamp);
            return;
        }

        router.swapExactTokensForTokens(amountIn, minOutput, path, silo, block.timestamp);
    }
}
