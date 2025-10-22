// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";

import {Zapper} from "./Zapper.sol";

/**
 * @title HostAdapter
 * @notice Isolated adapter for host-to-host integrations with the Zapper contract
 * @dev This contract forwards external deposit operations to Zapper while keeping
 *      integration roles separate. It acts as a middleware layer between external
 *      systems and the core Zapper functionality, providing role-based access control
 *      for different types of operations.
 */
contract HostAdapter is Initializable, OwnableUpgradeable, AccessControlUpgradeable {
    /// @notice Role identifier for backend operators to register/update external deposits
    /// @dev Granted to backend services that need to register deposits on behalf of users
    bytes32 public constant HOST_OPERATOR_ROLE = keccak256("HOST_OPERATOR_ROLE");

    /// @notice Role identifier for curator operators to approve external deposits
    /// @dev Granted to curators who can approve deposits with specific price snapshots
    bytes32 public constant CURATOR_OPERATOR_ROLE = keccak256("CURATOR_OPERATOR_ROLE");

    /// @notice The Zapper contract instance this adapter forwards calls to
    Zapper private _zapper;

    /**
     * @notice Emitted when an external deposit is registered through the adapter
     * @param operator The address that registered the deposit
     * @param beneficiary The address that will receive the xCUP tokens
     * @param depositId The unique identifier for the deposit
     * @param tag The integration tag for tracking
     * @param amount The USDC amount of the deposit
     */
    event ExternalDepositRegistered(
        address indexed operator, address indexed beneficiary, bytes32 indexed depositId, bytes32 tag, uint256 amount
    );

    /**
     * @notice Emitted when a deposit beneficiary is updated
     * @param operator The address that updated the beneficiary
     * @param depositId The deposit identifier
     * @param oldBeneficiary The previous beneficiary address
     * @param newBeneficiary The new beneficiary address
     */
    event DepositBeneficiaryUpdated(
        address indexed operator, bytes32 indexed depositId, address indexed oldBeneficiary, address newBeneficiary
    );

    /**
     * @notice Emitted when an external deposit is approved with price snapshot
     * @param curator The address that approved the deposit
     * @param depositId The deposit identifier
     * @param approvedAmount The approved USDC amount
     * @param priceSnapshot The price used for approval
     */
    event ExternalDepositApproved(
        address indexed curator, bytes32 indexed depositId, uint256 approvedAmount, uint256 priceSnapshot
    );

    /**
     * @notice Emitted when the Zapper contract address is updated
     * @param oldZapper The previous Zapper contract address
     * @param newZapper The new Zapper contract address
     */
    event ZapperUpdated(address indexed oldZapper, address indexed newZapper);

    /// @notice Thrown when zapper address is invalid (zero address)
    error InvalidZapperAddress();

    /// @notice Thrown when beneficiary address is invalid (zero address)
    error InvalidBeneficiary();

    /// @notice Thrown when amount is zero or invalid
    error InvalidAmount();

    /// @notice Thrown when approved amount is zero or invalid
    error InvalidApprovedAmount();

    /// @notice Thrown when price is zero or invalid
    error InvalidPrice();

    /// @notice Thrown when trying to set the same zapper address
    error SameZapperAddress();

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /**
     * @notice Initializes the HostAdapter contract
     * @dev This function replaces the constructor for upgradeable contracts.
     *      Sets up the connection to the Zapper contract and grants initial roles.
     *
     * Requirements:
     * - Can only be called once due to initializer modifier
     * - `zapper_` must be a non-zero address
     * - Caller becomes the owner and admin of the contract
     *
     * @param zapper_ The address of the Zapper contract to forward calls to
     *
     * @custom:oz-initializer
     */
    function initialize(address payable zapper_) public initializer {
        if (zapper_ == address(0)) revert InvalidZapperAddress();

        __Ownable_init(_msgSender());
        __AccessControl_init();

        _zapper = Zapper(zapper_);

        _grantRole(DEFAULT_ADMIN_ROLE, _msgSender());
        _grantRole(HOST_OPERATOR_ROLE, _msgSender());
        _grantRole(CURATOR_OPERATOR_ROLE, _msgSender());
    }

    /**
     * @notice Returns the address of the connected Zapper contract
     * @dev Provides transparency into which Zapper contract this adapter forwards to.
     *
     * @return zapperAddress The address of the Zapper contract
     */
    function zapper() external view returns (address zapperAddress) {
        return address(_zapper);
    }

    /**
     * @notice Registers an external deposit for a beneficiary through the Zapper
     * @dev Forwards the call to the Zapper contract's registerExternalDepositFor function.
     *      This function does not involve any token movement - it only registers the
     *      deposit information for later approval and claiming.
     *
     * Requirements:
     * - Caller must have HOST_OPERATOR_ROLE
     * - This adapter must have HOST_INTEGRATION_ROLE on the Zapper contract
     * - `beneficiary` must be a non-zero address
     * - `usdcAmount` must be greater than 0
     *
     * @param beneficiary The address that will receive xCUP tokens when claimed
     * @param usdcAmount The USDC amount being registered (informational only)
     * @param tag An integration-specific identifier for tracking purposes
     *
     * @return depositId The unique identifier for the registered deposit
     *
     * Emits an {ExternalDepositRegistered} event.
     */
    function registerExternalDepositFor(address beneficiary, uint256 usdcAmount, bytes32 tag)
        external
        onlyRole(HOST_OPERATOR_ROLE)
        returns (bytes32 depositId)
    {
        if (beneficiary == address(0)) revert InvalidBeneficiary();
        if (usdcAmount == 0) revert InvalidAmount();

        depositId = _zapper.registerExternalDepositFor(beneficiary, usdcAmount, tag);

        emit ExternalDepositRegistered(_msgSender(), beneficiary, depositId, tag, usdcAmount);
    }

    /**
     * @notice Updates the beneficiary address for a pending deposit
     * @dev Forwards the call to the Zapper contract's setDepositBeneficiary function.
     *      This can only be done before the deposit is approved.
     *
     * Requirements:
     * - Caller must have HOST_OPERATOR_ROLE
     * - Deposit must exist and not be approved yet
     * - `beneficiary` must be a non-zero address
     *
     * @param depositId The unique identifier of the deposit to update
     * @param beneficiary The new beneficiary address
     *
     * Emits a {DepositBeneficiaryUpdated} event.
     */
    function setDepositBeneficiary(bytes32 depositId, address beneficiary) external onlyRole(HOST_OPERATOR_ROLE) {
        if (beneficiary == address(0)) revert InvalidBeneficiary();

        // Get current deposit info to emit the old beneficiary
        Zapper.Deposit memory deposit = _zapper.getDeposit(depositId);
        address oldBeneficiary = deposit.beneficiary;

        _zapper.setDepositBeneficiary(depositId, beneficiary);

        emit DepositBeneficiaryUpdated(_msgSender(), depositId, oldBeneficiary, beneficiary);
    }

    /**
     * @notice Approves an external deposit with a specific price snapshot
     * @dev Forwards the call to the Zapper contract's approveExternalDepositWithPrice function.
     *      This locks in both the approved amount and the price to be used for CUP conversion.
     *
     * Requirements:
     * - Caller must have CURATOR_OPERATOR_ROLE
     * - Deposit must exist and not be approved yet
     * - `approvedUsdc` must be greater than 0 and not exceed deposit amount
     * - `price` must be greater than 0
     *
     * @param depositId The unique identifier of the deposit to approve
     * @param approvedUsdc The USDC amount to approve (may be less than deposited amount)
     * @param price The copper price to use for CUP conversion (8 decimal precision)
     *
     * Emits an {ExternalDepositApproved} event.
     */
    function approveExternalDepositWithPrice(bytes32 depositId, uint256 approvedUsdc, uint256 price)
        external
        onlyRole(CURATOR_OPERATOR_ROLE)
    {
        if (approvedUsdc == 0) revert InvalidApprovedAmount();
        if (price == 0) revert InvalidPrice();

        _zapper.approveExternalDepositWithPrice(depositId, approvedUsdc, price);

        emit ExternalDepositApproved(_msgSender(), depositId, approvedUsdc, price);
    }

    /**
     * @notice Updates the Zapper contract address
     * @dev Only callable by the contract owner. Used when the Zapper contract is upgraded.
     *
     * Requirements:
     * - Caller must be the contract owner
     * - `newZapper` must be a non-zero address
     * - `newZapper` must be different from current Zapper
     *
     * @param newZapper The address of the new Zapper contract
     */
    function setZapper(address payable newZapper) external onlyOwner {
        if (newZapper == address(0)) revert InvalidZapperAddress();
        if (newZapper == address(_zapper)) revert SameZapperAddress();

        address oldZapper = address(_zapper);
        _zapper = Zapper(newZapper);

        emit ZapperUpdated(oldZapper, newZapper);
    }
}
