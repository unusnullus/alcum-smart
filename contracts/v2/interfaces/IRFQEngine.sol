// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/**
 * @title IRFQEngine
 * @notice On-chain Request-For-Quote settlement layer for T+0 instant liquidity.
 *
 * @dev Settlement flow (single transaction, no counterparty risk):
 *      1. User locks vault shares via createRFQ().
 *      2. A registered market maker calls fillRFQ() — atomically delivering settlement
 *         tokens to the user and receiving vault shares in return.
 *      3. The market maker may hold shares to earn yield or queue a standard redemption.
 *
 *      minSettlementToken enforces a user-defined minimum acceptable price (slippage protection).
 *      Expiry prevents stale RFQs from being filled after the user's desired window.
 */
interface IRFQEngine {

    struct RFQRequest {
        bytes32 rfqId;
        address requester;
        uint256 vaultId;
        uint256 shares;
        uint256 minSettlementToken; // minimum settlement token amount the user will accept
        uint256 expiry;
        bool    filled;
        bool    cancelled;
        address filledBy;
        uint256 tokenReceived;      // actual settlement token amount received when filled
    }

    event RFQCreated(
        bytes32 indexed rfqId,
        address indexed requester,
        uint256 vaultId,
        uint256 shares,
        uint256 minSettlementToken,
        uint256 expiry
    );
    event RFQFilled(
        bytes32 indexed rfqId,
        address indexed marketMaker,
        uint256 tokenAmount,
        uint256 shares
    );
    event RFQCancelled(bytes32 indexed rfqId);
    event MarketMakerRegistered(address indexed mm, bool active);

    /// @notice Lock shares and broadcast a redemption request.
    function createRFQ(
        uint256 vaultId,
        uint256 shares,
        uint256 minSettlementToken,
        uint256 expiry
    ) external returns (bytes32 rfqId);

    /// @notice Cancel an unfilled request and recover locked shares.
    function cancelRFQ(bytes32 rfqId) external;

    /// @notice Atomically swap settlement tokens for locked shares. `tokenAmount` must be ≥ minSettlementToken.
    function fillRFQ(bytes32 rfqId, uint256 tokenAmount) external;

    function getRFQ(bytes32 rfqId) external view returns (RFQRequest memory);
    function isRegisteredMM(address mm) external view returns (bool);
}
