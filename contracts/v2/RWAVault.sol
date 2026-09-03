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
import {IERC20Metadata} from "@openzeppelin/contracts/interfaces/IERC20Metadata.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IUniswapV2Router02} from "@uniswap/v2-periphery/contracts/interfaces/IUniswapV2Router02.sol";

import {IAssetOracle} from "./interfaces/IAssetOracle.sol";
import {INavReader} from "./interfaces/INavReader.sol";

import {VaultLib} from "./libraries/VaultLib.sol";

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
    using Math for uint256;

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

    /// @notice SharedSettlementEngine — source of reported NAV when `reportedInventoryOnly`.
    address public settlementEngine;

    /// @notice Registry vault id (set by VaultFactory after registration).
    uint256 public vaultId;

    /// @notice When true, ERC-4626 `totalAssets` follows operator-reported NAV (§05).
    bool public reportedInventoryOnly;

    // ─────────────────────────── ERRORS ─────────────────────────────────────

    error InvalidAddress();
    error InvalidAmount();
    error InvalidAssetPrice();
    error OracleNotSet();
    error NoLiquidPath();
    error ReportedNavNotConfigured();

    // ─────────────────────────── EVENTS ─────────────────────────────────────

    event AssetOracleUpdated(address indexed previous, address indexed current);
    event UniswapRouterUpdated(address indexed previous, address indexed current);
    event SettlementTokenUpdated(address indexed previous, address indexed current);
    event WethTokenUpdated(address indexed previous, address indexed current);
    event SwapIntermediaryUpdated(address indexed previous, address indexed current);
    event ReportedNavConfigured(
        address indexed settlementEngine,
        uint256 indexed vaultId,
        bool reportedInventoryOnly
    );

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

    /**
     * @inheritdoc ERC4626Upgradeable
     * @dev Deposits are unrestricted (KYC is enforced at the router claim path).
     *      Paused state blocks both deposit and mint.
     */
    function deposit(uint256 assets, address receiver)
        public
        override
        nonReentrant
        whenNotPaused
        returns (uint256)
    {
        return super.deposit(assets, receiver);
    }

    /**
     * @inheritdoc ERC4626Upgradeable
     * @dev See {deposit}.
     */
    function mint(uint256 shares, address receiver)
        public
        override
        nonReentrant
        whenNotPaused
        returns (uint256)
    {
        return super.mint(shares, receiver);
    }

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

    /**
     * @inheritdoc ERC4626Upgradeable
     * @dev Returns 0 while paused so integrators do not assume deposits are open (FIND-002).
     */
    function maxDeposit(address receiver) public view override returns (uint256) {
        if (paused()) return 0;
        return super.maxDeposit(receiver);
    }

    /**
     * @inheritdoc ERC4626Upgradeable
     * @dev See {maxDeposit}.
     */
    function maxMint(address receiver) public view override returns (uint256) {
        if (paused()) return 0;
        return super.maxMint(receiver);
    }

    /**
     * @inheritdoc ERC4626Upgradeable
     * @dev Direct withdraw is REDEEMER_ROLE-only (router/RFQ). EOAs and other integrators see 0.
     */
    function maxWithdraw(address owner) public view override returns (uint256) {
        if (paused()) return 0;
        if (!hasRole(REDEEMER_ROLE, _msgSender())) return 0;
        return convertToAssets(balanceOf(owner));
    }

    /**
     * @inheritdoc ERC4626Upgradeable
     * @dev See {maxWithdraw}.
     */
    function maxRedeem(address owner) public view override returns (uint256) {
        if (paused()) return 0;
        if (!hasRole(REDEEMER_ROLE, _msgSender())) return 0;
        return balanceOf(owner);
    }

    /**
     * @inheritdoc ERC4626Upgradeable
     * @dev Sync vaults: on-chain asset balance.
     *      Reported-inventory vaults: operator NAV converted to asset units (§05).
     *      Before first `updateNAV` (`!navInitialized`): returns 0 (catalog/Z2 gate).
     */
    function totalAssets() public view override returns (uint256) {
        if (!reportedInventoryOnly) {
            return IERC20(asset()).balanceOf(address(this));
        }
        if (settlementEngine == address(0)) revert ReportedNavNotConfigured();

        INavReader settlement = INavReader(settlementEngine);
        if (!settlement.navInitialized(vaultId)) return 0;

        INavReader.NAVComponents memory n = settlement.getNav(vaultId);
        uint256 spot = n.assetSpotPrice;
        if (spot == 0) return n.assetInInventory + n.assetInTransit;

        uint256 settlementSide = n.retainedEarnings + n.stablecoinBalance;
        uint256 netSettlement = settlementSide > n.liabilities
            ? settlementSide - n.liabilities
            : 0;

        uint8 oracleDecimals = assetOracle.decimals();
        uint8 assetDecimals_ = IERC20Metadata(asset()).decimals();
        uint8 settlementDecimals_ = IERC20Metadata(address(settlementToken)).decimals();

        uint256 fromSettlement = VaultLib.settlementToAssetAmount(
            netSettlement,
            spot,
            assetDecimals_,
            oracleDecimals,
            settlementDecimals_
        );

        return n.assetInInventory + n.assetInTransit + fromSettlement;
    }

    /**
     * @inheritdoc ERC4626Upgradeable
     * @dev Empty vaults price their first shares from the oracle-implied
     *      settlement value, avoiding inflated first-user shares from the
     *      ERC-4626 virtual offset. Reported-inventory vaults keep
     *      `totalAssets() == 0` until the first operator NAV, so they keep using
     *      this bootstrap rate until NAV is initialized.
     */
    function _convertToShares(
        uint256 assets,
        Math.Rounding rounding
    ) internal view override returns (uint256) {
        if (_usesOracleBootstrapRate()) {
            return _assetsToBootstrapShares(assets, rounding);
        }
        return super._convertToShares(assets, rounding);
    }

    /**
     * @inheritdoc ERC4626Upgradeable
     * @dev Mirror of {_convertToShares} for previews and share value reads
     *      before the first reported NAV.
     */
    function _convertToAssets(
        uint256 shares,
        Math.Rounding rounding
    ) internal view override returns (uint256) {
        if (_usesOracleBootstrapRate()) {
            return _bootstrapSharesToAssets(shares, rounding);
        }
        return super._convertToAssets(shares, rounding);
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

        uint8 oracleDecimals = assetOracle.decimals();
        uint8 assetDecimals = IERC20Metadata(asset()).decimals();
        uint8 settlementDecimals = IERC20Metadata(address(settlementToken)).decimals();

        uint256 settlementValue = VaultLib.assetToSettlementAmount(
            assetAmount,
            assetPrice,
            assetDecimals,
            oracleDecimals,
            settlementDecimals
        );
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

        uint8 oracleDecimals = assetOracle.decimals();
        uint8 assetDecimals = IERC20Metadata(asset()).decimals();
        uint8 settlementDecimals = IERC20Metadata(address(settlementToken)).decimals();

        uint256 assetAmount = VaultLib.settlementToAssetAmount(
            settlementValue,
            assetPrice,
            assetDecimals,
            oracleDecimals,
            settlementDecimals
        );
        shares = convertToShares(assetAmount);
    }

    function _usesOracleBootstrapRate() internal view returns (bool) {
        if (totalSupply() == 0) return true;
        if (!reportedInventoryOnly) return false;
        if (settlementEngine == address(0)) revert ReportedNavNotConfigured();
        return !INavReader(settlementEngine).navInitialized(vaultId);
    }

    function _assetsToBootstrapShares(
        uint256 assets,
        Math.Rounding rounding
    ) internal view returns (uint256) {
        uint256 settlementValue = _assetToSettlementAmount(assets, rounding);
        uint8 settlementDecimals_ = IERC20Metadata(address(settlementToken)).decimals();
        return _scaleDecimals(
            settlementValue,
            settlementDecimals_,
            VaultLib.VAULT_SHARE_DECIMALS,
            rounding
        );
    }

    function _bootstrapSharesToAssets(
        uint256 shares,
        Math.Rounding rounding
    ) internal view returns (uint256) {
        uint8 settlementDecimals_ = IERC20Metadata(address(settlementToken)).decimals();
        uint256 settlementValue = _scaleDecimals(
            shares,
            VaultLib.VAULT_SHARE_DECIMALS,
            settlementDecimals_,
            rounding
        );
        return _settlementToAssetAmount(settlementValue, rounding);
    }

    function _assetToSettlementAmount(
        uint256 assetAmount,
        Math.Rounding rounding
    ) internal view returns (uint256) {
        uint256 assetPrice = getAssetPrice();
        if (assetPrice == 0) revert InvalidAssetPrice();

        uint8 oracleDecimals = assetOracle.decimals();
        uint8 assetDecimals_ = IERC20Metadata(asset()).decimals();
        uint8 settlementDecimals_ = IERC20Metadata(address(settlementToken)).decimals();

        return assetAmount.mulDiv(
            assetPrice * 10 ** uint256(settlementDecimals_),
            10 ** uint256(assetDecimals_) * 10 ** uint256(oracleDecimals),
            rounding
        );
    }

    function _settlementToAssetAmount(
        uint256 settlementAmount,
        Math.Rounding rounding
    ) internal view returns (uint256) {
        uint256 assetPrice = getAssetPrice();
        if (assetPrice == 0) revert InvalidAssetPrice();

        uint8 oracleDecimals = assetOracle.decimals();
        uint8 assetDecimals_ = IERC20Metadata(asset()).decimals();
        uint8 settlementDecimals_ = IERC20Metadata(address(settlementToken)).decimals();

        return settlementAmount.mulDiv(
            10 ** uint256(oracleDecimals) * 10 ** uint256(assetDecimals_),
            assetPrice * 10 ** uint256(settlementDecimals_),
            rounding
        );
    }

    function _scaleDecimals(
        uint256 amount,
        uint8 fromDecimals,
        uint8 toDecimals,
        Math.Rounding rounding
    ) internal pure returns (uint256) {
        if (fromDecimals == toDecimals) return amount;
        if (fromDecimals < toDecimals) {
            return amount * 10 ** uint256(toDecimals - fromDecimals);
        }
        return amount.mulDiv(1, 10 ** uint256(fromDecimals - toDecimals), rounding);
    }

    // ─────────────────────────── ADMIN ──────────────────────────────────────

    /// @notice Replace the asset price oracle. Must implement IAssetOracle with 8-decimal prices.
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

    /**
     * @notice Wire Settlement + vaultId for reported-inventory accounting.
     * @dev Called by VaultFactory right after registry assignment (before ownership transfer).
     */
    function configureReportedNav(
        address settlementEngine_,
        uint256 vaultId_,
        bool reportedInventoryOnly_
    ) external onlyOwner {
        if (reportedInventoryOnly_ && settlementEngine_ == address(0)) revert InvalidAddress();
        if (vaultId_ == 0) revert InvalidAmount();
        settlementEngine = settlementEngine_;
        vaultId = vaultId_;
        reportedInventoryOnly = reportedInventoryOnly_;
        emit ReportedNavConfigured(settlementEngine_, vaultId_, reportedInventoryOnly_);
    }

    function pause()   external onlyOwner { _pause();   }
    function unpause() external onlyOwner { _unpause(); }

    /**
     * @inheritdoc ERC4626Upgradeable
     * @dev Empty-vault pricing is handled by the oracle bootstrap conversion,
     *      so no extra decimal offset is needed.
     */
    function _decimalsOffset() internal pure override returns (uint8) {
        return 0;
    }

    /// @dev Only the owner (vault issuer admin) may authorize an implementation upgrade.
    function _authorizeUpgrade(address) internal override onlyOwner {}

    /// @dev 6 decimal shares align with 6-decimal settlement tokens (e.g. USDC, USDT) as the primary pricing unit.
    function decimals() public pure override returns (uint8) { return 6; }

    /// @dev Reduced by 3 for settlementEngine, vaultId, reportedInventoryOnly.
    uint256[41] private __gap;
}
