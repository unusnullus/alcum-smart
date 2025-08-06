// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

contract CUPToken is ERC20, AccessControl, Ownable {
    bytes32 public constant MINTER_ROLE = keccak256("MINTER_ROLE");
    bytes32 public constant BURNER_ROLE = keccak256("BURNER_ROLE");

    constructor() ERC20("CUP", "CUP") Ownable(_msgSender()) {
        _grantRole(DEFAULT_ADMIN_ROLE, _msgSender());

        _mint(_msgSender(), 100000000000e6);
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
}
