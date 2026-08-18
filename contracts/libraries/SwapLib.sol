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
 * @dev Spot quotes come from `getAmountsOut` in the same transaction as the swap.
 *      Callers must enforce a tight `slippageBps` (router maximum 1_000 bps).
 *
 *      Tries a direct 2-hop path first, then an optional 3-hop path via `swapIntermediary`
 *      (should match the RWAVault configuration for consistent quoting).
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

    function zapIn(
        IERC20 tokenIn,
        uint256 amount,
        uint256 slippageBps,
        IUniswapV2Router02 router,
        IERC20 settlementToken,
        address recipient,
        address routerCaller,
        address msgSender,
        uint256 msgValue,
        address swapIntermediary
    ) external returns (uint256 depositValue) {
        if (slippageBps > BPS_DENOMINATOR) revert InvalidSlippage();

        if (address(tokenIn) != address(0)) {
            if (msgValue != 0) revert UnexpectedETH();
            tokenIn.safeTransferFrom(msgSender, routerCaller, amount);
            tokenIn.forceApprove(address(router), amount);
        } else if (msgValue != amount) {
            revert InvalidETHAmount();
        }

        uint256 initialTokenOutBalance = settlementToken.balanceOf(recipient);

        tradeForToken(
            address(tokenIn),
            address(settlementToken),
            amount,
            slippageBps,
            router,
            recipient,
            msgValue,
            swapIntermediary
        );

        depositValue = settlementToken.balanceOf(recipient) - initialTokenOutBalance;
    }

    function tradeForToken(
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 slippageBps,
        IUniswapV2Router02 router,
        address recipient,
        uint256 msgValue,
        address swapIntermediary
    ) public {
        if (slippageBps > BPS_DENOMINATOR) revert InvalidSlippage();

        address inputToken = tokenIn == address(0) ? router.WETH() : tokenIn;
        (uint256 quotedOut, address[] memory path) =
            _quotePath(router, inputToken, tokenOut, amountIn, swapIntermediary);
        uint256 minOutput = (quotedOut * (BPS_DENOMINATOR - slippageBps)) / BPS_DENOMINATOR;

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
