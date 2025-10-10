// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {ERC20Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";

/**
 * @title CUPToken
 * @notice The CUP token represents refined copper assets in the Alcum ecosystem
 * @dev An upgradeable ERC20 token with role-based minting and burning capabilities.
 *      This token is used to represent copper inventory and trading positions within
 *      the protocol. It uses 6 decimal places to align with USDC precision.
 */
contract CUPToken is Initializable, ERC20Upgradeable, AccessControlUpgradeable, OwnableUpgradeable {
    /// @notice Role identifier for addresses authorized to mint tokens
    /// @dev Typically granted to the SettlementEngine contract for revenue distribution
    bytes32 public constant MINTER_ROLE = keccak256("MINTER_ROLE");

    /// @notice Role identifier for addresses authorized to burn tokens
    /// @dev Used for token destruction during redemption or settlement processes
    bytes32 public constant BURNER_ROLE = keccak256("BURNER_ROLE");

    /// @notice Thrown when attempting to mint to the zero address
    error MintToZeroAddress();

    /// @notice Thrown when attempting to mint zero amount
    error InvalidMintAmount();

    /// @notice Thrown when attempting to burn from the zero address
    error BurnFromZeroAddress();

    /// @notice Thrown when attempting to burn zero amount
    error InvalidBurnAmount();

    /// @notice Thrown when attempting to burn more tokens than available
    error InsufficientBalance();

    /**
     * @notice Emitted when tokens are minted to an account
     * @param to The address receiving the minted tokens
     * @param amount The amount of tokens minted
     * @param minter The address that performed the minting operation
     */
    event TokensMinted(address indexed to, uint256 amount, address indexed minter);

    /**
     * @notice Emitted when tokens are burned from an account
     * @param from The address from which tokens were burned
     * @param amount The amount of tokens burned
     * @param burner The address that performed the burning operation
     */
    event TokensBurned(address indexed from, uint256 amount, address indexed burner);

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /**
     * @notice Initializes the CUPToken contract
     * @dev This function replaces the constructor for upgradeable contracts.
     *      Sets up the token with name "CUP", symbol "CUP", and grants admin role to deployer.
     *
     * Requirements:
     * - Can only be called once due to initializer modifier
     * - Caller becomes the owner and admin of the contract
     *
     * @custom:oz-initializer
     */
    function initialize() public initializer {
        __ERC20_init("CUP", "CUP");
        __AccessControl_init();
        __Ownable_init(_msgSender());

        _grantRole(DEFAULT_ADMIN_ROLE, _msgSender());
    }

    /**
     * @notice Mints new tokens to a specified account
     * @dev Only addresses with MINTER_ROLE can call this function.
     *      Typically used by the SettlementEngine to distribute revenue.
     *
     * Requirements:
     * - Caller must have MINTER_ROLE
     * - `account` cannot be the zero address
     * - `value` must be greater than 0
     *
     * @param account The address to receive the minted tokens
     * @param value The amount of tokens to mint (in 6 decimal precision)
     *
     * Emits a {TokensMinted} event.
     * Emits a {Transfer} event with `from` set to the zero address.
     */
    function mint(address account, uint256 value) external onlyRole(MINTER_ROLE) {
        if (account == address(0)) revert MintToZeroAddress();
        if (value == 0) revert InvalidMintAmount();

        _mint(account, value);
        emit TokensMinted(account, value, _msgSender());
    }

    /**
     * @notice Burns tokens from a specified account
     * @dev Only addresses with BURNER_ROLE can call this function.
     *      Used for token destruction during redemption processes.
     *
     * Requirements:
     * - Caller must have BURNER_ROLE
     * - `from` cannot be the zero address
     * - `from` must have at least `value` tokens
     * - `value` must be greater than 0
     *
     * @param from The address from which to burn tokens
     * @param value The amount of tokens to burn (in 6 decimal precision)
     *
     * Emits a {TokensBurned} event.
     * Emits a {Transfer} event with `to` set to the zero address.
     */
    function burn(address from, uint256 value) external onlyRole(BURNER_ROLE) {
        if (from == address(0)) revert BurnFromZeroAddress();
        if (value == 0) revert InvalidBurnAmount();
        if (balanceOf(from) < value) revert InsufficientBalance();

        _burn(from, value);
        emit TokensBurned(from, value, _msgSender());
    }

    /**
     * @notice Returns the number of decimal places used by the token
     * @dev CUP token uses 6 decimal places to align with USDC precision
     *      for easier price calculations and conversions.
     *
     * @return The number of decimal places (6)
     */
    function decimals() public view override returns (uint8) {
        return 6;
    }

    // Reserve storage gap for future upgrades (to avoid storage collisions)
    uint256[50] private __gap;
}
