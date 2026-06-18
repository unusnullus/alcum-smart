// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/**
 * @title IFeeDistributor
 * @notice Pluggable module for on-chain fee routing.
 *
 * @dev SharedSettlementEngine transfers the system-fee slice to this contract
 *      instead of hard-coding a single treasury address. Implementations may
 *      split fees across multiple recipients, trigger buybacks, add to
 *      protocol-owned liquidity, or perform any other fee-routing logic.
 *
 *      The caller must approve this contract for `amount` of `token` before calling
 *      distribute(). The implementation is responsible for pulling the funds.
 */
interface IFeeDistributor {
    /**
     * @notice Route `amount` of `token` according to the configured distribution rules.
     * @param token  ERC-20 token to distribute (typically USDC).
     * @param amount Total amount to distribute.
     */
    function distribute(address token, uint256 amount) external;

    /// @notice Human-readable description of this distributor's routing logic.
    function description() external view returns (string memory);
}
