// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {ReentrancyGuardUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {ERC4626Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC4626Upgradeable.sol";
import {ERC20Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";

import {IERC20} from "@openzeppelin/contracts/interfaces/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IUniswapV2Router02} from "@uniswap/v2-periphery/contracts/interfaces/IUniswapV2Router02.sol";

import {IAssetOracle} from "./interfaces/IAssetOracle.sol";

/**
 * @title RWAVault
 * @notice ERC-4626 compliant vault for any tokenised real-world asset.
 *
 * @dev Deposits are unrestricted. Withdrawals and redemptions are restricted to
 *      addresses holding REDEEMER_ROLE (OpenLiquidityRouter, RFQEngine) so that
 *      the protocol can enforce off-chain KYC/KYB checks and settlement rules
 *      before releasing underlying assets.
 *
 *      Role layout:
 *        DEFAULT_ADMIN_ROLE — protocol multisig / deployer
 *        REDEEMER_ROLE      — OpenLiquidityRouter + RFQEngine
 *
 *      Share decimals: 6 (matching USDC as the primary settlement currency).
 *      Override `decimals()` in an inheriting contract if a different precision is needed.
 */
contract RWAVault is
    Initializable,
    UUPSUpgradeable,
    ERC4626Upgradeable,
    OwnableUpgradeable,
    PausableUpgradeable,
    AccessControlUpgradeable,
    ReentrancyGuardUpgradeable
{
    using SafeERC20 for IERC20;

    // ─────────────────────────── ROLES ──────────────────────────────────────

    /// @notice Contracts authorised to call withdraw() / redeem() on behalf of users.
    bytes32 public constant REDEEMER_ROLE = keccak256("REDEEMER_ROLE");

    // ─────────────────────────── STATE ──────────────────────────────────────

    IAssetOracle       public assetOracle;
    IUniswapV2Router02 public uniswapRouter;
    IERC20             public settlementToken;

    /// @notice WETH address used as intermediate hop in ETH-denominated price paths.
    address public wethToken;

    /**
     * @notice Optional intermediate token for multi-hop Uniswap quotes.
     * @dev    Set this to a token (e.g. USDT) that has a liquid pair with both
     *         the input token (e.g. WETH) AND the settlement token (e.g. USDC).
     *         When a direct 2-token path reverts (no pool / no liquidity) this
     *         3-token path is tried automatically.  Leave as address(0) to
     *         disable the fallback.
     */
    address public swapIntermediary;

    // ─────────────────────────── ERRORS ─────────────────────────────────────

    error InvalidAddress();
    error InvalidAmount();
    error InvalidAssetPrice();
    error OracleNotSet();
    error NoLiquidPath();

    // ─────────────────────────── EVENTS ─────────────────────────────────────

    event AssetOracleUpdated(address indexed previous, address indexed current);
    event UniswapRouterUpdated(address indexed previous, address indexed current);
    event SettlementTokenUpdated(address indexed previous, address indexed current);
    event WethTokenUpdated(address indexed previous, address indexed current);
    event SwapIntermediaryUpdated(address indexed previous, address indexed current);

    // ─────────────────────────── INIT ───────────────────────────────────────

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() { _disableInitializers(); }

    /**
     * @param assetToken_    RWA token this vault wraps (underlying of the ERC-4626).
     * @param name_          ERC-20 name for vault shares.
     * @param symbol_        ERC-20 symbol for vault shares.
     * @param assetOracle_   Price oracle for the underlying asset.
     * @param uniswapRouter_ Uniswap V2 router for exchange-rate queries.
     * @param settlementToken_   Settlement token for deposits/redemptions (e.g. USDC, USDT, DAI).
     * @param wethToken_         WETH address for ETH-quoted price paths.
     */
    function initialize(
        IERC20  assetToken_,
        string  memory name_,
        string  memory symbol_,
        address assetOracle_,
        address uniswapRouter_,
        address settlementToken_,
        address wethToken_
    ) public initializer {
        if (address(assetToken_) == address(0)) revert InvalidAddress();
        if (assetOracle_         == address(0)) revert InvalidAddress();
        if (uniswapRouter_       == address(0)) revert InvalidAddress();
        if (settlementToken_     == address(0)) revert InvalidAddress();
        if (wethToken_           == address(0)) revert InvalidAddress();

        __ERC20_init(name_, symbol_);
        __ERC4626_init(assetToken_);
        __UUPSUpgradeable_init();
        __AccessControl_init();
        __Ownable_init(_msgSender());
        __Pausable_init();
        __ReentrancyGuard_init();

        _grantRole(DEFAULT_ADMIN_ROLE, _msgSender());

        assetOracle      = IAssetOracle(assetOracle_);
        uniswapRouter    = IUniswapV2Router02(uniswapRouter_);
        settlementToken  = IERC20(settlementToken_);
        wethToken        = wethToken_;
    }

    // ─────────────────────────── ERC-4626 OVERRIDES ─────────────────────────

    /// @inheritdoc ERC4626Upgradeable
    function withdraw(
        uint256 assets,
        address receiver,
        address owner
    ) public override onlyRole(REDEEMER_ROLE) nonReentrant whenNotPaused returns (uint256 shares) {
        return super.withdraw(assets, receiver, owner);
    }

    /// @inheritdoc ERC4626Upgradeable
    function redeem(
        uint256 shares,
        address receiver,
        address owner
    ) public override onlyRole(REDEEMER_ROLE) nonReentrant whenNotPaused returns (uint256 assets) {
        return super.redeem(shares, receiver, owner);
    }

    // ─────────────────────────── PRICE UTILITIES ────────────────────────────

    /**
     * @notice Canonical WETH address for price path resolution.
     * @dev    Prefers the explicitly configured `wethToken`.  Falls back to
     *         `uniswapRouter.WETH()` so that price quotes always use the same
     *         WETH address as the router itself — even if `wethToken` was not
     *         set or was configured to a wrong address.
     */
    function _resolveWeth() internal view returns (address) {
        if (wethToken != address(0)) return wethToken;
        return uniswapRouter.WETH();
    }

    /// @notice Current raw asset price from the configured oracle (8 decimal precision).
    function getAssetPrice() public view returns (uint256) {
        if (address(assetOracle) == address(0)) revert OracleNotSet();
        return assetOracle.price();
    }

    /**
     * @notice Quote `fromAmount` of `fromToken` into settlement token units.
     * @dev    Tries a direct 2-hop Uniswap path first.  If that reverts (e.g. no
     *         pool or zero reserves), falls back to a 3-hop path via
     *         `swapIntermediary` when one is configured.
     *         Reverts with `NoLiquidPath` if neither path succeeds.
     */
    function _quoteToSettlement(
        address fromToken,
        uint256 fromAmount
    ) internal view returns (uint256) {
        address[] memory directPath = new address[](2);
        directPath[0] = fromToken;
        directPath[1] = address(settlementToken);

        try uniswapRouter.getAmountsOut(fromAmount, directPath) returns (
            uint256[] memory amounts
        ) {
            return amounts[1];
        } catch {
            address mid = swapIntermediary;
            if (
                mid == address(0) ||
                mid == fromToken  ||
                mid == address(settlementToken)
            ) revert NoLiquidPath();

            address[] memory multiPath = new address[](3);
            multiPath[0] = fromToken;
            multiPath[1] = mid;
            multiPath[2] = address(settlementToken);

            uint256[] memory amounts = uniswapRouter.getAmountsOut(fromAmount, multiPath);
            return amounts[2];
        }
    }

    /**
     * @notice Quote `fromSettlement` units of settlement token into `toToken`.
     * @dev    Mirror of `_quoteToSettlement` — tries direct path, then multi-hop.
     */
    function _quoteFromSettlement(
        address toToken,
        uint256 fromSettlement
    ) internal view returns (uint256) {
        address[] memory directPath = new address[](2);
        directPath[0] = address(settlementToken);
        directPath[1] = toToken;

        try uniswapRouter.getAmountsOut(fromSettlement, directPath) returns (
            uint256[] memory amounts
        ) {
            return amounts[1];
        } catch {
            address mid = swapIntermediary;
            if (
                mid == address(0) ||
                mid == toToken  ||
                mid == address(settlementToken)
            ) revert NoLiquidPath();

            address[] memory multiPath = new address[](3);
            multiPath[0] = address(settlementToken);
            multiPath[1] = mid;
            multiPath[2] = toToken;

            uint256[] memory amounts = uniswapRouter.getAmountsOut(fromSettlement, multiPath);
            return amounts[2];
        }
    }

    /**
     * @notice USD value of `shareAmount` vault shares denominated in `quoteToken`.
     * @dev Uses oracle price for USD conversion; routes through Uniswap for non-USDC
     *      quote tokens. Pass `address(0)` to receive the WETH-equivalent quote.
     *      Falls back to a multi-hop path via `swapIntermediary` if the direct
     *      Uniswap pool is absent or has no liquidity.
     * @param quoteToken  Token to express value in. `address(0)` → WETH.
     * @param shareAmount Number of vault shares to price.
     */
    function getShareValueIn(
        address quoteToken,
        uint256 shareAmount
    ) external view returns (uint256 value) {
        if (shareAmount == 0) revert InvalidAmount();

        uint256 assetAmount = convertToAssets(shareAmount);
        uint256 assetPrice  = getAssetPrice();
        if (assetPrice == 0) revert InvalidAssetPrice();

        uint8   oracleDecimals = assetOracle.decimals();
        uint256 scale          = 10 ** uint256(oracleDecimals);

        uint256 settlementValue = (assetAmount * assetPrice) / scale;
        address actualToken     = quoteToken == address(0) ? _resolveWeth() : quoteToken;

        if (actualToken == address(settlementToken)) {
            return settlementValue;
        }

        return _quoteFromSettlement(actualToken, settlementValue);
    }

    /**
     * @notice Vault shares received for `tokenAmount` of `inputToken`.
     * @dev Routes non-settlement tokens through Uniswap to obtain a settlement
     *      token value, then divides by the oracle price to derive the underlying
     *      asset amount, and finally converts to shares via the ERC-4626 rate.
     *      When ETH is passed as `address(0)` it is treated as WETH.
     *      Falls back to a multi-hop path via `swapIntermediary` if the direct
     *      WETH → settlementToken Uniswap pool is absent or has no liquidity.
     * @param inputToken  Token being deposited. `address(0)` → WETH equivalent.
     * @param tokenAmount Amount of `inputToken`.
     */
    function getTokenToShareRate(
        address inputToken,
        uint256 tokenAmount
    ) external view returns (uint256 shares) {
        if (tokenAmount == 0) revert InvalidAmount();

        address actualToken     = inputToken == address(0) ? _resolveWeth() : inputToken;
        uint256 settlementValue;

        if (actualToken == address(settlementToken)) {
            settlementValue = tokenAmount;
        } else {
            settlementValue = _quoteToSettlement(actualToken, tokenAmount);
        }

        uint256 assetPrice = getAssetPrice();
        if (assetPrice == 0) revert InvalidAssetPrice();

        uint8   oracleDecimals = assetOracle.decimals();
        uint256 scale          = 10 ** uint256(oracleDecimals);

        uint256 assetAmount = (settlementValue * scale) / assetPrice;
        shares = convertToShares(assetAmount);
    }

    // ─────────────────────────── ADMIN ──────────────────────────────────────

    function setAssetOracle(address newOracle) external onlyOwner {
        if (newOracle == address(0)) revert InvalidAddress();
        emit AssetOracleUpdated(address(assetOracle), newOracle);
        assetOracle = IAssetOracle(newOracle);
    }

    function setUniswapRouter(address newRouter) external onlyOwner {
        if (newRouter == address(0)) revert InvalidAddress();
        emit UniswapRouterUpdated(address(uniswapRouter), newRouter);
        uniswapRouter = IUniswapV2Router02(newRouter);
    }

    function setSettlementToken(address newToken) external onlyOwner {
        if (newToken == address(0)) revert InvalidAddress();
        emit SettlementTokenUpdated(address(settlementToken), newToken);
        settlementToken = IERC20(newToken);
    }

    function setWethToken(address newWeth) external onlyOwner {
        if (newWeth == address(0)) revert InvalidAddress();
        emit WethTokenUpdated(wethToken, newWeth);
        wethToken = newWeth;
    }

    /**
     * @notice Set the intermediate token used in multi-hop Uniswap fallback paths.
     * @dev    Set to `address(0)` to disable the multi-hop fallback.
     *         Useful when deploying on networks where a direct WETH/settlementToken
     *         pool does not exist (e.g. Sepolia testnets).
     */
    function setSwapIntermediary(address newIntermediary) external onlyOwner {
        emit SwapIntermediaryUpdated(swapIntermediary, newIntermediary);
        swapIntermediary = newIntermediary;
    }

    function pause()   external onlyOwner { _pause();   }
    function unpause() external onlyOwner { _unpause(); }

    /// @dev Only the owner (protocol admin) may authorize an implementation upgrade.
    function _authorizeUpgrade(address) internal override onlyOwner {}

    /// @dev 6 decimal shares align with 6-decimal settlement tokens (e.g. USDC, USDT) as the primary pricing unit.
    function decimals() public pure override returns (uint8) { return 6; }

    uint256[44] private __gap;
}
