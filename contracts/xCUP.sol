// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {ReentrancyGuardUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";

import {IERC20} from "@openzeppelin/contracts/interfaces/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/interfaces/IERC20Metadata.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ERC20Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";

import {ERC4626Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC4626Upgradeable.sol";
import {ICopperPriceConsumer} from "./interfaces/ICopperPriceConsumer.sol";
import {IUniswapV2Router02} from "@uniswap/v2-periphery/contracts/interfaces/IUniswapV2Router02.sol";

/**
 * @title xCUP
 * @notice An ERC4626 vault that wraps CUP tokens with controlled redemption access
 * @dev This vault is designed to work with the Zapper contract, where users deposit
 *      various tokens (USDC, ETH, etc.) via the Zapper, which converts them to CUP
 *      tokens and deposits them into this vault on behalf of users.
 *
 *      Users receive xCUP shares representing their share of the vault's CUP holdings,
 *      but only authorized contracts (like the Zapper) can redeem shares on behalf of users.
 *      The vault integrates with price oracles and DEX routers for price calculations.
 */
contract xCUP is
    Initializable,
    ERC4626Upgradeable,
    OwnableUpgradeable,
    PausableUpgradeable,
    AccessControlUpgradeable,
    ReentrancyGuardUpgradeable
{
    using SafeERC20 for IERC20;

    /// @notice Role identifier for contracts that can redeem user shares (e.g., Zapper)
    /// @dev This role is typically granted to the Zapper contract for user redemptions
    bytes32 public constant REDEEMER_ROLE = keccak256("REDEEMER_ROLE");

    /// @notice Copper price consumer contract for price data
    /// @dev Used to get current copper spot prices for calculations
    ICopperPriceConsumer public copperPriceConsumer;

    /// @notice Uniswap V2 router for token swaps and price queries
    /// @dev Used for getting exchange rates between different tokens
    IUniswapV2Router02 public uniswapRouter;

    /// @notice USDC token contract for price calculations
    /// @dev USDC is used as the base currency for price calculations
    IERC20 public usdcToken;

    /// @notice WETH token address for ETH price calculations
    /// @dev Used when users want to get prices in ETH
    address public wethToken;

    /// @notice Flag to prevent re-initializing V2 functionality
    /// @dev Set to true after V2 initialization to prevent duplicate initialization
    bool public v2Initialized;

    /// @notice Decimal precision for copper price calculations
    /// @dev Copper prices use 8 decimal places for precision
    uint8 private constant COPPER_PRICE_DECIMALS = 8;

    /// @notice Thrown when trying to initialize V2 when already initialized
    error V2AlreadyInitialized();

    /// @notice Thrown when an invalid address is provided
    error InvalidAddress();

    /// @notice Thrown when an invalid amount is provided
    error InvalidAmount();

    /// @notice Thrown when copper price is invalid or zero
    error InvalidCopperPrice();

    /// @notice Thrown when price contracts are not properly initialized
    error PriceContractsNotInitialized();

    event CopperPriceConsumerUpdated(address indexed previous, address indexed current);
    event UniswapRouterUpdated(address indexed previous, address indexed current);
    event UsdcTokenUpdated(address indexed previous, address indexed current);
    event WethTokenUpdated(address indexed previous, address indexed current);
    event V2Initialized(
        address indexed copperPriceConsumer,
        address indexed uniswapRouter,
        address indexed usdcToken,
        address wethToken_,
        uint256 timestamp
    );

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /**
     * @notice Initializes the xCUP vault with the underlying asset and metadata
     * @dev This function replaces the constructor for upgradeable contracts.
     *      Sets up the ERC4626 vault with CUP as underlying asset and initializes
     *      all price-related contracts for exchange rate calculations.
     *
     * Requirements:
     * - Can only be called once due to initializer modifier
     * - All addresses must be non-zero
     * - Caller becomes the owner and admin of the contract
     *
     * @param underlying_ The underlying asset (CUP token contract)
     * @param name_ The name of the vault token (e.g., "xCUP Vault")
     * @param symbol_ The symbol of the vault token (e.g., "xCUP")
     * @param copperPriceConsumer_ The copper price consumer contract address
     * @param uniswapRouter_ The Uniswap V2 router address for price queries
     * @param usdcToken_ The USDC token address for price calculations
     * @param wethToken_ The WETH token address for ETH price calculations
     *
     * Emits a {V2Initialized} event.
     *
     * @custom:oz-initializer
     */
    function initialize(
        IERC20 underlying_,
        string memory name_,
        string memory symbol_,
        address copperPriceConsumer_,
        address uniswapRouter_,
        address usdcToken_,
        address wethToken_
    ) public initializer {
        if (address(underlying_) == address(0)) revert InvalidAddress();
        if (copperPriceConsumer_ == address(0)) revert InvalidAddress();
        if (uniswapRouter_ == address(0)) revert InvalidAddress();
        if (usdcToken_ == address(0)) revert InvalidAddress();
        if (wethToken_ == address(0)) revert InvalidAddress();

        // Initialize all upgradeable components
        __ERC20_init(name_, symbol_);
        __ERC4626_init(underlying_);
        __AccessControl_init();
        __Ownable_init(_msgSender());
        __Pausable_init();
        __ReentrancyGuard_init();

        // Set up access control
        _grantRole(DEFAULT_ADMIN_ROLE, _msgSender());

        // Initialize price-related contracts
        copperPriceConsumer = ICopperPriceConsumer(copperPriceConsumer_);
        uniswapRouter = IUniswapV2Router02(uniswapRouter_);
        usdcToken = IERC20(usdcToken_);
        wethToken = wethToken_;

        v2Initialized = true;

        emit V2Initialized(copperPriceConsumer_, uniswapRouter_, usdcToken_, wethToken_, block.timestamp);
    }

    /**
     * @notice Withdraws assets from the vault by burning shares
     * @dev Only addresses with REDEEMER_ROLE can call this function.
     *      This restriction ensures controlled access to user funds.
     *
     * Requirements:
     * - Caller must have REDEEMER_ROLE
     * - `assets` must be greater than 0
     * - `owner` must have sufficient shares
     * - Contract must not be paused
     *
     * @param assets The amount of underlying assets to withdraw
     * @param receiver The address to receive the withdrawn assets
     * @param owner The address that owns the shares being burned
     *
     * @return shares The amount of shares burned for the withdrawal
     */
    function withdraw(uint256 assets, address receiver, address owner)
        public
        override
        onlyRole(REDEEMER_ROLE)
        nonReentrant
        whenNotPaused
        returns (uint256 shares)
    {
        return super.withdraw(assets, receiver, owner);
    }

    /**
     * @notice Redeems shares for underlying assets
     * @dev Only addresses with REDEEMER_ROLE can call this function.
     *      This restriction ensures controlled access to user funds.
     *
     * Requirements:
     * - Caller must have REDEEMER_ROLE
     * - `shares` must be greater than 0
     * - `owner` must have at least `shares` amount
     * - Contract must not be paused
     *
     * @param shares The amount of shares to redeem
     * @param receiver The address to receive the underlying assets
     * @param owner The address that owns the shares being redeemed
     *
     * @return assets The amount of underlying assets received
     */
    function redeem(uint256 shares, address receiver, address owner)
        public
        override
        onlyRole(REDEEMER_ROLE)
        nonReentrant
        whenNotPaused
        returns (uint256 assets)
    {
        return super.redeem(shares, receiver, owner);
    }

    /**
     * @notice Pauses the vault, preventing deposits and withdrawals
     * @dev Only callable by the contract owner. Used for emergency situations
     *      or maintenance periods.
     *
     * Requirements:
     * - Caller must be the contract owner
     * - Contract must not already be paused
     */
    function pause() public onlyOwner whenNotPaused {
        _pause();
    }

    /**
     * @notice Unpauses the vault, allowing deposits and withdrawals
     * @dev Only callable by the contract owner. Restores normal functionality.
     *
     * Requirements:
     * - Caller must be the contract owner
     * - Contract must be paused
     */
    function unpause() public onlyOwner whenPaused {
        _unpause();
    }

    /**
     * @notice Returns the number of decimals for the vault token
     * @dev xCUP uses 6 decimals to match the underlying CUP token precision.
     *
     * @return decimals The number of decimal places (6)
     */
    function decimals() public view override returns (uint8) {
        return 6;
    }

    /**
     * @notice Modifier to check if price contracts are initialized
     * @dev Ensures all required price-related contracts are set before price operations.
     *      Reverts with PriceContractsNotInitialized if any contract is not set.
     */
    modifier priceContractsInitialized() {
        if (
            address(copperPriceConsumer) == address(0) || address(uniswapRouter) == address(0)
                || address(usdcToken) == address(0) || wethToken == address(0)
        ) {
            revert PriceContractsNotInitialized();
        }
        _;
    }

    /**
     * @notice Returns the current copper price from the oracle
     * @dev Fetches the latest copper price from the configured price consumer.
     *
     * @return price The current copper price with full precision
     */
    function getCopperPrice() public view returns (uint256 price) {
        return copperPriceConsumer.price();
    }

    /**
     * @notice Updates the copper price consumer contract address
     * @dev Only callable by the contract owner. Used when upgrading the price oracle.
     *
     * Requirements:
     * - Caller must be the contract owner
     * - `newCopperPriceConsumer` must be a non-zero address
     *
     * @param newCopperPriceConsumer The new copper price consumer contract address
     *
     * Emits a {CopperPriceConsumerUpdated} event.
     */
    function setCopperPriceConsumer(address newCopperPriceConsumer) external onlyOwner {
        if (newCopperPriceConsumer == address(0)) revert InvalidAddress();

        address previous = address(copperPriceConsumer);
        copperPriceConsumer = ICopperPriceConsumer(newCopperPriceConsumer);

        emit CopperPriceConsumerUpdated(previous, newCopperPriceConsumer);
    }

    /**
     * @notice Calculates the price of xCUP tokens in a specified token
     * @dev Converts xCUP amount to USD value using copper price, then to target token using Uniswap.
     *      For ETH, pass address(0) which will be converted to WETH internally.
     *
     * Requirements:
     * - Price contracts must be initialized
     * - `xcupAmount` must be greater than 0
     * - Copper price must be valid (> 0)
     * - Uniswap pool must exist for non-USDC tokens
     *
     * @param token The token address to get xCUP price in (address(0) for ETH)
     * @param xcupAmount The amount of xCUP tokens to calculate price for
     *
     * @return price The equivalent value in the specified token
     */
    function getXcupPriceInToken(address token, uint256 xcupAmount)
        external
        view
        priceContractsInitialized
        returns (uint256 price)
    {
        if (xcupAmount == 0) revert InvalidAmount();

        address actualToken = token == address(0) ? wethToken : token;

        uint256 currentCopperPrice = getCopperPrice();
        if (currentCopperPrice == 0) revert InvalidCopperPrice();

        // convert shares -> underlying CUP amount
        uint256 cupAmount = convertToAssets(xcupAmount);

        uint256 scale = 10 ** uint256(COPPER_PRICE_DECIMALS);
        uint256 totalUsdValue = (cupAmount * currentCopperPrice) / scale;

        if (actualToken == address(usdcToken)) {
            return totalUsdValue;
        } else {
            // Use Uniswap to get USDC price in specified token
            address[] memory path = new address[](2);
            path[0] = address(usdcToken);
            path[1] = actualToken;

            uint256[] memory amountsOut = uniswapRouter.getAmountsOut(totalUsdValue, path);
            return amountsOut[1];
        }
    }

    /**
     * @dev Get exchange rate of token (ETH, USDT, USDC, etc.) to XCUP
     * @param token Token address
     * @param tokenAmount Amount of tokens for exchange
     * @return xcupAmount Amount of XCUP tokens that can be obtained
     */
    function getTokenToXcupExchangeRate(address token, uint256 tokenAmount)
        external
        view
        priceContractsInitialized
        returns (uint256 xcupAmount)
    {
        require(tokenAmount > 0, "Amount must be > 0");

        address actualToken = token == address(0) ? wethToken : token;
        uint256 usdcValue;

        if (actualToken == address(usdcToken)) {
            usdcValue = tokenAmount;
        } else {
            // Use Uniswap to get token price in USDC
            address[] memory path = new address[](2);
            path[0] = actualToken;
            path[1] = address(usdcToken);

            uint256[] memory amountsOut = uniswapRouter.getAmountsOut(tokenAmount, path);
            usdcValue = amountsOut[1];
        }

        // Get copper price (8 decimals)
        uint256 currentCopperPrice = getCopperPrice();
        require(currentCopperPrice > 0, "Invalid copper price");

        uint256 scale = 10 ** uint256(COPPER_PRICE_DECIMALS);

        // Calculate CUP amount based on copper price
        uint256 cupAmount = (usdcValue * scale) / currentCopperPrice;

        // Convert CUP amount to xCUP shares using ERC4626 conversion
        xcupAmount = convertToShares(cupAmount);
    }

    /**
     * @dev Set new Uniswap router address (owner only)
     * @param newUniswapRouter New Uniswap router address
     */
    function setUniswapRouter(address newUniswapRouter) external onlyOwner {
        require(newUniswapRouter != address(0), "Invalid Uniswap router");
        address previous = address(uniswapRouter);
        uniswapRouter = IUniswapV2Router02(newUniswapRouter);
        emit UniswapRouterUpdated(previous, newUniswapRouter);
    }

    /**
     * @dev Set new USDC token address (owner only)
     * @param newUsdcToken New USDC token address
     */
    function setUsdcToken(address newUsdcToken) external onlyOwner {
        require(newUsdcToken != address(0), "Invalid USDC token");
        address previous = address(usdcToken);
        usdcToken = IERC20(newUsdcToken);
        emit UsdcTokenUpdated(previous, newUsdcToken);
    }

    /**
     * @dev Set new WETH token address (owner only)
     * @param newWethToken New WETH token address
     */
    function setWethToken(address newWethToken) external onlyOwner {
        require(newWethToken != address(0), "Invalid WETH token");
        address previous = wethToken;
        wethToken = newWethToken;
        emit WethTokenUpdated(previous, newWethToken);
    }

    // Reserve storage gap for future upgrades (to avoid storage collisions)
    uint256[45] private __gap;
}
