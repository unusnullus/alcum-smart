// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

/**
 * @title IxCUP
 * @dev Interface for xCUP Vault contract with price and exchange rate methods
 */
interface IxCUP {
    /// @dev Price data structure
    struct PriceData {
        uint256 price; // Price in wei (18 decimals)
        uint256 timestamp; // Timestamp
        bool isValid; // Price validity flag
    }

    /// @dev Events
    event TokenExchangeRateCalculated(
        address indexed token, uint256 xcupAmount, uint256 tokenAmount, uint256 rate, uint256 timestamp
    );

    /**
     * @dev Get current XCUP price in USD
     */
    function getXcupPriceInUSD() external view returns (PriceData memory priceData);

    /**
     * @dev Initialize V2 functionality (owner only)
     */
    function initializeV2(address copperPriceConsumer_, address uniswapRouter_, address usdcToken_, address wethToken_)
        external;

    /**
     * @dev Set new copper price consumer address (owner only)
     */
    function setCopperPriceConsumer(address newCopperPriceConsumer) external;

    /**
     * @dev Get XCUP price in specified token (ETH, USDT, USDC, etc.)
     */
    function getXcupPriceInToken(address token, uint256 xcupAmount) external returns (PriceData memory priceData);

    /**
     * @dev Get exchange rate of token to XCUP
     */
    function getTokenToXcupExchangeRate(address token, uint256 tokenAmount)
        external
        returns (PriceData memory priceData);

    // VIEW VERSIONS (no state changes)
    /**
     * @dev Get XCUP price in specified token (view-only)
     */
    function getXcupPriceInTokenView(address token, uint256 xcupAmount)
        external
        view
        returns (PriceData memory priceData);

    /**
     * @dev Get exchange rate of token to XCUP (view-only)
     */
    function getTokenToXcupExchangeRateView(address token, uint256 tokenAmount)
        external
        view
        returns (PriceData memory priceData);

    /**
     * @dev Set new Uniswap router address (owner only)
     */
    function setUniswapRouter(address newUniswapRouter) external;

    /**
     * @dev Set new USDC token address (owner only)
     */
    function setUsdcToken(address newUsdcToken) external;

    /**
     * @dev Set new WETH token address (owner only)
     */
    function setWethToken(address newWethToken) external;
}
