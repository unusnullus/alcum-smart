// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC20} from "@openzeppelin/contracts/interfaces/IERC20.sol";

/**
 * @title Silo
 * @notice A simple contract that holds USDC tokens and provides unlimited approval to the Zapper contract
 * @dev This contract acts as a temporary vault for USDC tokens during the zapping process.
 *      It automatically approves the Zapper contract to spend its USDC balance, enabling
 *      seamless token operations without requiring separate approval transactions.
 */

contract Silo {
    using SafeERC20 for IERC20;

    /**
     * @notice Initializes the Silo with unlimited approval for the Zapper
     * @dev Grants unlimited spending approval to the deploying Zapper contract.
     *      This eliminates the need for separate approval transactions during zapping.
     *
     * @param token The USDC token contract to approve spending for
     */
    constructor(IERC20 token) {
        token.forceApprove(msg.sender, type(uint256).max);
    }
}
