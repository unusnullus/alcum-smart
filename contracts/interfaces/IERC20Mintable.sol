// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/**
 * @title IERC20Mintable
 * @dev Interface for ERC20 tokens with minting capability
 */
interface IERC20Mintable is IERC20 {
    /**
     * @dev Mints `amount` tokens to `to` address
     * @param to The address to mint tokens to
     * @param amount The amount of tokens to mint
     */
    function mint(address to, uint256 amount) external;

    /**
     * @dev Burns `amount` tokens from the caller
     * @param amount The amount of tokens to burn
     */
    function burn(uint256 amount) external;

    /**
     * @dev Burns `amount` tokens from `account`
     * @param account The account to burn tokens from
     * @param amount The amount of tokens to burn
     */
    function burnFrom(address account, uint256 amount) external;
}
