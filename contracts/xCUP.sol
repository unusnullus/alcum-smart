// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";

import {IERC20} from "@openzeppelin/contracts/interfaces/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/interfaces/IERC20Metadata.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ERC20Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";

import {ERC4626Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC4626Upgradeable.sol";

/**
 * @title xCUP
 * @dev An ERC4626 vault that wraps CUP tokens with controlled redemption access.
 * This vault is designed to work with the Zapper contract, where users deposit
 * various tokens (USDC, ETH, etc.) via the Zapper, which converts them to CUP
 * tokens and deposits them into this vault on behalf of users.
 * 
 * Users receive xCUP shares representing their share of the vault's CUP holdings,
 * but only authorized contracts (like the Zapper) can redeem shares on behalf of users.
 */
contract xCUP is Initializable, ERC4626Upgradeable, OwnableUpgradeable, PausableUpgradeable, AccessControlUpgradeable {
    using SafeERC20 for IERC20;

    /// @dev Role identifier for contracts that can redeem user shares (e.g., Zapper)
    bytes32 public constant REDEEMER_ROLE = keccak256("REDEEMER_ROLE");

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /**
     * @dev Initializes the xCUP vault with the underlying asset and metadata
     * @param underlying_ The underlying asset (CUP token)
     * @param name_ The name of the vault token
     * @param symbol_ The symbol of the vault token
     */
    function initialize(IERC20 underlying_, string memory name_, string memory symbol_) public initializer {
        require(address(underlying_) != address(0), "Invalid underlying asset");

        __ERC20_init(name_, symbol_);
        __ERC4626_init(underlying_);
        __AccessControl_init();
        __Ownable_init(_msgSender());
        __Pausable_init();

        _grantRole(DEFAULT_ADMIN_ROLE, _msgSender());
    }

    /** @dev See {IERC4626-withdraw}.
     * @custom:revert if caller is not the redeemer.
     */
    function withdraw(
        uint256 assets,
        address receiver,
        address owner
    ) public override onlyRole(REDEEMER_ROLE) returns (uint256) {
        return super.withdraw(assets, receiver, owner);
    }

    /** @dev See {IERC4626-redeem}.
     * @custom:revert if caller is not the redeemer.
     */
    function redeem(
        uint256 shares,
        address receiver,
        address owner
    ) public override onlyRole(REDEEMER_ROLE) returns (uint256) {
        return super.redeem(shares, receiver, owner);
    }

    /**
     * @dev Pauses the vault, preventing deposits and withdrawals
     */
    function pause() public onlyOwner {
        _pause();
    }

    /**
     * @dev Unpauses the vault, allowing deposits and withdrawals
     */
    function unpause() public onlyOwner {
        _unpause();
    }

    /**
     * @dev Returns the number of decimals for the vault token
     * @return The number of decimals
     */
    function decimals() public view override returns (uint8) {
        return 6;
    }
}
