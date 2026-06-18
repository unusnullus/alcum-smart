// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/**
 * @title IAssetOracle
 * @notice Generic price oracle interface for any tokenized real-world asset.
 * @dev Implementations may wrap Chainlink, Redstone, Pyth, or any other feed.
 *      Price convention: 8 decimal places (aligned with Chainlink USD feeds).
 *      Example: $4.50 → 450_000_000.
 */
interface IAssetOracle {
    /// @notice Current asset price expressed with `decimals()` precision.
    function price() external view returns (uint256);

    /// @notice Number of decimal places used by `price()`. Typically 8.
    function decimals() external view returns (uint8);

    /// @notice Human-readable description of the priced asset (e.g. "Copper / USD").
    function description() external view returns (string memory);

    /// @notice Unix timestamp of the most recent price update.
    function updatedAt() external view returns (uint256);
}
