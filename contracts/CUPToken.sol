// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";

import {ERC20Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";

contract CUPToken is Initializable, ERC20Upgradeable, AccessControlUpgradeable, OwnableUpgradeable {
    bytes32 public constant MINTER_ROLE = keccak256("MINTER_ROLE");
    bytes32 public constant BURNER_ROLE = keccak256("BURNER_ROLE");

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /**
     * @notice Initializes the CUPToken contract
     * @dev This function replaces the constructor for upgradeable contracts
     */
    function initialize() public initializer {
        __ERC20_init("CUP", "CUP");
        __AccessControl_init();
        __Ownable_init(_msgSender());

        _grantRole(DEFAULT_ADMIN_ROLE, _msgSender());
    }

    function mint(address account, uint256 value) external onlyRole(MINTER_ROLE) {
        _mint(account, value);
    }

    function burn(address from, uint256 value) external onlyRole(BURNER_ROLE) {
        _burn(from, value);
    }

    function decimals() public view override returns (uint8) {
        return 6;
    }

    // Reserve storage gap for future upgrades (to avoid storage collisions)
    uint256[50] private __gap;
}
