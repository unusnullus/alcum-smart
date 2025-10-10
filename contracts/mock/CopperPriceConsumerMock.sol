// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ChainlinkClient} from "@chainlink/contracts/src/v0.8/ChainlinkClient.sol";
import {Chainlink} from "@chainlink/contracts/src/v0.8/Chainlink.sol";

import {ICopperPriceConsumer} from "../interfaces/ICopperPriceConsumer.sol";

/**
 * @title CopperPriceConsumerMock
 * @notice Mock implementation of copper price consumer for testing
 * @dev This contract provides a simplified implementation of the ICopperPriceConsumer
 *      interface for testing purposes. It allows manual price updates and simulates
 *      oracle behavior without requiring actual Chainlink infrastructure.
 */
contract CopperPriceConsumerMock is ChainlinkClient, ICopperPriceConsumer {
    using Chainlink for Chainlink.Request;

    /// @notice Current copper price with 8 decimal precision
    /// @dev Default price is set to $5.00 (500000000 with 8 decimals)
    uint256 public price;

    /// @notice Mock oracle address (not used in testing)
    address private oracle;

    /// @notice Mock job ID (not used in testing)
    bytes32 private jobId;

    /// @notice Mock fee (not used in testing)
    uint256 private fee;

    /**
     * @notice Emitted when the price is updated manually
     * @param oldPrice The previous price value
     * @param newPrice The new price value
     * @param updatedBy The address that updated the price
     */
    event PriceUpdated(uint256 oldPrice, uint256 newPrice, address indexed updatedBy);

    /**
     * @notice Initializes the mock with a default copper price
     * @dev Sets the initial price to $5.00 (500000000 with 8 decimals)
     */
    constructor() {
        price = 500000000; // $5.00 with 8 decimal precision
    }

    /**
     * @notice Mock implementation of price request
     * @dev In a real implementation, this would send a request to Chainlink oracle.
     *      In this mock, it simply returns a dummy request ID.
     *
     * @return requestId A mock request ID (always returns bytes32(0))
     */
    function requestCopperPrice() public returns (bytes32 requestId) {
        // Mock implementation - in real contract this would interact with Chainlink
        Chainlink.Request memory req = _buildChainlinkRequest(jobId, address(this), this.fulfill.selector);
        req._add("base", "COPPER");
        req._add("quote", "USD");

        // Return mock request ID for testing
        return bytes32(0);
    }

    /**
     * @notice Mock fulfillment function for testing oracle responses
     * @dev In a real implementation, this would be called by the Chainlink oracle.
     *      In this mock, it can be called directly for testing purposes.
     *
     * @param _requestId The request ID (ignored in mock)
     * @param _price The new copper price to set
     */
    function fulfill(bytes32 _requestId, uint256 _price) public recordChainlinkFulfillment(_requestId) {
        uint256 oldPrice = price;
        price = _price;
        emit PriceUpdated(oldPrice, _price, msg.sender);
    }

    /**
     * @notice Returns the copper price as a decimal value
     * @dev In this mock implementation, returns the raw price value.
     *      In the real implementation, this would divide by 10^8.
     *
     * @return priceDecimal The copper price (raw value in mock)
     */
    function getPriceAsDecimal() public view returns (uint256 priceDecimal) {
        return price;
    }

    /**
     * @notice Manually updates the copper price for testing
     * @dev Allows direct price updates for testing scenarios.
     *      Anyone can call this function in the mock implementation.
     *
     * @param _price The new price to set with 8 decimal precision
     *
     * Emits a {PriceUpdated} event.
     */
    function updatePrice(uint256 _price) external {
        uint256 oldPrice = price;
        price = _price;
        emit PriceUpdated(oldPrice, _price, msg.sender);
    }

    /**
     * @notice Sets the mock oracle configuration for testing
     * @dev Allows setting oracle parameters for more realistic testing scenarios.
     *
     * @param _oracle Mock oracle address
     * @param _jobId Mock job ID
     * @param _fee Mock fee amount
     */
    function setOracleConfig(address _oracle, bytes32 _jobId, uint256 _fee) external {
        oracle = _oracle;
        jobId = _jobId;
        fee = _fee;
    }

    /**
     * @notice Returns the current mock oracle configuration
     * @dev Provides access to mock oracle settings for testing verification.
     *
     * @return oracleAddr The mock oracle address
     * @return currentJobId The mock job ID
     * @return currentFee The mock fee amount
     */
    function getOracleConfig() external view returns (address oracleAddr, bytes32 currentJobId, uint256 currentFee) {
        return (oracle, jobId, fee);
    }
}
