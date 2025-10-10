// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/**
 * @title ICopperPriceConsumer
 * @notice Interface for copper price oracle consumers
 * @dev Defines the standard interface for contracts that consume copper price data
 *      from Chainlink oracles or other price feed sources.
 */
interface ICopperPriceConsumer {
    /**
     * @notice Requests the latest copper price from the oracle
     * @dev Initiates a request to the Chainlink oracle for current copper spot price.
     *      The oracle will respond by calling the fulfill function.
     *
     * @return requestId The unique identifier for this price request
     */
    function requestCopperPrice() external returns (bytes32 requestId);

    /**
     * @notice Oracle callback function to receive price data
     * @dev This function is called by the Chainlink oracle with the requested price.
     *      Only authorized oracles should be able to call this function.
     *
     * @param _requestId The request ID that this fulfillment is for
     * @param _price The copper price with appropriate decimal precision
     */
    function fulfill(bytes32 _requestId, uint256 _price) external;

    /**
     * @notice Returns the copper price as a decimal value
     * @dev Returns the price divided by the precision multiplier for human readability.
     *      For example, if stored price is 450000000 (8 decimals), returns 4.5
     *
     * @return priceDecimal The copper price as a decimal value
     */
    function getPriceAsDecimal() external view returns (uint256 priceDecimal);

    /**
     * @notice Returns the raw copper price with full precision
     * @dev Returns the price as stored internally, including all decimal places.
     *      Typically stored with 8 decimal precision (e.g., $4.50 = 450000000)
     *
     * @return rawPrice The copper price with full precision
     */
    function price() external view returns (uint256 rawPrice);

    /**
     * @notice Manually updates the copper price
     * @dev Allows authorized addresses to set the price directly, typically used
     *      for emergency updates or testing scenarios.
     *
     * @param _price The new price to set with appropriate decimal precision
     */
    function updatePrice(uint256 _price) external;
}
