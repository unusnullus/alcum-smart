// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";

import {ChainlinkClient} from "@chainlink/contracts/src/v0.8/ChainlinkClient.sol";
import {Chainlink} from "@chainlink/contracts/src/v0.8/Chainlink.sol";

import {ICopperPriceConsumer} from "./interfaces/ICopperPriceConsumer.sol";

contract CopperPriceConsumer is
    Initializable,
    ChainlinkClient,
    ICopperPriceConsumer,
    OwnableUpgradeable,
    AccessControlUpgradeable
{
    using Chainlink for Chainlink.Request;

    // Decimal precision for price storage (8 decimals)
    uint256 private constant PRICE_DECIMALS = 8;
    uint256 private constant PRICE_MULTIPLIER = 10 ** PRICE_DECIMALS;

    // Role for price updaters
    bytes32 public constant PRICE_UPDATER_ROLE = keccak256("PRICE_UPDATER_ROLE");

    uint256 public price;
    address private oracle;
    bytes32 private jobId;
    uint256 private fee;

    // Events
    event PriceUpdated(uint256 oldPrice, uint256 newPrice, address updatedBy);

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /**
     * @notice Initializes the CopperPriceConsumer contract
     * @dev This function replaces the constructor for upgradeable contracts
     * @param _oracle The Chainlink oracle address
     * @param _jobId The job ID for the price request
     * @param _fee The fee for the price request
     * @param _link The LINK token address
     */
    function initialize(address _oracle, bytes32 _jobId, uint256 _fee, address _link) public initializer {
        require(_oracle != address(0), "Invalid oracle address");
        require(_link != address(0), "Invalid LINK token address");

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

    function requestCopperPrice() public returns (bytes32 requestId) {
        Chainlink.Request memory req = _buildChainlinkRequest(jobId, address(this), this.fulfill.selector);
        req._add("base", "COPPER");
        req._add("quote", "USD");
        return _sendChainlinkRequestTo(oracle, req, fee);
    }

    function fulfill(bytes32 _requestId, uint256 _price) public recordChainlinkFulfillment(_requestId) {
        price = _price;
    }

    function setJobId(bytes32 _jobId) public onlyOwner {
        jobId = _jobId;
    }

    function setFee(uint256 _fee) public onlyOwner {
        fee = _fee;
    }

    function getPriceAsDecimal() public view returns (uint256) {
        return price / PRICE_MULTIPLIER;
    }

    /**
     * @notice Manually update the copper price
     * @dev Only users with PRICE_UPDATER_ROLE can call this function
     * @param _price The new price to set (with 8 decimal precision)
     */
    function updatePrice(uint256 _price) public onlyRole(PRICE_UPDATER_ROLE) {
        require(_price > 0, "Price must be greater than zero");
        uint256 oldPrice = price;
        price = _price;
        emit PriceUpdated(oldPrice, _price, msg.sender);
    }

    // Reserve storage gap for future upgrades (to avoid storage collisions)
    uint256[50] private __gap;
}
