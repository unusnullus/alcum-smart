// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
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
 * @dev An ERC4626 vault that wraps CUP tokens with controlled redemption access.
 * This vault is designed to work with the Zapper contract, where users deposit
 * various tokens (USDC, ETH, etc.) via the Zapper, which converts them to CUP
 * tokens and deposits them into this vault on behalf of users.
 *
 * Users receive xCUP shares representing their share of the vault's CUP holdings,
 * but only authorized contracts (like the Zapper) can redeem shares on behalf of users.
 */
contract xCUP is Initializable, ERC4626Upgradeable, OwnableUpgradeable, PausableUpgradeable, AccessControlUpgradeable {
    using SafeERC20 for IERC20;

    /// @dev Role identifier for contracts that can redeem user shares (e.g., Zapper)
    bytes32 public constant REDEEMER_ROLE = keccak256("REDEEMER_ROLE");

    /// @dev Copper price consumer contract
    ICopperPriceConsumer public copperPriceConsumer;

    /// @dev Uniswap V2 router for token swaps
    IUniswapV2Router02 public uniswapRouter;

    /// @dev USDC token address for price calculations
    IERC20 public usdcToken;

    /// @dev WETH token address for ETH price calculations
    address public wethToken;

    /// @dev Flag to prevent re-initializing V2
    bool public v2Initialized;

    uint8 private constant COPPER_PRICE_DECIMALS = 11;

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
     * @dev Initializes the xCUP vault with the underlying asset and metadata
     * @param underlying_ The underlying asset (CUP token)
     * @param name_ The name of the vault token
     * @param symbol_ The symbol of the vault token
     */
    function initialize(IERC20 underlying_, string memory name_, string memory symbol_) public initializer {
        require(address(underlying_) != address(0), "Invalid underlying asset");

        __ERC20_init(name_, symbol_);
        __ERC4626_init(underlying_);
        __AccessControl_init();
        __Ownable_init(_msgSender());
        __Pausable_init();

        _grantRole(DEFAULT_ADMIN_ROLE, _msgSender());
    }

    /**
     * @dev Initialize V2 functionality - sets up price-related contracts
     * @param copperPriceConsumer_ The copper price consumer contract
     * @param uniswapRouter_ The Uniswap V2 router address
     * @param usdcToken_ The USDC token address
     * @param wethToken_ The WETH token address
     */
    function initializeV2(
        address copperPriceConsumer_,
        address uniswapRouter_,
        address usdcToken_,
        address wethToken_
    ) external onlyOwner {
        require(!v2Initialized, "V2 already initialized");
        require(copperPriceConsumer_ != address(0), "Invalid copper price consumer");
        require(uniswapRouter_ != address(0), "Invalid Uniswap router");
        require(usdcToken_ != address(0), "Invalid USDC token");
        require(wethToken_ != address(0), "Invalid WETH token");

        copperPriceConsumer = ICopperPriceConsumer(copperPriceConsumer_);
        uniswapRouter = IUniswapV2Router02(uniswapRouter_);
        usdcToken = IERC20(usdcToken_);
        wethToken = wethToken_;

        v2Initialized = true;

        emit V2Initialized(copperPriceConsumer_, uniswapRouter_, usdcToken_, wethToken_, block.timestamp);
    }

    /** @dev See {IERC4626-withdraw}.
     * @custom:revert if caller is not the redeemer.
     */
    function withdraw(
        uint256 assets,
        address receiver,
        address owner
    ) public override onlyRole(REDEEMER_ROLE) returns (uint256) {
        return super.withdraw(assets, receiver, owner);
    }

    /** @dev See {IERC4626-redeem}.
     * @custom:revert if caller is not the redeemer.
     */
    function redeem(
        uint256 shares,
        address receiver,
        address owner
    ) public override onlyRole(REDEEMER_ROLE) returns (uint256) {
        return super.redeem(shares, receiver, owner);
    }

    /**
     * @dev Pauses the vault, preventing deposits and withdrawals
     */
    function pause() public onlyOwner {
        _pause();
    }

    /**
     * @dev Unpauses the vault, allowing deposits and withdrawals
     */
    function unpause() public onlyOwner {
        _unpause();
    }

    /**
     * @dev Returns the number of decimals for the vault token
     * @return The number of decimals
     */
    function decimals() public view override returns (uint8) {
        return 6;
    }

    /**
     * @dev Modifier to check if price contracts are initialized
     */
    modifier priceContractsInitialized() {
        require(address(copperPriceConsumer) != address(0), "Copper price consumer not initialized");
        require(address(uniswapRouter) != address(0), "Uniswap router not initialized");
        require(address(usdcToken) != address(0), "USDC token not initialized");
        require(wethToken != address(0), "WETH token not initialized");
        _;
    }

    function getCopperPrice() public view returns (uint256 price) {
        price = copperPriceConsumer.price();
    }

    /**
     * @dev Set new copper price consumer address (owner only)
     * @param newCopperPriceConsumer New copper price consumer address
     */
    function setCopperPriceConsumer(address newCopperPriceConsumer) external onlyOwner {
        require(newCopperPriceConsumer != address(0), "Invalid copper price consumer");
        address previous = address(copperPriceConsumer);
        copperPriceConsumer = ICopperPriceConsumer(newCopperPriceConsumer);
        emit CopperPriceConsumerUpdated(previous, newCopperPriceConsumer);
    }

    /**
     * @dev Get XCUP price in specified token (ETH, USDT, USDC, etc.)
     * @param token Token address to get XCUP price in
     * @param xcupAmount Amount of XCUP tokens for calculation
     * @return price Price in specified token
     */
    function getXcupPriceInToken(
        address token,
        uint256 xcupAmount
    ) external view priceContractsInitialized returns (uint256 price) {
        require(xcupAmount > 0, "Amount must be > 0");

        address actualToken = token == address(0) ? wethToken : token;

        uint256 currentCopperPrice = getCopperPrice();
        require(currentCopperPrice > 0, "Invalid copper price");

        uint256 scale = 10 ** uint256(COPPER_PRICE_DECIMALS);
        uint256 totalUsdValue = (xcupAmount * scale) / currentCopperPrice;

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
    function getTokenToXcupExchangeRate(
        address token,
        uint256 tokenAmount
    ) external view priceContractsInitialized returns (uint256 xcupAmount) {
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

        // Get copper price (11 decimals)
        uint256 currentCopperPrice = getCopperPrice();
        require(currentCopperPrice > 0, "Invalid copper price");

        uint256 scale = 10 ** uint256(COPPER_PRICE_DECIMALS);
        // xcupAmount = (usdcValue * currentCopperPrice) / scale
        xcupAmount = (usdcValue * currentCopperPrice) / scale;
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
