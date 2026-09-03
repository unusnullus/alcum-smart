// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/**
 * @title ICommittedLiquidityRouter
 * @notice Read-only surface for per-vault settlement liquidity commitments tracked by OpenLiquidityRouter.
 */
interface ICommittedLiquidityRouter {
    /// @notice Settlement tokens reserved for pending deposits and approved unclaimed redeems.
    function getCommittedLiability(uint256 vaultId) external view returns (uint256);

    /// @notice Idle facility balance minus committed liability (floored at zero).
    function getAvailableIdle(uint256 vaultId) external view returns (uint256);
}
