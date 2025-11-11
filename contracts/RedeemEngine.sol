// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {ReentrancyGuardUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {IERC20Mintable} from "./interfaces/IERC20Mintable.sol";

import {ICopperPriceConsumer} from "./interfaces/ICopperPriceConsumer.sol";
import {Silo} from "./Silo.sol";
import {RedeemLib} from "./libraries/RedeemLib.sol";
import {RedeemViewLib} from "./libraries/RedeemViewLib.sol";

/**
 * @title RedeemEngine
 * @dev Manages the complete redemption flow: request → approve → claim.
 *      Uses a dedicated Silo contract for USDC management during redemptions.
 *      Supports both direct redemption (with commission) and request-based redemption (without commission).
 */
contract RedeemEngine is
    Initializable,
    AccessControlUpgradeable,
    OwnableUpgradeable,
    PausableUpgradeable,
    ReentrancyGuardUpgradeable
{
    using SafeERC20 for IERC20;

    /// @notice Role identifier for vault curators who can approve redeem requests
    bytes32 public constant VAULT_CURATOR_ROLE = keccak256("VAULT_CURATOR_ROLE");

    /// @notice CUP token contract
    IERC20 private _cup;

    /// @notice USDC token contract
    IERC20 private _usdc;

    /// @notice xCUP vault contract (ERC4626 compliant)
    IERC4626 private _vault;

    /// @notice Copper price oracle consumer
    ICopperPriceConsumer private _copperPriceConsumer;

    /// @notice Dedicated Silo contract for redeem operations
    Silo private _redeemSilo;

    /// @notice Zapper contract address (where CUP tokens are sent after redeem)
    address private _zapper;

    /// @notice Mapping of redeem IDs to redeem requests
    mapping(bytes32 => RedeemLib.RedeemRequest) private _redeems;

    /// @notice Array of pending redeem IDs awaiting curator approval
    bytes32[] private _pendingRedeemIds;

    /// @notice Mapping of user addresses to their redeem IDs
    mapping(address => bytes32[]) private _userRedeems;

    /// @notice Commission percentage for direct redeem operations (in basis points, e.g., 200 = 2%)
    uint256 private _redeemCommissionBps;

    // Reserve storage gap for future upgrades
    uint256[40] private __gap;

    /**
     * @notice Emitted when a redeem request is created
     */
    event RedeemRequested(address indexed user, bytes32 indexed redeemId, uint256 shares);

    /**
     * @notice Emitted when a redeem request is approved by curator
     */
    event RedeemApproved(bytes32 indexed redeemId, uint256 shares, uint256 usdcAmount);

    /**
     * @notice Emitted when a redeem request is claimed by user
     */
    event RedeemClaimed(address indexed user, bytes32 indexed redeemId, uint256 usdcAmount);

    /**
     * @notice Emitted when a direct redeem is executed (with commission)
     */
    event DirectRedeemExecuted(address indexed user, uint256 shares, uint256 usdcAmount, uint256 commissionAmount);

    /**
     * @notice Emitted when redeem commission is updated
     */
    event RedeemCommissionUpdated(uint256 newCommissionBps);

    /**
     * @notice Emitted when USDC is withdrawn from redeem silo
     */
    event RedeemSiloWithdrawn(address indexed to, uint256 amount);

    /**
     * @notice Emitted when a redeem request is cancelled by user
     */
    event RedeemCancelled(bytes32 indexed redeemId, address indexed user, uint256 shares);

    /**
     * @notice Emitted when a redeem request is declined by curator
     */
    event RedeemDeclined(bytes32 indexed redeemId, address indexed user, uint256 shares);

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /**
     * @notice Initializes the RedeemEngine contract
     * @param cup_ The address of the CUP token contract
     * @param usdc_ The address of the USDC token contract
     * @param vault_ The address of the xCUP vault contract (ERC4626)
     * @param copperPriceConsumer_ The address of the copper price oracle consumer
     * @param zapper_ The address of the Zapper contract (where CUP tokens are sent after redeem)
     * @param redeemCommissionBps_ Initial commission rate in basis points (e.g., 200 = 2%)
     */
    function initialize(
        address cup_,
        address usdc_,
        address vault_,
        address copperPriceConsumer_,
        address zapper_,
        uint256 redeemCommissionBps_
    ) public initializer {
        require(cup_ != address(0), "Invalid CUP address");
        require(usdc_ != address(0), "Invalid USDC address");
        require(vault_ != address(0), "Invalid Vault address");
        require(copperPriceConsumer_ != address(0), "Invalid Copper Price Consumer address");
        require(zapper_ != address(0), "Invalid Zapper address");
        require(redeemCommissionBps_ <= 10000, "Commission cannot exceed 100%");

        __AccessControl_init();
        __Ownable_init(_msgSender());
        __Pausable_init();
        __ReentrancyGuard_init();

        _grantRole(DEFAULT_ADMIN_ROLE, _msgSender());

        _cup = IERC20(cup_);
        _usdc = IERC20(usdc_);
        _vault = IERC4626(vault_);
        _copperPriceConsumer = ICopperPriceConsumer(copperPriceConsumer_);
        _zapper = zapper_;
        _redeemCommissionBps = redeemCommissionBps_;

        // Deploy dedicated Silo for redeem operations
        _redeemSilo = new Silo(_usdc);
    }

    // ───────────────────────────── REQUEST-BASED REDEEM ─────────────────────────────

    /**
     * @notice Creates a new redeem request and transfers xCUP shares to the contract
     * @dev User must approve this contract to spend their xCUP shares before calling.
     *      The redeemId must be unique - if it already exists, the transaction will revert.
     * @param shares The number of xCUP vault shares to redeem
     * @param redeemId The unique identifier for the redeem request (must be unique)
     */
    function requestRedeem(uint256 shares, bytes32 redeemId) external nonReentrant whenNotPaused {
        require(shares > 0, "Shares must be greater than 0");

        uint256 ownedShares = _vault.balanceOf(_msgSender());
        require(ownedShares >= shares, "Insufficient shares to redeem");

        // Transfer xCUP shares from user to this contract
        IERC20(address(_vault)).safeTransferFrom(_msgSender(), address(this), shares);

        // Create redeem request (adds to pending list and user's list)
        RedeemLib.requestRedeem(_redeems, _pendingRedeemIds, _userRedeems, redeemId, msg.sender, shares);
        emit RedeemRequested(msg.sender, redeemId, shares);
    }

    /**
     * @notice Approves a pending redeem request
     * @param redeemId The unique identifier of the redeem request
     * @param usdcAmount The USDC amount to approve for payout
     */
    function approveRedeem(bytes32 redeemId, uint256 usdcAmount) external whenNotPaused onlyRole(VAULT_CURATOR_ROLE) {
        RedeemLib.approveRedeem(_redeems, redeemId, usdcAmount);
        RedeemLib.RedeemRequest storage req = _redeems[redeemId];

        // Remove from pending list when approved
        RedeemLib.removePendingRedeem(_pendingRedeemIds, redeemId);

        emit RedeemApproved(redeemId, req.shares, usdcAmount);
    }

    /**
     * @notice Claims an approved redeem request
     * @dev Uses xCUP shares that were already transferred to the contract during requestRedeem
     * @param redeemId The unique identifier of the redeem request
     * @return usdcAmount The amount of USDC received
     */
    function claimRedeem(bytes32 redeemId) public nonReentrant whenNotPaused returns (uint256 usdcAmount) {
        return _claimRedeem(redeemId);
    }

    /**
     * @dev Internal function to claim a redeem request (without nonReentrant to allow batch claiming)
     * @param redeemId The unique identifier of the redeem request
     * @return usdcAmount The amount of USDC received
     */
    function _claimRedeem(bytes32 redeemId) internal returns (uint256 usdcAmount) {
        return
            RedeemLib.claimRedeem(
                _redeems,
                redeemId,
                msg.sender,
                _vault,
                _usdc,
                address(_redeemSilo),
                _zapper,
                address(_copperPriceConsumer),
                _userRedeems
            );
    }

    /**
     * @notice Claims all approved redeem requests for msg.sender
     * @dev Iterates over user's redeem IDs and claims those which are approved.
     *      Uses xCUP shares that were already transferred to the contract during requestRedeem.
     * @return totalUsdcAmount Total amount of USDC received for all claimed redeems
     */
    function claimAllRedeems() external nonReentrant whenNotPaused returns (uint256 totalUsdcAmount) {
        bytes32[] storage ids = _userRedeems[_msgSender()];

        // Create a copy of IDs to iterate over, since _claimRedeem will remove entries
        bytes32[] memory idsCopy = new bytes32[](ids.length);
        for (uint256 i = 0; i < ids.length; i++) {
            idsCopy[i] = ids[i];
        }

        // Iterate over the copy
        for (uint256 i = 0; i < idsCopy.length; i++) {
            bytes32 id = idsCopy[i];
            RedeemLib.RedeemRequest storage req = _redeems[id];

            if (req.user == _msgSender() && req.approved && !req.claimed && req.user != address(0)) {
                // Call _claimRedeem which handles removal from user's list
                uint256 usdcAmount = _claimRedeem(id);
                totalUsdcAmount += usdcAmount;
            }
        }
    }

    /**
     * @notice Returns full redeem request information by ID
     * @param redeemId The unique identifier of the redeem request
     * @return RedeemRequest struct containing user, shares, usdcAmount, approved, and claimed status
     */
    function getRedeem(bytes32 redeemId) external view returns (RedeemLib.RedeemRequest memory) {
        return RedeemViewLib.getRedeem(_redeems, redeemId);
    }

    /**
     * @notice Returns all pending redeem IDs awaiting curator approval
     * @return Array of bytes32 redeem IDs currently pending approval
     */
    function getPendingRedeemIds() external view returns (bytes32[] memory) {
        return RedeemViewLib.getPendingRedeemIds(_pendingRedeemIds);
    }

    /**
     * @notice Returns all pending redeem requests with complete information
     * @return redeemsArray Array of complete RedeemRequest structs for all pending redeems
     */
    function getPendingRedeems() external view returns (RedeemLib.RedeemRequest[] memory) {
        return RedeemViewLib.getPendingRedeems(_redeems, _pendingRedeemIds);
    }

    /**
     * @notice Returns all redeem IDs for a given user
     * @param user The user address to query
     * @return Array of bytes32 redeem IDs for the user
     */
    function getUserRedeemIds(address user) external view returns (bytes32[] memory) {
        return RedeemViewLib.getUserRedeemIds(_userRedeems, user);
    }

    /**
     * @notice Returns all redeem requests for a given user
     * @param user The user address to query
     * @return Array of complete RedeemRequest structs for the user
     */
    function getUserRedeems(address user) external view returns (RedeemLib.RedeemRequest[] memory) {
        return RedeemViewLib.getUserRedeems(_redeems, _userRedeems, user);
    }

    /**
     * @notice Returns the total shares of all pending redeem requests
     * @return totalShares The total shares of pending redeem requests
     */
    function getTotalPendingShares() external view returns (uint256) {
        return RedeemViewLib.getTotalPendingShares(_redeems, _pendingRedeemIds);
    }

    // ───────────────────────────── DIRECT REDEEM (WITH COMMISSION) ─────────────────────────────

    /**
     * @notice Allows users to directly redeem their xCUP vault shares for USDC (with commission)
     * @dev This function enables users to exit their vault position immediately without waiting
     *      for curator approval. Commission is deducted and stays in the redeem silo.
     *
     * @param sharesToRedeem The number of xCUP vault shares to redeem
     * @return usdcToWithdraw The amount of USDC received from redemption (after commission)
     */
    function redeem(uint256 sharesToRedeem) external nonReentrant whenNotPaused returns (uint256 usdcToWithdraw) {
        require(sharesToRedeem > 0, "Shares to redeem must be greater than 0");

        uint256 ownedShares = _vault.balanceOf(_msgSender());
        require(ownedShares >= sharesToRedeem, "Insufficient shares to redeem");

        IERC20(address(_vault)).safeTransferFrom(_msgSender(), address(this), sharesToRedeem);

        _vault.approve(address(_vault), sharesToRedeem);

        // CUP tokens are sent directly to Zapper contract
        uint256 withdrawnCup = _vault.redeem(sharesToRedeem, address(_zapper), address(this));

        uint256 copperPrice = getCopperPrice();
        require(copperPrice > 0, "Copper price is 0");

        // Convert CUP back to USDC using copper price
        uint256 totalUsdcAmount = (withdrawnCup * copperPrice) / (10 ** 8);

        // Apply commission - commission stays in redeem silo, user gets the remainder
        uint256 commissionAmount = (totalUsdcAmount * _redeemCommissionBps) / 10000;
        usdcToWithdraw = totalUsdcAmount - commissionAmount;

        // Pull total USDC from redeem silo (redeem silo must be pre-funded)
        require(_usdc.balanceOf(address(_redeemSilo)) >= totalUsdcAmount, "Insufficient USDC in redeem silo");
        _usdc.safeTransferFrom(address(_redeemSilo), address(this), totalUsdcAmount);

        // Transfer commission back to redeem silo (it stays there)
        if (commissionAmount > 0) {
            _usdc.safeTransfer(address(_redeemSilo), commissionAmount);
        }

        // Send remainder to user
        require(_usdc.balanceOf(address(this)) >= usdcToWithdraw, "Insufficient USDC balance");
        _usdc.safeTransfer(_msgSender(), usdcToWithdraw);

        emit DirectRedeemExecuted(_msgSender(), sharesToRedeem, usdcToWithdraw, commissionAmount);
    }

    // ───────────────────────────── ADMIN FUNCTIONS ─────────────────────────────

    /**
     * @notice Sets the commission rate for direct redeem operations
     * @dev Commission is charged on direct redeem operations, with the remainder staying in redeem silo
     * @param commissionBps Commission rate in basis points (e.g., 200 = 2%)
     */
    function setRedeemCommission(uint256 commissionBps) external onlyRole(VAULT_CURATOR_ROLE) {
        require(commissionBps <= 10000, "Commission cannot exceed 100%");
        _redeemCommissionBps = commissionBps;
        emit RedeemCommissionUpdated(commissionBps);
    }

    /**
     * @notice Allows the contract owner to withdraw USDC from the Redeem Silo
     * @param amount The amount of USDC to withdraw from the Redeem Silo (6 decimals)
     */
    function withdrawFromRedeemSilo(uint256 amount) external nonReentrant onlyRole(VAULT_CURATOR_ROLE) {
        require(_usdc.balanceOf(address(_redeemSilo)) >= amount, "Insufficient USDC balance in redeem silo");

        _usdc.safeTransferFrom(address(_redeemSilo), owner(), amount);

        emit RedeemSiloWithdrawn(owner(), amount);
    }

    /**
     * @dev Pauses the contract, preventing new redeem requests and claims
     */
    function pause() external onlyOwner {
        _pause();
    }

    /**
     * @dev Unpauses the contract, allowing new redeem requests and claims
     */
    function unpause() external onlyOwner {
        _unpause();
    }

    // ───────────────────────────── REDEEM CANCELLATION ─────────────────────────────

    /**
     * @notice Allows users to cancel their pending redeem request and get shares back
     * @dev User can cancel only if request is not approved and not claimed
     * @param redeemId The unique identifier of the redeem request to cancel
     * @return shares The number of shares returned to the user
     */
    function cancelRedeemRequest(bytes32 redeemId) external nonReentrant whenNotPaused returns (uint256 shares) {
        (address user, uint256 sharesToReturn) = RedeemLib.cancelRedeem(
            _redeems,
            _pendingRedeemIds,
            _userRedeems,
            redeemId
        );

        require(user == msg.sender, "Not authorized to cancel");

        // Return xCUP shares to user
        IERC20(address(_vault)).safeTransfer(msg.sender, sharesToReturn);

        emit RedeemCancelled(redeemId, user, sharesToReturn);

        return sharesToReturn;
    }

    /**
     * @notice Allows users to cancel all their pending redeem requests
     * @dev Returns all xCUP shares from pending requests back to user
     * @return totalShares The total number of shares returned to the user
     */
    function cancelAllRedeemRequests() external nonReentrant whenNotPaused returns (uint256 totalShares) {
        bytes32[] storage userRedeemIds = _userRedeems[_msgSender()];
        require(userRedeemIds.length > 0, "No redeem requests found");

        // Create a copy of redeem IDs to iterate over, since we'll be modifying the original array
        bytes32[] memory redeemIds = new bytes32[](userRedeemIds.length);
        uint256 validRedeemsCount = 0;

        // First pass: collect valid pending redeems
        for (uint256 i = 0; i < userRedeemIds.length; i++) {
            bytes32 redeemId = userRedeemIds[i];
            RedeemLib.RedeemRequest storage req = _redeems[redeemId];

            if (req.user == _msgSender() && !req.approved && !req.claimed && req.user != address(0)) {
                redeemIds[validRedeemsCount] = redeemId;
                totalShares += req.shares;
                validRedeemsCount++;
            }
        }

        require(validRedeemsCount > 0, "No pending redeem requests to cancel");

        // Second pass: actually cancel the redeems
        for (uint256 i = 0; i < validRedeemsCount; i++) {
            bytes32 redeemId = redeemIds[i];
            RedeemLib.RedeemRequest storage req = _redeems[redeemId];

            // Clean up the redeem
            delete _redeems[redeemId];
            RedeemLib.removePendingRedeem(_pendingRedeemIds, redeemId);
            RedeemLib.removeUserRedeem(_userRedeems, _msgSender(), redeemId);

            emit RedeemCancelled(redeemId, _msgSender(), req.shares);
        }

        // Transfer total shares back to user
        IERC20(address(_vault)).safeTransfer(_msgSender(), totalShares);
    }

    // ───────────────────────────── CURATOR FUNCTIONS ─────────────────────────────

    /**
     * @notice Allows vault curators to decline a redeem request
     * @dev Curator can decline only if request is not approved and not claimed
     *      Returns xCUP shares back to the user
     * @param redeemId The unique identifier of the redeem request to decline
     */
    function declineRedeem(bytes32 redeemId) external whenNotPaused onlyRole(VAULT_CURATOR_ROLE) nonReentrant {
        (address user, uint256 sharesToReturn) = RedeemLib.declineRedeem(
            _redeems,
            _pendingRedeemIds,
            _userRedeems,
            redeemId
        );

        // Return xCUP shares to user
        IERC20(address(_vault)).safeTransfer(user, sharesToReturn);

        emit RedeemDeclined(redeemId, user, sharesToReturn);
    }

    /**
     * @notice Allows vault curators to approve multiple redeem requests proportionally
     * @dev This function enables curators to approve a specific total shares amount across
     *      all pending redeem requests, with each request receiving a proportional share.
     *      USDC amounts are calculated based on current copper price.
     * @param targetTotalShares The total shares to approve across all redeems
     */
    function approveRedeemsProportionally(
        uint256 targetTotalShares
    ) external whenNotPaused onlyRole(VAULT_CURATOR_ROLE) {
        // Get current copper price to calculate USDC amounts
        uint256 copperPrice = getCopperPrice();
        require(copperPrice > 0, "Copper price is 0");

        // Calculate proportion and total pending shares
        (uint256 proportion, uint256 totalPendingShares) = RedeemLib.calculateProportionalApproval(
            _redeems,
            _pendingRedeemIds,
            targetTotalShares
        );

        // Create a copy of pending IDs since we'll be modifying the array
        bytes32[] memory pendingIds = new bytes32[](_pendingRedeemIds.length);
        for (uint256 i = 0; i < _pendingRedeemIds.length; i++) {
            pendingIds[i] = _pendingRedeemIds[i];
        }

        // Approve redeems proportionally and calculate USDC amounts
        for (uint256 i = 0; i < pendingIds.length; i++) {
            bytes32 redeemId = pendingIds[i];
            RedeemLib.RedeemRequest storage req = _redeems[redeemId];

            if (req.user != address(0) && !req.approved) {
                uint256 approvedShares = (req.shares * proportion) / 1e18;

                if (approvedShares > 0) {
                    // Convert approved shares to CUP assets using vault
                    uint256 cupValue = _vault.convertToAssets(approvedShares);

                    // Convert CUP to USDC using copper price
                    uint256 usdcAmount = (cupValue * copperPrice) / (10 ** 8);

                    // Approve the redeem
                    req.approved = true;
                    req.usdcAmount = usdcAmount;

                    // Remove from pending list
                    RedeemLib.removePendingRedeem(_pendingRedeemIds, redeemId);

                    emit RedeemApproved(redeemId, approvedShares, usdcAmount);
                }
            }
        }
    }

    /**
     * @notice Allows vault curators to approve all pending redeem requests in full
     * @dev This function provides a convenient way to approve all pending redeem requests
     *      for their complete shares. USDC amounts are calculated based on current copper price.
     * @return totalShares The total shares approved across all redeems
     * @return redeemsApproved The number of individual redeems that were approved
     */
    function approveAllRedeems()
        external
        whenNotPaused
        onlyRole(VAULT_CURATOR_ROLE)
        returns (uint256 totalShares, uint256 redeemsApproved)
    {
        // Get current copper price to calculate USDC amounts
        uint256 copperPrice = getCopperPrice();
        require(copperPrice > 0, "Copper price is 0");

        // Create a copy of pending IDs since we'll be modifying the array
        bytes32[] memory pendingIds = new bytes32[](_pendingRedeemIds.length);
        for (uint256 i = 0; i < _pendingRedeemIds.length; i++) {
            pendingIds[i] = _pendingRedeemIds[i];
        }

        // Approve all pending redeems in full
        for (uint256 i = 0; i < pendingIds.length; i++) {
            bytes32 redeemId = pendingIds[i];
            RedeemLib.RedeemRequest storage req = _redeems[redeemId];

            if (req.user != address(0) && !req.approved) {
                // Convert shares to CUP assets using vault
                uint256 cupValue = _vault.convertToAssets(req.shares);

                // Convert CUP to USDC using copper price
                uint256 usdcAmount = (cupValue * copperPrice) / (10 ** 8);

                // Approve the redeem
                req.approved = true;
                req.usdcAmount = usdcAmount;
                totalShares += req.shares;
                redeemsApproved++;

                // Remove from pending list
                RedeemLib.removePendingRedeem(_pendingRedeemIds, redeemId);

                emit RedeemApproved(redeemId, req.shares, usdcAmount);
            }
        }

        require(redeemsApproved > 0, "No valid pending redeems");
    }

    // ───────────────────────────── VIEW FUNCTIONS ─────────────────────────────

    /**
     * @notice Returns the current copper price from the oracle
     * @return price The current copper price with 8 decimal places
     */
    function getCopperPrice() public view returns (uint256 price) {
        price = _copperPriceConsumer.price();
    }

    /**
     * @notice Returns the current commission rate for direct redeem operations
     * @return Commission rate in basis points
     */
    function getRedeemCommission() external view returns (uint256) {
        return _redeemCommissionBps;
    }

    /**
     * @notice Returns the address of the redeem Silo contract
     * @return The redeem Silo contract address
     */
    function redeemSilo() public view returns (address) {
        return address(_redeemSilo);
    }

    /**
     * @notice Returns the address of the CUP token contract
     * @return The CUP token address
     */
    function cup() public view returns (address) {
        return address(_cup);
    }

    /**
     * @notice Returns the address of the USDC token contract
     * @return The USDC token address
     */
    function usdc() public view returns (address) {
        return address(_usdc);
    }

    /**
     * @notice Returns the address of the xCUP vault contract
     * @return The vault contract address
     */
    function vault() public view returns (address) {
        return address(_vault);
    }

    /**
     * @notice Returns the address of the Zapper contract
     * @return The Zapper contract address
     */
    function zapper() public view returns (address) {
        return _zapper;
    }
}
