// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/**
 * @title IERC20Mintable
 * @notice Interface for ERC20 tokens with minting and burning capabilities
 * @dev Extends the standard ERC20 interface with mint and burn functions.
 *      Used by tokens that need controlled supply management through
 *      role-based access control.
 */
interface IERC20Mintable is IERC20 {
    /**
     * @notice Mints new tokens to a specified address
     * @dev Creates new tokens and assigns them to the specified address.
     *      Typically restricted to authorized minter roles.
     *
     * Requirements:
     * - Caller must have minting permissions
     * - `to` cannot be the zero address
     * - `amount` must be greater than 0
     *
     * @param to The address to receive the newly minted tokens
     * @param amount The amount of tokens to mint
     *
     * Emits a {Transfer} event with `from` set to the zero address.
     */
    function mint(address to, uint256 amount) external;

    /**
     * @notice Burns tokens from the caller's balance
     * @dev Destroys tokens from the caller's account, reducing the total supply.
     *      The caller must have sufficient balance to burn.
     *
     * Requirements:
     * - Caller must have at least `amount` tokens
     * - `amount` must be greater than 0
     *
     * @param amount The amount of tokens to burn from caller's balance
     *
     * Emits a {Transfer} event with `to` set to the zero address.
     */
    function burn(uint256 amount) external;

    /**
     * @notice Burns tokens from a specified account
     * @dev Destroys tokens from the specified account, reducing the total supply.
     *      Typically restricted to authorized burner roles or requires allowance.
     *
     * Requirements:
     * - Caller must have burning permissions or sufficient allowance
     * - `account` must have at least `amount` tokens
     * - `amount` must be greater than 0
     *
     * @param account The account to burn tokens from
     * @param amount The amount of tokens to burn
     *
     * Emits a {Transfer} event with `to` set to the zero address.
     */
    function burnFrom(address account, uint256 amount) external;
}
