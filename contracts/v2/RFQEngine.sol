// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import {ReentrancyGuardUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";

import {IRFQEngine} from "./interfaces/IRFQEngine.sol";
import {VaultRegistry} from "./VaultRegistry.sol";
import {VaultLib} from "./libraries/VaultLib.sol";

/**
 * @title RFQEngine
 * @notice On-chain Request-For-Quote (RFQ) settlement layer for T+0 instant liquidity.
 *
     * @dev Settlement flow (single transaction, no counterparty risk):
     *      1. User calls createRFQ() — shares are locked in this contract.
     *      2. A registered market maker calls fillRFQ() — settlement tokens are atomically
     *         transferred to the user and locked shares are transferred to the market maker.
     *      3. The market maker may hold shares to earn yield or queue a standard redemption.
     *
     *      Security properties:
     *      - Checks-Effects-Interactions: state is finalised before any external call.
     *      - Expiry prevents stale RFQs from being filled after the user's deadline.
     *      - Only the original requester may cancel their RFQ.
     *      - minSettlementToken enforces a user-defined minimum price (slippage protection).
 *      - All state-changing paths are protected by ReentrancyGuard.
 *
 *      Market maker whitelisting (MARKET_MAKER_ROLE) maps to off-chain KYC/KYB.
 *      Admin manages the whitelist via registerMarketMaker().
 */
contract RFQEngine is
    Initializable,
    OwnableUpgradeable,
    AccessControlUpgradeable,
    PausableUpgradeable,
    ReentrancyGuardUpgradeable,
    UUPSUpgradeable,
    IRFQEngine
{
    using SafeERC20 for IERC20;

    // ─────────────────────────── ROLES ──────────────────────────────────────

    /// @notice Registered market makers that may fill RFQs.
    bytes32 public constant MARKET_MAKER_ROLE = keccak256("MARKET_MAKER_ROLE");

    // ─────────────────────────── STATE ──────────────────────────────────────

    VaultRegistry public registry;

    /// @dev rfqId → RFQRequest.
    mapping(bytes32 => RFQRequest) private _rfqs;

    /// @dev Per-user nonce for deterministic rfqId generation.
    mapping(address => uint256) private _nonces;

    /// @notice Active (unfilled, non-cancelled) RFQ identifiers for off-chain indexers.
    bytes32[] public activeRFQs;

    // ─────────────────────────── ERRORS ─────────────────────────────────────

    error ZeroAddress();
    error ZeroShares();
    error ZeroMinSettlementToken();
    error InvalidExpiry();
    error RFQNotFound(bytes32 rfqId);
    error RFQAlreadyFilled(bytes32 rfqId);
    error RFQAlreadyCancelled(bytes32 rfqId);
    error RFQExpired(bytes32 rfqId);
    error NotRFQOwner();
    error BelowMinSettlementToken(uint256 offered, uint256 required);
    error VaultNotActive(uint256 vaultId);

    // ─────────────────────────── INIT ───────────────────────────────────────

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(address registry_, address admin_) public initializer {
        if (registry_ == address(0)) revert ZeroAddress();
        if (admin_ == address(0)) revert ZeroAddress();

        __Ownable_init(admin_);
        __AccessControl_init();
        __Pausable_init();
        __ReentrancyGuard_init();
        __UUPSUpgradeable_init();

        _grantRole(DEFAULT_ADMIN_ROLE, admin_);

        registry = VaultRegistry(registry_);
    }

    // ─────────────────────────── USER ACTIONS ───────────────────────────────

    /**
     * @notice Lock vault shares and broadcast an instant-liquidity redemption request.
     * @param vaultId           Registry ID of the vault the shares belong to.
     * @param shares            Amount of vault shares to sell.
     * @param minSettlementToken Minimum settlement token payout the user will accept (slippage protection).
     * @param expiry            Unix timestamp after which this RFQ may not be filled.
     * @return rfqId            Deterministic identifier derived from (user, nonce, vaultId, timestamp).
     */
    function createRFQ(
        uint256 vaultId,
        uint256 shares,
        uint256 minSettlementToken,
        uint256 expiry
    ) external override nonReentrant whenNotPaused returns (bytes32 rfqId) {
        if (shares == 0) revert ZeroShares();
        if (minSettlementToken == 0) revert ZeroMinSettlementToken();
        if (expiry <= block.timestamp) revert InvalidExpiry();
        if (!registry.isActive(vaultId)) revert VaultNotActive(vaultId);

        VaultLib.VaultRecord memory v = registry.getVault(vaultId);

        rfqId = keccak256(abi.encodePacked(msg.sender, _nonces[msg.sender]++, vaultId, block.timestamp));

        IERC20(v.vault).safeTransferFrom(msg.sender, address(this), shares);

        _rfqs[rfqId] = RFQRequest({
            rfqId:              rfqId,
            requester:          msg.sender,
            vaultId:            vaultId,
            shares:             shares,
            minSettlementToken: minSettlementToken,
            expiry:             expiry,
            filled:             false,
            cancelled:          false,
            filledBy:           address(0),
            tokenReceived:      0
        });

        activeRFQs.push(rfqId);

        emit RFQCreated(rfqId, msg.sender, vaultId, shares, minSettlementToken, expiry);
    }

    /**
     * @notice Cancel an unfilled RFQ and recover locked shares.
     * @dev Only the original requester may cancel. Callable even after expiry.
     */
    function cancelRFQ(bytes32 rfqId) external override nonReentrant whenNotPaused {
        RFQRequest storage r = _rfqs[rfqId];

        if (r.requester == address(0)) revert RFQNotFound(rfqId);
        if (r.filled) revert RFQAlreadyFilled(rfqId);
        if (r.cancelled) revert RFQAlreadyCancelled(rfqId);
        if (r.requester != msg.sender) revert NotRFQOwner();

        r.cancelled = true;
        _removeActiveRFQ(rfqId);

        VaultLib.VaultRecord memory v = registry.getVault(r.vaultId);
        IERC20(v.vault).safeTransfer(r.requester, r.shares);

        emit RFQCancelled(rfqId);
    }

    // ─────────────────────────── MARKET MAKER ACTIONS ───────────────────────

    /**
     * @notice Atomically swap settlement tokens for the locked vault shares of an open RFQ.
     * @dev State is finalised before external transfers (CEI pattern).
     *      Transfer order: settlement tokens from market maker → requester, then shares → market maker.
     * @param rfqId       Identifier of the RFQ to fill.
     * @param tokenAmount Settlement token amount the market maker offers. Must be ≥ minSettlementToken.
     */
    function fillRFQ(
        bytes32 rfqId,
        uint256 tokenAmount
    ) external override onlyRole(MARKET_MAKER_ROLE) nonReentrant whenNotPaused {
        RFQRequest storage r = _rfqs[rfqId];

        if (r.requester == address(0)) revert RFQNotFound(rfqId);
        if (r.filled) revert RFQAlreadyFilled(rfqId);
        if (r.cancelled) revert RFQAlreadyCancelled(rfqId);
        if (block.timestamp > r.expiry) revert RFQExpired(rfqId);
        if (tokenAmount < r.minSettlementToken) revert BelowMinSettlementToken(tokenAmount, r.minSettlementToken);

        VaultLib.VaultRecord memory v = registry.getVault(r.vaultId);

        r.filled = true;
        r.filledBy = msg.sender;
        r.tokenReceived = tokenAmount;

        _removeActiveRFQ(rfqId);

        IERC20(v.settlementToken).safeTransferFrom(msg.sender, r.requester, tokenAmount);
        IERC20(v.vault).safeTransfer(msg.sender, r.shares);

        emit RFQFilled(rfqId, msg.sender, tokenAmount, r.shares);
    }

    // ─────────────────────────── VIEWS ──────────────────────────────────────

    function getRFQ(bytes32 rfqId) external view override returns (RFQRequest memory) {
        return _rfqs[rfqId];
    }

    function isRegisteredMM(address mm) external view override returns (bool) {
        return hasRole(MARKET_MAKER_ROLE, mm);
    }

    function getActiveRFQCount() external view returns (uint256) {
        return activeRFQs.length;
    }

    /// @notice Paginated view over the active RFQ list for off-chain indexers.
    function getActiveRFQsPaginated(uint256 offset, uint256 limit) external view returns (bytes32[] memory page) {
        uint256 total = activeRFQs.length;
        if (offset >= total) return new bytes32[](0);

        uint256 end = offset + limit > total ? total : offset + limit;
        page = new bytes32[](end - offset);
        for (uint256 i = offset; i < end; i++) {
            page[i - offset] = activeRFQs[i];
        }
    }

    // ─────────────────────────── ADMIN ──────────────────────────────────────

    /// @notice Grant or revoke MARKET_MAKER_ROLE. KYC/KYB is managed off-chain.
    function registerMarketMaker(address mm, bool active) external onlyOwner {
        if (mm == address(0)) revert ZeroAddress();
        if (active) {
            _grantRole(MARKET_MAKER_ROLE, mm);
        } else {
            _revokeRole(MARKET_MAKER_ROLE, mm);
        }
        emit MarketMakerRegistered(mm, active);
    }

    function pause() external onlyOwner {
        _pause();
    }
    function unpause() external onlyOwner {
        _unpause();
    }

    // ─────────────────────────── INTERNAL ───────────────────────────────────

    function _removeActiveRFQ(bytes32 rfqId) internal {
        bytes32[] storage arr = activeRFQs;
        for (uint256 i; i < arr.length; i++) {
            if (arr[i] == rfqId) {
                arr[i] = arr[arr.length - 1];
                arr.pop();
                return;
            }
        }
    }

    function _authorizeUpgrade(address) internal override onlyOwner {}

    uint256[44] private __gap;
}
