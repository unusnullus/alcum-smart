// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";

import {Zapper} from "./Zapper.sol";

/**
 * @title HostAdapter
 * @dev Isolated adapter for host-to-host integrations. This contract forwards
 *      external deposit operations to Zapper while keeping integration roles separate.
 *      Note: Grant Zapper's HOST_INTEGRATION_ROLE to this adapter instance.
 */
contract HostAdapter is Initializable, OwnableUpgradeable, AccessControlUpgradeable {
    /// @dev Role for backend operators to register/update external deposits
    bytes32 public constant HOST_OPERATOR_ROLE = keccak256("HOST_OPERATOR_ROLE");
    /// @dev Role for curator operators to approve external deposits with price snapshot
    bytes32 public constant CURATOR_OPERATOR_ROLE = keccak256("CURATOR_OPERATOR_ROLE");

    Zapper private _zapper;

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(address zapper_) public initializer {
        require(zapper_ != address(0), "Invalid zapper");

        __Ownable_init(_msgSender());
        __AccessControl_init();

        _zapper = Zapper(zapper_);

        _grantRole(DEFAULT_ADMIN_ROLE, _msgSender());
        _grantRole(HOST_OPERATOR_ROLE, _msgSender());
        _grantRole(CURATOR_OPERATOR_ROLE, _msgSender());
    }

    function zapper() external view returns (address) {
        return address(_zapper);
    }

    /**
     * @dev Forward: register an external deposit (no token movement) for a beneficiary.
     * Requires this adapter to have Zapper.HOST_INTEGRATION_ROLE.
     */
    function registerExternalDepositFor(address beneficiary, uint256 usdcAmount, bytes32 tag)
        external
        onlyRole(HOST_OPERATOR_ROLE)
        returns (bytes32 depositId)
    {
        depositId = _zapper.registerExternalDepositFor(beneficiary, usdcAmount, tag);
    }

    /**
     * @dev Forward: update beneficiary before approval.
     */
    function setDepositBeneficiary(bytes32 depositId, address beneficiary)
        external
        onlyRole(HOST_OPERATOR_ROLE)
    {
        _zapper.setDepositBeneficiary(depositId, beneficiary);
    }

    /**
     * @dev Forward: approve external deposit with explicit price snapshot.
     */
    function approveExternalDepositWithPrice(bytes32 depositId, uint256 approvedUsdc, uint256 price)
        external
        onlyRole(CURATOR_OPERATOR_ROLE)
    {
        _zapper.approveExternalDepositWithPrice(depositId, approvedUsdc, price);
    }
}


