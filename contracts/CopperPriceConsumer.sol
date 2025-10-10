// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";

import {ChainlinkClient} from "@chainlink/contracts/src/v0.8/ChainlinkClient.sol";
import {Chainlink} from "@chainlink/contracts/src/v0.8/Chainlink.sol";

import {ICopperPriceConsumer} from "./interfaces/ICopperPriceConsumer.sol";

/**
 * @title CopperPriceConsumer
 * @notice Chainlink oracle consumer for fetching copper spot prices
 * @dev This contract integrates with Chainlink oracles to provide reliable copper price data
 *      for the Alcum protocol. It supports both automated oracle updates and manual price
 *      updates by authorized roles.
 */
contract CopperPriceConsumer is
    Initializable,
    ChainlinkClient,
    ICopperPriceConsumer,
    OwnableUpgradeable,
    AccessControlUpgradeable
{
    using Chainlink for Chainlink.Request;

    /// @notice Decimal precision for price storage (8 decimals)
    /// @dev Copper prices are stored with 8 decimal places for precision
    uint256 private constant PRICE_DECIMALS = 8;

    /// @notice Multiplier for price calculations (10^8)
    uint256 private constant PRICE_MULTIPLIER = 10 ** PRICE_DECIMALS;

    /// @notice Role identifier for addresses authorized to manually update prices
    /// @dev Used for emergency price updates or testing scenarios
    bytes32 public constant PRICE_UPDATER_ROLE = keccak256("PRICE_UPDATER_ROLE");

    /// @notice Current copper price in USD with 8 decimal precision
    uint256 public price;

    /// @notice Chainlink oracle address for price requests
    address private oracle;

    /// @notice Chainlink job ID for copper price requests
    bytes32 private jobId;

    /// @notice Fee in LINK tokens required for each price request
    uint256 private fee;

    /// @notice Thrown when oracle address is invalid (zero address)
    error InvalidOracleAddress();

    /// @notice Thrown when LINK token address is invalid (zero address)
    error InvalidLinkAddress();

    /// @notice Thrown when fee is zero or invalid
    error InvalidFee();

    /// @notice Thrown when price from oracle is zero or invalid
    error InvalidPriceFromOracle();

    /// @notice Thrown when trying to set the same job ID
    error SameJobId();

    /// @notice Thrown when trying to set the same fee
    error SameFee();

    /// @notice Thrown when trying to set the same oracle
    error SameOracle();

    /// @notice Thrown when price is zero or invalid
    error InvalidPrice();

    /**
     * @notice Emitted when the copper price is updated
     * @param oldPrice The previous price value
     * @param newPrice The new price value
     * @param updatedBy The address that triggered the update
     * @param timestamp The timestamp of the update
     */
    event PriceUpdated(uint256 oldPrice, uint256 newPrice, address indexed updatedBy, uint256 timestamp);

    /**
     * @notice Emitted when oracle configuration is updated
     * @param oracle The new oracle address
     * @param jobId The new job ID
     * @param fee The new fee amount
     */
    event OracleConfigUpdated(address indexed oracle, bytes32 indexed jobId, uint256 fee);

    /**
     * @notice Emitted when a price request is made to the oracle
     * @param requestId The Chainlink request ID
     * @param oracle The oracle address
     */
    event PriceRequested(bytes32 indexed requestId, address indexed oracle);

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /**
     * @notice Initializes the CopperPriceConsumer contract
     * @dev This function replaces the constructor for upgradeable contracts.
     *      Sets up Chainlink integration and initial price configuration.
     *
     * Requirements:
     * - Can only be called once due to initializer modifier
     * - All addresses must be non-zero
     * - Caller becomes the owner and admin of the contract
     *
     * @param _oracle The Chainlink oracle address for price requests
     * @param _jobId The Chainlink job ID for copper price data
     * @param _fee The fee in LINK tokens required for each request
     * @param _link The LINK token contract address
     *
     * @custom:oz-initializer
     */
    function initialize(address _oracle, bytes32 _jobId, uint256 _fee, address _link) public initializer {
        if (_oracle == address(0)) revert InvalidOracleAddress();
        if (_link == address(0)) revert InvalidLinkAddress();
        if (_fee == 0) revert InvalidFee();

        __Ownable_init(_msgSender());
        __AccessControl_init();

        // Grant the deployer the default admin role and price updater role
        _grantRole(DEFAULT_ADMIN_ROLE, _msgSender());
        _grantRole(PRICE_UPDATER_ROLE, _msgSender());

        _setChainlinkToken(_link);

        oracle = _oracle;
        jobId = _jobId;
        fee = _fee;
    }

    /**
     * @notice Requests the latest copper price from the Chainlink oracle
     * @dev Creates a Chainlink request for COPPER/USD price data.
     *      The oracle will call the fulfill function with the result.
     *
     * Requirements:
     * - Contract must have sufficient LINK balance to pay the fee
     * - Oracle and job ID must be properly configured
     *
     * @return requestId The unique identifier for this price request
     *
     * Emits a {PriceRequested} event.
     */
    function requestCopperPrice() public returns (bytes32 requestId) {
        Chainlink.Request memory req = _buildChainlinkRequest(jobId, address(this), this.fulfill.selector);
        req._add("base", "COPPER");
        req._add("quote", "USD");

        requestId = _sendChainlinkRequestTo(oracle, req, fee);
        emit PriceRequested(requestId, oracle);

        return requestId;
    }

    /**
     * @notice Chainlink oracle callback function to receive price data
     * @dev This function is called by the Chainlink oracle with the requested price.
     *      Only the oracle can call this function for valid request IDs.
     *
     * @param _requestId The request ID that this fulfillment is for
     * @param _price The copper price with 8 decimal precision
     *
     * Emits a {PriceUpdated} event.
     */
    function fulfill(bytes32 _requestId, uint256 _price) public recordChainlinkFulfillment(_requestId) {
        if (_price == 0) revert InvalidPriceFromOracle();

        uint256 oldPrice = price;
        price = _price;

        emit PriceUpdated(oldPrice, _price, oracle, block.timestamp);
    }

    /**
     * @notice Updates the Chainlink job ID for price requests
     * @dev Only callable by the contract owner. Used when oracle configuration changes.
     *
     * Requirements:
     * - Caller must be the contract owner
     * - New job ID must be different from current one
     *
     * @param _jobId The new Chainlink job ID
     */
    function setJobId(bytes32 _jobId) public onlyOwner {
        if (_jobId == jobId) revert SameJobId();

        jobId = _jobId;

        emit OracleConfigUpdated(oracle, _jobId, fee);
    }

    /**
     * @notice Updates the fee required for price requests
     * @dev Only callable by the contract owner. Used when oracle fee structure changes.
     *
     * Requirements:
     * - Caller must be the contract owner
     * - Fee must be greater than 0
     *
     * @param _fee The new fee amount in LINK tokens
     */
    function setFee(uint256 _fee) public onlyOwner {
        if (_fee == 0) revert InvalidFee();
        if (_fee == fee) revert SameFee();

        fee = _fee;
        emit OracleConfigUpdated(oracle, jobId, _fee);
    }

    /**
     * @notice Updates the oracle address for price requests
     * @dev Only callable by the contract owner. Used when switching oracles.
     *
     * Requirements:
     * - Caller must be the contract owner
     * - Oracle address must be non-zero and different from current
     *
     * @param _oracle The new oracle address
     */
    function setOracle(address _oracle) public onlyOwner {
        if (_oracle == address(0)) revert InvalidOracleAddress();
        if (_oracle == oracle) revert SameOracle();

        oracle = _oracle;
        emit OracleConfigUpdated(_oracle, jobId, fee);
    }

    /**
     * @notice Returns the copper price as a decimal (without precision multiplier)
     * @dev Divides the stored price by 10^8 to get the human-readable price.
     *
     * @return priceDecimal The copper price as a decimal value
     */
    function getPriceAsDecimal() public view returns (uint256 priceDecimal) {
        return price / PRICE_MULTIPLIER;
    }

    /**
     * @notice Manually updates the copper price
     * @dev Only addresses with PRICE_UPDATER_ROLE can call this function.
     *      Used for emergency price updates or testing scenarios.
     *
     * Requirements:
     * - Caller must have PRICE_UPDATER_ROLE
     * - Price must be greater than 0
     *
     * @param _price The new price to set (with 8 decimal precision)
     *
     * Emits a {PriceUpdated} event.
     */
    function updatePrice(uint256 _price) public onlyRole(PRICE_UPDATER_ROLE) {
        if (_price == 0) revert InvalidPrice();

        uint256 oldPrice = price;
        price = _price;

        emit PriceUpdated(oldPrice, _price, _msgSender(), block.timestamp);
    }

    // Reserve storage gap for future upgrades (to avoid storage collisions)
    uint256[50] private __gap;
}
