// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC20Votes} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Votes.sol";
import {ERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";
import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {Nonces} from "@openzeppelin/contracts/utils/Nonces.sol";

/**
 * @title GovernanceToken
 * @notice ERC20 token with voting capabilities for DAO governance
 * @dev This token implements ERC20Votes for snapshot-based voting and ERC20Permit for gasless approvals.
 *      The token can be minted by addresses with MINTER_ROLE and is used for governance proposals and voting.
 */
contract GovernanceToken is ERC20, ERC20Permit, ERC20Votes, AccessControl {
    /// @notice Role identifier for minters
    bytes32 public constant MINTER_ROLE = keccak256("MINTER_ROLE");
    /// @notice Thrown when attempting to mint to the zero address
    error MintToZeroAddress();

    /// @notice Thrown when attempting to mint zero amount
    error InvalidMintAmount();

    /**
     * @notice Emitted when tokens are minted
     * @param to The address receiving the minted tokens
     * @param amount The amount of tokens minted
     */
    event TokensMinted(address indexed to, uint256 amount);

    /**
     * @notice Initializes the GovernanceToken contract
     * @param name The name of the token
     * @param symbol The symbol of the token
     * @param initialAdmin The address that will have DEFAULT_ADMIN_ROLE and MINTER_ROLE
     */
    constructor(string memory name, string memory symbol, address initialAdmin) ERC20(name, symbol) ERC20Permit(name) {
        _grantRole(DEFAULT_ADMIN_ROLE, initialAdmin);
        _grantRole(MINTER_ROLE, initialAdmin);
    }

    /**
     * @notice Mints new tokens to a specified account
     * @dev Only addresses with MINTER_ROLE can call this function.
     *
     * Requirements:
     * - Caller must have MINTER_ROLE
     * - `to` cannot be the zero address
     * - `amount` must be greater than 0
     *
     * @param to The address to receive the minted tokens
     * @param amount The amount of tokens to mint
     *
     * Emits a {TokensMinted} event.
     */
    function mint(address to, uint256 amount) external onlyRole(MINTER_ROLE) {
        if (to == address(0)) revert MintToZeroAddress();
        if (amount == 0) revert InvalidMintAmount();

        _mint(to, amount);
        emit TokensMinted(to, amount);
    }

    /**
     * @notice Hook that is called after any token transfer
     * @dev Overrides required by Solidity to properly update voting snapshots
     * @param from The address tokens are transferred from
     * @param to The address tokens are transferred to
     * @param value The amount of tokens transferred
     */
    function _update(address from, address to, uint256 value) internal override(ERC20, ERC20Votes) {
        super._update(from, to, value);
    }

    /**
     * @notice Returns the number of decimals used by the token
     * @dev Defaults to 18 decimals for standard ERC20 tokens
     * @return The number of decimal places (18)
     */
    function decimals() public pure override returns (uint8) {
        return 18;
    }

    /**
     * @notice Returns the current nonce for an owner
     * @dev Resolves conflict between ERC20Permit and Nonces
     * @param owner The address to query the nonce for
     * @return The current nonce
     */
    function nonces(address owner) public view override(ERC20Permit, Nonces) returns (uint256) {
        return super.nonces(owner);
    }
}
