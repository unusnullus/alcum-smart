// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {ERC20Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC20} from "@openzeppelin/contracts/interfaces/IERC20.sol";
import {IXCUPPriceView} from "./interfaces/IXCUPPriceView.sol";

/**
 * @title XCUP/USDC Oracle-Priced Pool
 * @notice AMM where execution uses xCUP external price (USDC assumed 1:1 USD).
 * Liquidity accounting and LP minting are done by USD value contribution to keep
 * fair shares even with oracle-based pricing.
 */
contract XCUPOraclePool is ERC20Upgradeable, PausableUpgradeable, OwnableUpgradeable {
    using SafeERC20 for IERC20;

    uint256 internal constant MAX_FEE = 500; // in bps
    uint256 internal constant BASIS_POINTS = 10_000;

    uint16 public swapFee; // in bps

    IERC20 public xcup;
    IERC20 public usdc;

    event LiquidityAdded(address indexed user, uint256 xcupAmount, uint256 usdcAmount, uint256 lpTokens);
    event LiquidityRemoved(address indexed user, uint256 lpTokens, uint256 xcupAmount, uint256 usdcAmount);
    event Swapped(address indexed user, address indexed inToken, uint256 inAmount, uint256 outAmount);
    event FeeUpdated(uint256 oldFee, uint256 newFee);

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(address _xcup, address _usdc) public initializer {
        __ERC20_init("XCUP/USDC LP", "XCUP-ORACLE-LP");
        __Pausable_init();
        __Ownable_init(msg.sender);
        xcup = IERC20(_xcup);
        usdc = IERC20(_usdc);
        swapFee = 50;
    }

    function getReserves() public view returns (uint256 reserveXCUP, uint256 reserveUSDC) {
        reserveXCUP = xcup.balanceOf(address(this));
        reserveUSDC = usdc.balanceOf(address(this));
    }

    // ---------- Pricing ----------
    function _xcupPriceInUSDC(uint256 xcupAmount) internal view returns (uint256) {
        if (xcupAmount == 0) return 0;
        return IXCUPPriceView(address(xcup)).getXcupPriceInToken(address(usdc), xcupAmount);
    }

    function getAdjustedPrice(address baseToken, address quoteToken) external view returns (uint256) {
        require(
            (baseToken == address(xcup) && quoteToken == address(usdc)) ||
                (baseToken == address(usdc) && quoteToken == address(xcup)),
            "XCUPOraclePool: invalid pair"
        );
        if (baseToken == address(xcup)) {
            return _xcupPriceInUSDC(1_000_000); // 1 xCUP (6 decimals) in USDC (6 decimals)
        } else {
            // price of 1 USDC in xCUP units
            uint256 usdcInX = IXCUPPriceView(address(xcup)).getTokenToXcupExchangeRate(address(usdc), 1_000_000);
            return usdcInX; // xCUP units per 1 USDC
        }
    }

    // ---------- Liquidity (USD-based shares) ----------
    function _usdValue(uint256 xAmount, uint256 uAmount) internal view returns (uint256) {
        return _xcupPriceInUSDC(xAmount) + uAmount; // both in USDC units (6)
    }

    function addLiquidity(
        uint256 xcupDesired,
        uint256 usdcDesired
    ) external whenNotPaused returns (uint256 xcupAdded, uint256 usdcAdded, uint256 lpMinted) {
        require(xcupDesired > 0 || usdcDesired > 0, "XCUPOraclePool: zero desired");

        (uint256 rX, uint256 rU) = getReserves();
        uint256 ts = totalSupply();

        if (xcupDesired == 0 || usdcDesired == 0) {
            // Single-sided add: accept provided side as-is
            xcupAdded = xcupDesired;
            usdcAdded = usdcDesired;

            if (xcupAdded > 0) {
                xcup.safeTransferFrom(msg.sender, address(this), xcupAdded);
            }
            if (usdcAdded > 0) {
                usdc.safeTransferFrom(msg.sender, address(this), usdcAdded);
            }

            uint256 usdAdded = _usdValue(xcupAdded, usdcAdded);
            if (ts == 0) {
                // first LP: mint by USD value directly
                lpMinted = usdAdded;
            } else {
                uint256 usdPool = _usdValue(rX, rU);
                lpMinted = (usdAdded * ts) / usdPool;
            }
        } else {
            // Dual-sided: trim to oracle USD ratio
            uint256 oraclePrice = _xcupPriceInUSDC(1_000_000); // USDC per 1 xCUP
            uint256 requiredU = (xcupDesired * oraclePrice) / 1_000_000;
            if (requiredU <= usdcDesired) {
                xcupAdded = xcupDesired;
                usdcAdded = requiredU;
            } else {
                xcupAdded = (usdcDesired * 1_000_000) / oraclePrice;
                usdcAdded = usdcDesired;
            }

            xcup.safeTransferFrom(msg.sender, address(this), xcupAdded);
            usdc.safeTransferFrom(msg.sender, address(this), usdcAdded);

            uint256 usdAdded = _usdValue(xcupAdded, usdcAdded);
            if (ts == 0) {
                lpMinted = usdAdded;
            } else {
                uint256 usdPool = _usdValue(rX, rU);
                lpMinted = (usdAdded * ts) / usdPool;
            }
        }

        require(lpMinted > 0, "XCUPOraclePool: LP 0");
        _mint(msg.sender, lpMinted);
        emit LiquidityAdded(msg.sender, xcupAdded, usdcAdded, lpMinted);
    }

    function removeLiquidity(
        uint256 lpAmount
    ) external whenNotPaused returns (uint256 xcupReturned, uint256 usdcReturned) {
        require(lpAmount > 0, "XCUPOraclePool: zero LP");
        uint256 ts = totalSupply();
        (uint256 rX, uint256 rU) = getReserves();
        require(rX > 0 || rU > 0, "XCUPOraclePool: empty");

        xcupReturned = (rX * lpAmount) / ts;
        usdcReturned = (rU * lpAmount) / ts;

        _burn(msg.sender, lpAmount);
        if (xcupReturned > 0) xcup.safeTransfer(msg.sender, xcupReturned);
        if (usdcReturned > 0) usdc.safeTransfer(msg.sender, usdcReturned);
        emit LiquidityRemoved(msg.sender, lpAmount, xcupReturned, usdcReturned);
    }

    // ---------- Swaps (oracle-priced exact-in) ----------
    function swapExactXCUPToUSDC(uint256 xcupAmountIn, uint256 minUSDCOut) external whenNotPaused {
        require(xcupAmountIn > 0, "XCUPOraclePool: zero in");
        (, uint256 rU) = getReserves();
        uint256 amountInWithFee = (xcupAmountIn * (BASIS_POINTS - swapFee)) / BASIS_POINTS;
        uint256 quote = _xcupPriceInUSDC(amountInWithFee);
        uint256 usdcOut = quote > rU ? rU : quote; // can't exceed reserves
        require(usdcOut >= minUSDCOut && usdcOut > 0, "XCUPOraclePool: slippage");
        xcup.safeTransferFrom(msg.sender, address(this), xcupAmountIn);
        usdc.safeTransfer(msg.sender, usdcOut);
        emit Swapped(msg.sender, address(xcup), xcupAmountIn, usdcOut);
    }

    function swapExactUSDCToXCUP(uint256 usdcAmountIn, uint256 minXCUPOut) external whenNotPaused {
        require(usdcAmountIn > 0, "XCUPOraclePool: zero in");
        (uint256 rX, ) = getReserves();
        uint256 amountInWithFee = (usdcAmountIn * (BASIS_POINTS - swapFee)) / BASIS_POINTS;
        uint256 xcupOut = IXCUPPriceView(address(xcup)).getTokenToXcupExchangeRate(address(usdc), amountInWithFee);
        if (xcupOut > rX) xcupOut = rX;
        require(xcupOut >= minXCUPOut && xcupOut > 0, "XCUPOraclePool: slippage");
        usdc.safeTransferFrom(msg.sender, address(this), usdcAmountIn);
        xcup.safeTransfer(msg.sender, xcupOut);
        emit Swapped(msg.sender, address(usdc), usdcAmountIn, xcupOut);
    }

    // ---------- Admin ----------
    function setSwapFee(uint16 newFee) external onlyOwner {
        require(newFee <= MAX_FEE, "XCUPOraclePool: fee too high");
        uint256 old = swapFee;
        swapFee = newFee;
        emit FeeUpdated(old, newFee);
    }

    function pause() external onlyOwner {
        _pause();
    }
    function unpause() external onlyOwner {
        _unpause();
    }

    // ---------- Metadata ----------
    function decimals() public pure override returns (uint8) {
        return 6;
    }

    // ---------- Preview/View helpers ----------

    /**
     * @notice Preview what amounts will actually be added and LP minted.
     * @dev Same logic as addLiquidity but view-only (no state changes).
     */
    function previewAddLiquidity(
        uint256 xcupDesired,
        uint256 usdcDesired
    ) external view returns (uint256 xcupToAdd, uint256 usdcToAdd, uint256 lpToMint) {
        require(xcupDesired > 0 || usdcDesired > 0, "XCUPOraclePool: zero desired");

        (uint256 rX, uint256 rU) = getReserves();
        uint256 ts = totalSupply();

        if (xcupDesired == 0 || usdcDesired == 0) {
            // Single-sided
            xcupToAdd = xcupDesired;
            usdcToAdd = usdcDesired;

            uint256 usdAdded = _usdValue(xcupToAdd, usdcToAdd);
            if (ts == 0) {
                lpToMint = usdAdded;
            } else {
                uint256 usdPool = _usdValue(rX, rU);
                lpToMint = (usdAdded * ts) / usdPool;
            }
        } else {
            // Dual-sided: trim to oracle ratio
            uint256 oraclePrice = _xcupPriceInUSDC(1_000_000);
            uint256 requiredU = (xcupDesired * oraclePrice) / 1_000_000;
            if (requiredU <= usdcDesired) {
                xcupToAdd = xcupDesired;
                usdcToAdd = requiredU;
            } else {
                xcupToAdd = (usdcDesired * 1_000_000) / oraclePrice;
                usdcToAdd = usdcDesired;
            }

            uint256 usdAdded = _usdValue(xcupToAdd, usdcToAdd);
            if (ts == 0) {
                lpToMint = usdAdded;
            } else {
                uint256 usdPool = _usdValue(rX, rU);
                lpToMint = (usdAdded * ts) / usdPool;
            }
        }
    }
}
