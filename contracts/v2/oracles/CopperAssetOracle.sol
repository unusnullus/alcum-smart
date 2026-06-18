// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {IAssetOracle} from "../interfaces/IAssetOracle.sol";
import {ICopperPriceConsumer} from "../../interfaces/ICopperPriceConsumer.sol";

/**
 * @title CopperAssetOracle
 * @notice Adapter that exposes a Chainlink-backed copper price feed through the
 *         generic IAssetOracle interface.
 *
 * @dev Price convention: 8 decimal places (Chainlink USD standard).
 *      Example: copper at $4.50 → 450_000_000.
 *
 *      When the underlying feed returns 0 or when `useFallback` is true, the
 *      manually configured fallback price is returned instead. This allows
 *      operators to maintain protocol functionality during oracle outages.
 *
 *      The same adapter pattern can be applied to any v1 price consumer that
 *      does not natively implement IAssetOracle.
 */
contract CopperAssetOracle is IAssetOracle, AccessControl {

    bytes32 public constant ORACLE_ADMIN_ROLE = keccak256("ORACLE_ADMIN_ROLE");

    ICopperPriceConsumer public underlying;

    /// @notice Emergency fallback price (8 decimals). Active when `useFallback` is true
    ///         or when the underlying feed returns zero.
    uint256 public fallbackPrice;

    /// @notice Timestamp of the last manual fallback price update.
    uint256 public fallbackUpdatedAt;

    /// @notice When true, `price()` always returns `fallbackPrice` regardless of the feed.
    bool public useFallback;

    event UnderlyingUpdated(address indexed oldUnderlying, address indexed newUnderlying);
    event FallbackPriceSet(uint256 oldPrice, uint256 newPrice, address indexed by);
    event UseFallbackToggled(bool useFallback);

    error ZeroAddress();
    error ZeroPrice();

    constructor(address underlying_, address admin_) {
        if (underlying_ == address(0)) revert ZeroAddress();
        if (admin_      == address(0)) revert ZeroAddress();

        underlying = ICopperPriceConsumer(underlying_);
        _grantRole(DEFAULT_ADMIN_ROLE, admin_);
        _grantRole(ORACLE_ADMIN_ROLE, admin_);
    }

    // ─────────────────────────── IAssetOracle ───────────────────────────────

    /// @inheritdoc IAssetOracle
    function price() external view override returns (uint256) {
        if (useFallback) return fallbackPrice;
        uint256 p = underlying.price();
        return p == 0 ? fallbackPrice : p;
    }

    /// @inheritdoc IAssetOracle
    function decimals() external pure override returns (uint8) {
        return 8;
    }

    /// @inheritdoc IAssetOracle
    function description() external pure override returns (string memory) {
        return "Copper / USD";
    }

    /// @inheritdoc IAssetOracle
    function updatedAt() external view override returns (uint256) {
        if (useFallback) return fallbackUpdatedAt;
        // ICopperPriceConsumer does not expose updatedAt; approximate with the
        // last manual fallback update, falling back to the current block timestamp.
        return fallbackUpdatedAt > 0 ? fallbackUpdatedAt : block.timestamp;
    }

    // ─────────────────────────── ADMIN ──────────────────────────────────────

    /// @notice Replace the underlying price consumer (e.g. after a Chainlink feed migration).
    function setUnderlying(address newUnderlying) external onlyRole(ORACLE_ADMIN_ROLE) {
        if (newUnderlying == address(0)) revert ZeroAddress();
        emit UnderlyingUpdated(address(underlying), newUnderlying);
        underlying = ICopperPriceConsumer(newUnderlying);
    }

    /// @notice Set the emergency fallback price.
    /// @dev Should be kept in sync with the live market price to minimise
    ///      price discontinuity when toggling fallback mode.
    function setFallbackPrice(uint256 newPrice) external onlyRole(ORACLE_ADMIN_ROLE) {
        if (newPrice == 0) revert ZeroPrice();
        emit FallbackPriceSet(fallbackPrice, newPrice, msg.sender);
        fallbackPrice     = newPrice;
        fallbackUpdatedAt = block.timestamp;
    }

    /// @notice Toggle forced fallback mode. When enabled, the live feed is bypassed.
    function setUseFallback(bool flag) external onlyRole(ORACLE_ADMIN_ROLE) {
        useFallback = flag;
        emit UseFallbackToggled(flag);
    }
}
