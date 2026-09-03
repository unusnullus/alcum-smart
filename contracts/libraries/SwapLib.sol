// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IUniswapV2Router02} from "@uniswap/v2-periphery/contracts/interfaces/IUniswapV2Router02.sol";

/**
 * @title SwapLib
 * @notice Uniswap V2 helper used by OpenLiquidityRouter to convert an input asset into
 *         the vault settlement token.
 *
 * @dev Prefer caller-supplied `minAmountOut` (FIND-022). When zero, falls back to
 *      spot `getAmountsOut × (1 − slippageBps)` in the same tx.
 *
 *      Fee-on-transfer `tokenIn` is supported by swapping the measured balance received
 *      after `transferFrom` (FIND-007), not the caller-declared `amount`.
 *
 *      Native ETH is `tokenIn == address(0)`. WETH uses `swapExactTokensForTokens`.
 */
library SwapLib {
    using SafeERC20 for IERC20;

    uint256 internal constant BPS_DENOMINATOR = 10_000;

    error InvalidETHAmount();
    error InvalidSlippage();
    error UnexpectedETH();
    error NoLiquidPath();
    error InsufficientAmountOut(uint256 actual, uint256 minimum);
    error ZeroAmountIn();

    function zapIn(
        IERC20 tokenIn,
        uint256 amount,
        uint256 slippageBps,
        uint256 minAmountOut,
        IUniswapV2Router02 router,
        IERC20 settlementToken,
        address recipient,
        address routerCaller,
        address msgSender,
        uint256 msgValue,
        address swapIntermediary
    ) external returns (uint256 depositValue) {
        if (slippageBps > BPS_DENOMINATOR) revert InvalidSlippage();

        uint256 amountIn = _pullInput(tokenIn, amount, routerCaller, msgSender, msgValue, address(router));

        uint256 initialTokenOutBalance = settlementToken.balanceOf(recipient);

        tradeForToken(
            address(tokenIn),
            address(settlementToken),
            amountIn,
            slippageBps,
            minAmountOut,
            router,
            recipient,
            msgValue,
            swapIntermediary
        );

        depositValue = settlementToken.balanceOf(recipient) - initialTokenOutBalance;
        if (minAmountOut > 0 && depositValue < minAmountOut) {
            revert InsufficientAmountOut(depositValue, minAmountOut);
        }
    }

    /// @dev FIND-007: for ERC-20, swap the measured post-transfer balance (FoT-safe).
    function _pullInput(
        IERC20 tokenIn,
        uint256 amount,
        address routerCaller,
        address msgSender,
        uint256 msgValue,
        address uniRouter
    ) private returns (uint256 amountIn) {
        if (address(tokenIn) != address(0)) {
            if (msgValue != 0) revert UnexpectedETH();
            uint256 balBefore = tokenIn.balanceOf(routerCaller);
            tokenIn.safeTransferFrom(msgSender, routerCaller, amount);
            amountIn = tokenIn.balanceOf(routerCaller) - balBefore;
            if (amountIn == 0) revert ZeroAmountIn();
            tokenIn.forceApprove(uniRouter, amountIn);
        } else if (msgValue != amount) {
            revert InvalidETHAmount();
        } else {
            amountIn = amount;
        }
    }

    function tradeForToken(
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 slippageBps,
        uint256 minAmountOut,
        IUniswapV2Router02 router,
        address recipient,
        uint256 msgValue,
        address swapIntermediary
    ) public {
        if (slippageBps > BPS_DENOMINATOR) revert InvalidSlippage();

        address inputToken = tokenIn == address(0) ? router.WETH() : tokenIn;
        (uint256 quotedOut, address[] memory path) =
            _quotePath(router, inputToken, tokenOut, amountIn, swapIntermediary);

        // FIND-022: explicit minOut from UI wins; else spot × slippage floor.
        uint256 minOutput = minAmountOut;
        if (minOutput == 0) {
            minOutput = (quotedOut * (BPS_DENOMINATOR - slippageBps)) / BPS_DENOMINATOR;
        }

        if (tokenIn == address(0)) {
            router.swapExactETHForTokens{value: msgValue}(minOutput, path, recipient, block.timestamp);
            return;
        }

        router.swapExactTokensForTokens(amountIn, minOutput, path, recipient, block.timestamp);
    }

    function _quotePath(
        IUniswapV2Router02 router,
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        address swapIntermediary
    ) internal view returns (uint256 amountOut, address[] memory path) {
        path = new address[](2);
        path[0] = tokenIn;
        path[1] = tokenOut;

        try router.getAmountsOut(amountIn, path) returns (uint256[] memory amounts) {
            return (amounts[1], path);
        } catch {
            if (
                swapIntermediary == address(0) ||
                swapIntermediary == tokenIn ||
                swapIntermediary == tokenOut
            ) revert NoLiquidPath();

            path = new address[](3);
            path[0] = tokenIn;
            path[1] = swapIntermediary;
            path[2] = tokenOut;

            uint256[] memory amounts = router.getAmountsOut(amountIn, path);
            return (amounts[2], path);
        }
    }
}
