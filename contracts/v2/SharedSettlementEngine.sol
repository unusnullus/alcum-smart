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

import {IAssetOracle} from "./interfaces/IAssetOracle.sol";
import {IEpochManager} from "./interfaces/IEpochManager.sol";
import {IFeeDistributor} from "./interfaces/IFeeDistributor.sol";
import {IERC20Mintable} from "../interfaces/IERC20Mintable.sol";
import {VaultLib} from "./libraries/VaultLib.sol";
import {VaultRegistry} from "./VaultRegistry.sol";

/**
 * @title SharedSettlementEngine
 * @notice Protocol-wide settlement engine for all vaults.
 *
 * @dev Epoch revenue lifecycle (per vault):
 *      recordEpochRevenue  →  settleEpochRevenue  →  distributeRevenueToVault
 *
 *      On distribution:
 *        1. Revenue manager transfers net USDC into this contract.
 *        2. System fee is routed via the configured fee distribution path.
 *        3. Net USDC (after fee) is forwarded to the vault's CapitalFacility.
 *        4. Equivalent asset tokens are minted directly into the RWAVault, raising
 *           totalAssets and therefore the share price for all holders.
 *
 *      Fee distribution priority:
 *        1. feeDistributor (IFeeDistributor) — if set, receives the full fee slice.
 *        2. feeRecipients[]                  — multi-recipient split by basis points.
 *        3. vault treasury (VaultRegistry)   — fallback if neither above is configured.
 *        Any remainder when feeRecipients sum < 10_000 bps goes to the vault treasury.
 *
 *      Role layout:
 *        DEFAULT_ADMIN_ROLE    — protocol multisig
 *        REVENUE_MANAGER_ROLE  — global revenue manager (protocol admin); fallback for all vaults
 *        VAULT_FACTORY_ROLE    — VaultFactory; may register per-vault operators via setVaultOperator
 *
 *      Per-vault operator:
 *        vaultOperator[vaultId] — the issuer's own backend; has revenue-manager rights scoped
 *        exclusively to its vaultId. Set atomically by VaultFactory on vault creation.
 */
contract SharedSettlementEngine is
    Initializable,
    OwnableUpgradeable,
    AccessControlUpgradeable,
    PausableUpgradeable,
    ReentrancyGuardUpgradeable,
    UUPSUpgradeable
{
    using SafeERC20 for IERC20;

    // ─────────────────────────── ROLES ──────────────────────────────────────

    bytes32 public constant REVENUE_MANAGER_ROLE = keccak256("REVENUE_MANAGER_ROLE");
    /// @notice Granted to VaultFactory so it can register per-vault operators.
    bytes32 public constant VAULT_FACTORY_ROLE   = keccak256("VAULT_FACTORY_ROLE");

    // ─────────────────────────── STRUCTS ────────────────────────────────────

    struct EpochRevenue {
        uint256 epochId;
        uint256 netRevenue; // USDC (6 dec) — zeroed after distribution
        uint256 originalNetRevenue; // immutable record for analytics
        uint256 assetBought; // asset token units traded in
        uint256 assetSold; // asset token units traded out
        uint256 averageBuyPrice; // oracle price at purchase (8 dec)
        uint256 averageSellPrice; // oracle price at sale (8 dec)
        uint256 totalSupplyAtClose; // vault share supply snapshot at epoch close
        bool isSettled;
    }

    struct NAVComponents {
        uint256 assetInInventory; // asset token units in custody
        uint256 assetSpotPrice; // current oracle price (8 dec)
        uint256 assetInTransit; // asset tokens in transit between custodians
        uint256 retainedEarnings; // USDC (6 dec) — undistributed protocol earnings
        uint256 stablecoinBalance; // USDC (6 dec) — idle balance in CapitalFacility
        uint256 liabilities; // USDC (6 dec) — pending redemption obligations
    }

    /**
     * @notice A single recipient in the system-fee split.
     * @dev bps is expressed relative to 10_000 of the total system fee amount.
     *      The sum of all recipient bps must not exceed 10_000. Any shortfall
     *      is automatically forwarded to the vault treasury.
     */
    struct FeeRecipient {
        address recipient;
        uint256 bps;
    }

    // ─────────────────────────── STATE ──────────────────────────────────────

    VaultRegistry public registry;

    /// @notice Unused — slot retained for UUPS layout compatibility. Per-vault treasury is in VaultRegistry.
    address public treasury;

    uint256 public systemFeeBps;
    uint256 public constant BASIS_POINTS = 10_000;

    /**
     * @notice On-chain multi-recipient fee split configuration.
     * @dev Empty array defers to the vault treasury. Use setFeeDistribution() to configure.
     *      Takes lower precedence than `feeDistributor` if both are set.
     */
    FeeRecipient[] public feeRecipients;

    /**
     * @notice Pluggable fee routing module (IFeeDistributor).
     * @dev When non-zero, the full system fee is approved and distributed via this
     *      contract rather than through feeRecipients or the vault treasury directly.
     *      Supports advanced routing such as buybacks or protocol-owned liquidity.
     */
    address public feeDistributor;

    /// @notice Per-vault operator: the issuer's backend hot-wallet for that specific vault.
    ///         Has revenue-manager rights scoped exclusively to its vaultId.
    mapping(uint256 => address) public vaultOperator;

    /// @dev vaultId → epochId → EpochRevenue.
    mapping(uint256 => mapping(uint256 => EpochRevenue)) public epochRevenues;

    /// @dev vaultId → NAVComponents.
    mapping(uint256 => NAVComponents) internal _nav;

    /// @dev vaultId → epochId → system fee collected.
    mapping(uint256 => mapping(uint256 => uint256)) public epochSystemFees;

    // ─────────────────────────── EVENTS ─────────────────────────────────────

    event EpochRevenueRecorded(uint256 indexed vaultId, uint256 indexed epochId, uint256 netRevenue);
    event EpochSettled(uint256 indexed vaultId, uint256 indexed epochId, uint256 totalSupplyAtClose);
    event RevenueDistributed(
        uint256 indexed vaultId,
        uint256 indexed epochId,
        uint256 netAfterFees,
        uint256 assetMinted,
        uint256 systemFee
    );
    event NAVUpdated(uint256 indexed vaultId, uint256 netAssets, uint256 pricePerShare);
    event VaultOperatorSet(uint256 indexed vaultId, address indexed operator);
    event SystemFeeUpdated(uint256 oldFee, uint256 newFee);
    event FeeDistributionUpdated(uint256 recipientCount);
    event FeeDistributorUpdated(address indexed oldDistributor, address indexed newDistributor);
    event FeeDistributed(uint256 indexed vaultId, uint256 indexed epochId, uint256 totalFee, uint256 recipientCount);

    // ─────────────────────────── ERRORS ─────────────────────────────────────

    error ZeroAddress();
    error ZeroEpochId();
    error ZeroNetRevenue();
    error EpochAlreadySettled(uint256 vaultId, uint256 epochId);
    error EpochRevenueNotFound(uint256 vaultId, uint256 epochId);
    error EpochNotSettled(uint256 vaultId, uint256 epochId);
    error NoRevenueToDistribute(uint256 vaultId, uint256 epochId);
    error EpochIdMismatch(uint256 expected, uint256 provided);
    error InvalidSystemFee();
    error InvalidAssetPrice();
    error ZeroAssetTokensToMint();
    error InvalidFeeDistribution();
    error Unauthorized();
    error NoEpochManager(uint256 vaultId);
    error EpochNotFinished(uint256 vaultId);
    error InvalidEpochPrice();
    error CannotRescueVaultShares(address vaultShareToken);

    // ─────────────────────────── INIT ───────────────────────────────────────

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /**
     * @notice Initialize the settlement engine proxy. Can be called only once.
     * @param registry_      VaultRegistry used to resolve per-vault addresses.
     * @param systemFeeBps_  Protocol fee in basis points of epoch net revenue (max 10_000).
     * @param admin_         Owner, DEFAULT_ADMIN_ROLE and REVENUE_MANAGER_ROLE holder.
     */
    function initialize(
        address registry_,
        uint256 systemFeeBps_,
        address admin_
    ) public initializer {
        if (registry_ == address(0)) revert ZeroAddress();
        if (admin_ == address(0)) revert ZeroAddress();
        if (systemFeeBps_ > BASIS_POINTS) revert InvalidSystemFee();

        __Ownable_init(admin_);
        __AccessControl_init();
        __Pausable_init();
        __ReentrancyGuard_init();
        __UUPSUpgradeable_init();

        _grantRole(DEFAULT_ADMIN_ROLE, admin_);
        _grantRole(REVENUE_MANAGER_ROLE, admin_);

        registry = VaultRegistry(registry_);
        systemFeeBps = systemFeeBps_;
    }

    // ─────────────────────────── REVENUE LIFECYCLE ──────────────────────────

    /**
     * @notice Record off-chain trading data for a completed epoch.
     * @dev Calling this does not move any funds. It populates an EpochRevenue record
     *      that must be settled and then distributed in subsequent calls.
     */
    function recordEpochRevenue(
        uint256 vaultId,
        uint256 epochId,
        uint256 netRevenue,
        uint256 assetBought,
        uint256 assetSold,
        uint256 averageBuyPrice,
        uint256 averageSellPrice
    ) external whenNotPaused {
        _checkRevenueManager(vaultId);
        if (epochId == 0) revert ZeroEpochId();
        if (netRevenue == 0) revert ZeroNetRevenue();
        if (assetBought > 0 && averageBuyPrice == 0) revert InvalidEpochPrice();
        if (assetSold > 0 && averageSellPrice == 0) revert InvalidEpochPrice();

        EpochRevenue storage r = epochRevenues[vaultId][epochId];
        if (r.isSettled) revert EpochAlreadySettled(vaultId, epochId);

        registry.getVault(vaultId);

        r.epochId = epochId;
        r.netRevenue = netRevenue;
        r.originalNetRevenue = netRevenue;
        r.assetBought = assetBought;
        r.assetSold = assetSold;
        r.averageBuyPrice = averageBuyPrice;
        r.averageSellPrice = averageSellPrice;
        r.isSettled = false;

        emit EpochRevenueRecorded(vaultId, epochId, netRevenue);
    }

    /**
     * @notice Finalise the current epoch: snapshot vault share supply and mark as settled.
     * @dev `epochId` must match the current epoch reported by the vault's EpochManager.
     *      This prevents the revenue manager from settling future or duplicate epochs.
     *
     *      Epoch advancement (calling IEpochManager.nextEpoch) is a separate operator
     *      action — it requires time to elapse and must be performed after this call.
     *      Must be called before distributeRevenueToVault.
     */
    function settleEpochRevenue(
        uint256 vaultId,
        uint256 epochId
    ) external whenNotPaused {
        _checkRevenueManager(vaultId);
        EpochRevenue storage r = epochRevenues[vaultId][epochId];
        if (r.epochId != epochId) revert EpochRevenueNotFound(vaultId, epochId);
        if (r.isSettled) revert EpochAlreadySettled(vaultId, epochId);
        if (r.netRevenue == 0) revert NoRevenueToDistribute(vaultId, epochId);

        VaultLib.VaultRecord memory v = registry.getVault(vaultId);
        if (v.epochManager == address(0)) revert NoEpochManager(vaultId);
        if (IEpochManager(v.epochManager).timeLeftInEpoch() > 0) revert EpochNotFinished(vaultId);

        // Verify the provided epochId matches the on-chain EpochManager state.
        uint256 onChainEpoch = IEpochManager(v.epochManager).currentEpochId();
        if (epochId != onChainEpoch) revert EpochIdMismatch(onChainEpoch, epochId);

        r.totalSupplyAtClose = IERC4626(v.vault).totalSupply();
        r.isSettled = true;

        _nav[vaultId].retainedEarnings += r.netRevenue;

        emit EpochSettled(vaultId, epochId, r.totalSupplyAtClose);
    }

    /**
     * @notice Distribute settled epoch revenue to the vault ecosystem.
     *
     * @dev Caller must call IERC20(settlementToken).approve(address(this), netRevenue) before
     *      invoking this function. Steps executed:
     *        a. Pull full settlement token amount from caller.
     *        b. Route system fee via the configured distribution path.
     *        c. Transfer net settlement tokens to the vault's CapitalFacility.
     *        d. Mint proportional asset tokens into the RWAVault (increases share price).
     *        e. NAV warehouse inventory:
     *           - default vaults: sync `assetInInventory` from vault.balanceOf.
     *           - `reportedInventoryOnly` vaults: leave inventory unchanged (set via updateNAV).
     *
     * @param vaultId  Registry identifier of the target vault.
     * @param epochId  Epoch to distribute revenue for (must be settled).
     */
    function distributeRevenueToVault(
        uint256 vaultId,
        uint256 epochId
    ) external whenNotPaused nonReentrant {
        _checkRevenueManager(vaultId);
        EpochRevenue storage r = epochRevenues[vaultId][epochId];
        if (r.epochId != epochId) revert EpochRevenueNotFound(vaultId, epochId);
        if (!r.isSettled) revert EpochNotSettled(vaultId, epochId);
        if (r.netRevenue == 0) revert NoRevenueToDistribute(vaultId, epochId);

        VaultLib.VaultRecord memory v = registry.getVault(vaultId);

        uint256 total = r.netRevenue;
        uint256 fee = (total * systemFeeBps) / BASIS_POINTS;
        uint256 netAfterFee = total - fee;

        epochSystemFees[vaultId][epochId] = fee;

        IERC20(v.settlementToken).safeTransferFrom(msg.sender, address(this), total);

        if (fee > 0) {
            _distributeFee(v.settlementToken, fee, vaultId, epochId);
        }

        IERC20(v.settlementToken).safeTransfer(v.capitalFacility, netAfterFee);

        uint256 mintPrice = r.averageBuyPrice;
        if (mintPrice == 0) {
            mintPrice = IAssetOracle(v.assetOracle).price();
        }
        if (mintPrice == 0) revert InvalidAssetPrice();
        uint8 dec = IAssetOracle(v.assetOracle).decimals();

        uint256 assetToMint = (netAfterFee * 10 ** uint256(dec)) / mintPrice;
        if (assetToMint == 0) revert ZeroAssetTokensToMint();

        IERC20Mintable(v.assetToken).mint(v.vault, assetToMint);

        NAVComponents storage n = _nav[vaultId];
        if (n.retainedEarnings >= total) {
            n.retainedEarnings -= total;
        } else {
            n.retainedEarnings = 0;
        }

        if (!v.reportedInventoryOnly) {
            n.assetInInventory = IERC20(v.assetToken).balanceOf(v.vault);
        }

        r.netRevenue = 0;

        emit RevenueDistributed(vaultId, epochId, netAfterFee, assetToMint, fee);
    }

    // ─────────────────────────── NAV ────────────────────────────────────────

    /**
     * @notice Update the NAV components for a vault and emit a price-per-share snapshot.
     * @dev All monetary values in NAVComponents must use 6 decimal precision (USDC-aligned).
     *      assetSpotPrice must use 8 decimal precision (oracle-aligned).
     */
    function updateNAV(uint256 vaultId, NAVComponents calldata newNav) external {
        _checkRevenueManager(vaultId);
        VaultLib.VaultRecord memory v = registry.getVault(vaultId);

        NAVComponents memory nav = newNav;
        if (!v.reportedInventoryOnly) {
            nav.assetInInventory = IERC20(v.assetToken).balanceOf(v.vault);
        }
        _nav[vaultId] = nav;

        NAVComponents storage n = _nav[vaultId];

        uint8 dec = IAssetOracle(v.assetOracle).decimals();
        uint256 scale = 10 ** uint256(dec);
        uint256 assetValue = ((n.assetInInventory + n.assetInTransit) * n.assetSpotPrice) / scale;
        uint256 totalAssets = assetValue + n.retainedEarnings + n.stablecoinBalance;
        uint256 netAssets = totalAssets > n.liabilities ? totalAssets - n.liabilities : 0;

        uint256 supply = IERC4626(v.vault).totalSupply();
        uint256 pricePerShare = supply == 0 ? 1e6 : (netAssets * 1e6) / supply;

        emit NAVUpdated(vaultId, netAssets, pricePerShare);
    }

    // ─────────────────────────── VIEWS ──────────────────────────────────────

    function getEpochRevenue(uint256 vaultId, uint256 epochId) external view returns (EpochRevenue memory) {
        return epochRevenues[vaultId][epochId];
    }

    function getNav(uint256 vaultId) external view returns (NAVComponents memory) {
        return _nav[vaultId];
    }

    /// @notice Computed NAV summary: totalAssets, netAssets, and pricePerShare.
    function getNAVSummary(
        uint256 vaultId
    ) external view returns (uint256 totalAssets, uint256 netAssets, uint256 pricePerShare) {
        NAVComponents storage n = _nav[vaultId];
        VaultLib.VaultRecord memory v = registry.getVault(vaultId);

        uint8 dec = IAssetOracle(v.assetOracle).decimals();
        uint256 scale = 10 ** uint256(dec);
        uint256 assetValue = ((n.assetInInventory + n.assetInTransit) * n.assetSpotPrice) / scale;
        totalAssets = assetValue + n.retainedEarnings + n.stablecoinBalance;
        netAssets = totalAssets > n.liabilities ? totalAssets - n.liabilities : 0;
        uint256 supply = IERC4626(v.vault).totalSupply();
        pricePerShare = supply == 0 ? 1e6 : (netAssets * 1e6) / supply;
    }

    /**
     * @notice Walk backwards from `currentEpochId` to find the most recently settled epoch.
     * @dev Searches up to 100 epochs back. Returns (empty struct, false) if none found.
     */
    function getLastSettledEpochRevenue(
        uint256 vaultId,
        uint256 currentEpochId
    ) external view returns (EpochRevenue memory epochRevenue, bool found) {
        uint256 start = currentEpochId > 0 ? currentEpochId - 1 : 0;
        uint256 depth;
        for (uint256 e = start; e > 0 && depth < 100; e--) {
            EpochRevenue memory r = epochRevenues[vaultId][e];
            if (r.epochId == e && r.isSettled) return (r, true);
            depth++;
        }
    }

    // ─────────────────────────── ADMIN ──────────────────────────────────────

    /**
     * @notice Configure multi-recipient system-fee splitting.
     * @dev bps values are relative to the system fee amount, not total revenue.
     *      The sum of all bps must not exceed 10_000. Any shortfall is sent to the vault treasury.
     *      Pass an empty array to revert to per-vault treasury mode.
     */
    function setFeeDistribution(FeeRecipient[] calldata recipients) external onlyOwner {
        uint256 total;
        for (uint256 i; i < recipients.length; i++) {
            if (recipients[i].recipient == address(0)) revert ZeroAddress();
            total += recipients[i].bps;
        }
        if (total > BASIS_POINTS) revert InvalidFeeDistribution();

        delete feeRecipients;
        for (uint256 i; i < recipients.length; i++) {
            feeRecipients.push(recipients[i]);
        }
        emit FeeDistributionUpdated(recipients.length);
    }

    /**
     * @notice Set or remove the pluggable IFeeDistributor.
     * @dev Pass address(0) to disable and fall back to feeRecipients or the vault treasury.
     *      Takes precedence over feeRecipients[] when both are configured.
     */
    function setFeeDistributor(address distributor) external onlyOwner {
        emit FeeDistributorUpdated(feeDistributor, distributor);
        feeDistributor = distributor;
    }

    function getFeeRecipients() external view returns (FeeRecipient[] memory) {
        return feeRecipients;
    }

    function setSystemFee(uint256 newFeeBps) external onlyOwner {
        if (newFeeBps > BASIS_POINTS) revert InvalidSystemFee();
        emit SystemFeeUpdated(systemFeeBps, newFeeBps);
        systemFeeBps = newFeeBps;
    }

    function pause() external onlyOwner {
        _pause();
    }
    function unpause() external onlyOwner {
        _unpause();
    }

    /// @notice Recover ERC-20 tokens accidentally sent to this contract.
    function rescueTokens(address token, address to, uint256 amount) external onlyOwner {
        if (to == address(0)) revert ZeroAddress();
        if (registry.vaultIdByAddress(token) != 0) revert CannotRescueVaultShares(token);
        IERC20(token).safeTransfer(to, amount);
    }

    // ─────────────────────────── INTERNAL ───────────────────────────────────

    /**
     * @dev Route the system fee according to the configured distribution path.
     *      Priority: feeDistributor → feeRecipients → vault treasury.
     */
    function _distributeFee(address settlementToken, uint256 fee, uint256 vaultId, uint256 epochId) internal {
        address vaultTreasury = registry.getVault(vaultId).treasury;

        if (feeDistributor != address(0)) {
            IERC20(settlementToken).forceApprove(feeDistributor, fee);
            IFeeDistributor(feeDistributor).distribute(settlementToken, fee);
            emit FeeDistributed(vaultId, epochId, fee, 1);
            return;
        }

        uint256 len = feeRecipients.length;
        if (len > 0) {
            uint256 distributed;
            for (uint256 i; i < len; i++) {
                uint256 slice = (fee * feeRecipients[i].bps) / BASIS_POINTS;
                if (slice > 0 && feeRecipients[i].recipient != address(0)) {
                    IERC20(settlementToken).safeTransfer(feeRecipients[i].recipient, slice);
                    distributed += slice;
                }
            }
            uint256 remainder = fee - distributed;
            if (remainder > 0) IERC20(settlementToken).safeTransfer(vaultTreasury, remainder);
            emit FeeDistributed(vaultId, epochId, fee, len);
            return;
        }

        IERC20(settlementToken).safeTransfer(vaultTreasury, fee);
        emit FeeDistributed(vaultId, epochId, fee, 1);
    }

    /**
     * @notice Register the per-vault operator for a newly created vault.
     * @dev Called by VaultFactory atomically on createVault. May also be called by owner
     *      to rotate the operator. Pass address(0) to clear.
     */
    function setVaultOperator(uint256 vaultId, address operator) external {
        if (!hasRole(VAULT_FACTORY_ROLE, msg.sender) && msg.sender != owner()) revert Unauthorized();
        vaultOperator[vaultId] = operator;
        emit VaultOperatorSet(vaultId, operator);
    }

    /// @dev Reverts unless caller is the per-vault operator OR holds global REVENUE_MANAGER_ROLE.
    function _checkRevenueManager(uint256 vaultId) internal view {
        if (msg.sender != vaultOperator[vaultId] && !hasRole(REVENUE_MANAGER_ROLE, msg.sender))
            revert Unauthorized();
    }

    function _authorizeUpgrade(address) internal override onlyOwner {}

    /**
     * @dev Storage gap for future variable additions. Reduce this size by the number
     *      of slots added in subsequent upgrades.
     */
    uint256[43] private __gap;
}
