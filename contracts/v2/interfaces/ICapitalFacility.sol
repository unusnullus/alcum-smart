// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/**
 * @title ICapitalFacility
 * @notice Per-vault stablecoin liquidity buffer that earns yield on idle capital.
 *
 * @dev Committed capital may be deployed into whitelisted DeFi protocols between
 *      settlement events. When a redemption obligation is triggered, capital must
 *      be recalled before the payout is approved.
 *
 *      Invariant: primary obligation (redemption liquidity) always takes precedence
 *      over secondary benefit (yield). Operators must ensure sufficient idle balance
 *      before any redemption approval.
 */
interface ICapitalFacility {

    struct Deployment {
        address protocol;    // whitelisted yield protocol
        uint256 amount;      // stablecoin amount deployed
        uint256 deployedAt;  // unix timestamp
        bytes   data;        // protocol-specific calldata
    }

    event CapitalDeployed(address indexed protocol, uint256 amount);
    event CapitalRecalled(address indexed protocol, uint256 amount);
    event ProtocolWhitelisted(address indexed protocol, bool whitelisted);

    /// @notice Stablecoin balance held in this contract (not deployed externally).
    function idleBalance() external view returns (uint256);

    /// @notice Total stablecoin controlled by this facility (idle + deployed).
    function totalBalance() external view returns (uint256);

    /// @notice Stablecoin currently deployed in a specific protocol.
    function deployedIn(address protocol) external view returns (uint256);

    /// @notice Deploy `amount` stablecoin into a whitelisted yield protocol.
    function deployCapital(address protocol, uint256 amount, bytes calldata data) external;

    /// @notice Recall `amount` stablecoin from a deployed protocol.
    function recallCapital(address protocol, uint256 amount) external;

    /// @notice Emergency: recall all deployed capital across all protocols.
    function recallAll() external;
}
