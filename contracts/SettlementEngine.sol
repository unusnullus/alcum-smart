// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {ReentrancyGuardUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Mintable} from "./interfaces/IERC20Mintable.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";

import {IEpochManager} from "./interfaces/IEpochManager.sol";
import {ICopperPriceConsumer} from "./interfaces/ICopperPriceConsumer.sol";

/**
 * @title SettlementEngine
 * @author Alcum Protocol Team
 * @notice Handles settlement of epoch-based copper trading revenues and NAV calculations
 * @dev This contract manages the complete revenue settlement cycle for copper trading operations.
 *      It tracks Net Asset Value (NAV) components including copper inventory, cash reserves,
 *      and liabilities, then distributes revenues to vault participants through CUP token minting.
 *
 *      The settlement process involves:
 *      1. Recording epoch revenue data from trading operations
 *      2. Settling epoch revenues and updating retained earnings
 *      3. Distributing net revenues by minting CUP tokens to the vault
 *      4. Calculating and maintaining accurate NAV components
 *
 *      Security Features:
 *      - Role-based access control with REVENUE_MANAGER_ROLE
 *      - Pausable functionality for emergency situations
 *      - ReentrancyGuard protection for revenue distribution
 *      - Comprehensive input validation and state checks
 *      - Single settlement per epoch to prevent double-spending
 *
 *      Integration:
 *      - Works with ERC4626 vault for share-based revenue distribution
 *      - Integrates with Chainlink oracle for copper price feeds
 *      - Connects to EpochManager for time-based operations
 *      - Handles USDC as the base currency for all calculations
 */
contract SettlementEngine is
    Initializable,
    OwnableUpgradeable,
    PausableUpgradeable,
    AccessControlUpgradeable,
    ReentrancyGuardUpgradeable
{
    using SafeERC20 for IERC20;

    /// @notice Role identifier for revenue managers who can record and settle epoch revenue
    /// @dev Granted to addresses authorized to manage the complete revenue settlement cycle.
    bytes32 public constant REVENUE_MANAGER_ROLE = keccak256("REVENUE_MANAGER_ROLE");

    /// @notice Thrown when an invalid address (zero address) is provided during initialization
    /// @dev Used in constructor validation to ensure all contract dependencies are properly set
    error InvalidAddress();

    /// @notice Thrown when an invalid epoch ID is provided (zero or future epoch)
    /// @dev Epoch IDs must be positive and not exceed the current epoch from EpochManager
    error InvalidEpochId();

    /// @notice Thrown when attempting to modify an epoch that has already been settled
    /// @dev Prevents double-settlement and ensures data integrity of finalized epochs
    error EpochAlreadySettled();

    /// @notice Thrown when trying to access revenue data for a non-existent epoch
    /// @dev Occurs when epoch ID doesn't match any recorded revenue data
    error EpochRevenueNotFound();

    /// @notice Thrown when attempting to distribute revenue for an unsettled epoch
    /// @dev Revenue must be settled before distribution to ensure proper accounting
    error EpochNotSettled();

    /// @notice Thrown when revenue amount is invalid (zero or negative)
    /// @dev Ensures only positive revenue amounts are recorded for distribution
    error InvalidRevenue();

    /// @notice Thrown when copper price from oracle is invalid (zero or stale)
    /// @dev Critical for accurate NAV calculations and revenue distribution
    error InvalidCopperPrice();

    /// @notice Thrown when attempting to distribute zero or already distributed revenue
    /// @dev Prevents unnecessary transactions and ensures revenue availability
    error NoRevenueToDistribute();

    /// @notice Thrown when vault address is zero during initialization
    error InvalidVaultAddress();

    /// @notice Thrown when treasury address is zero during initialization
    error InvalidTreasuryAddress();

    /// @notice Thrown when zapper address is zero during initialization
    error InvalidZapperAddress();

    /// @notice Thrown when epoch manager address is zero during initialization
    error InvalidEpochManagerAddress();

    /// @notice Thrown when copper price consumer address is zero during initialization
    error InvalidCopperPriceConsumerAddress();

    /// @notice Thrown when USDC address is zero during initialization
    error InvalidUSDCAddress();

    /// @notice Thrown when epoch ID is zero (invalid)
    error ZeroEpochId();

    /// @notice Thrown when epoch ID is in the future
    error FutureEpochId();

    /// @notice Thrown when net revenue is zero or negative
    error ZeroNetRevenue();

    /// @notice Thrown when system fee exceeds maximum allowed (100%)
    error InvalidSystemFee();

    /// @notice Thrown when trying to perform operations on a non-existent epoch
    error EpochDoesNotExist();

    /// @notice Thrown when copper price is stale (older than maximum allowed age)
    error StaleCopperPrice();

    /// @notice Thrown when attempting to mint zero CUP tokens
    error ZeroCupTokensToMint();

    /**
     * @notice Components used to calculate the Net Asset Value (NAV) of the protocol
     * @dev All monetary values are denominated in USDC (6 decimals) and copper amounts in CUP tokens (8 decimals)
     *
     *      NAV Calculation Formula:
     *      Total Assets = (cupInWarehouse + cupInTransit) × copperSpotPrice + retainedEarnings + stablecoinBalance
     *      Net Assets = Total Assets - liabilities
     *      Price Per Share = Net Assets ÷ Total Vault Supply
     *
     *      This structure represents the real-world copper business state including:
     *      - Physical copper inventory valued at current market prices
     *      - Working capital and cash reserves for operations
     *      - Outstanding obligations and debt commitments
     *
     * @param cupInWarehouse Refined copper inventory stored in warehouse (CUP tokens, 8 decimals)
     * @param copperSpotPrice Current copper spot price in USD (8 decimals, e.g., $4.50 = 450,000,000)
     * @param cupInTransit Copper being processed or transported (CUP tokens, 8 decimals)
     * @param retainedEarnings Accumulated profits from previous epochs (USDC, 6 decimals)
     * @param stablecoinBalance Cash/stablecoin reserves available for operations (USDC, 6 decimals)
     * @param liabilities Outstanding obligations and debts (USDC, 6 decimals)
     */
    struct NAVComponents {
        uint256 cupInWarehouse;
        uint256 copperSpotPrice;
        uint256 cupInTransit;
        uint256 retainedEarnings;
        uint256 stablecoinBalance;
        uint256 liabilities;
    }

    /**
     * @notice Revenue data for a specific epoch of copper trading operations
     * @dev Tracks both operational metrics and financial outcomes for analytics and settlement.
     *      Captures one complete copper trading cycle from raw material acquisition through
     *      processing to sales and net profit calculation.
     *
     *      Business Flow:
     *      1. Purchase raw copper/scrap at averagePurchasePrice
     *      2. Process and refine copper (cupPurchased → cupSold)
     *      3. Sell refined copper at averageSalePrice
     *      4. Calculate net revenue after all costs
     *      5. Settle and distribute profits to vault participants
     *
     * @param epochId Unique identifier for the epoch (must be > 0)
     * @param netRevenue Final revenue after all processing and costs (USDC, 6 decimals)
     * @param originalNetRevenue Original revenue amount before distribution, preserved for analytics (USDC, 6 decimals)
     * @param cupPurchased Amount of copper purchased as raw material (CUP tokens, 8 decimals)
     * @param cupSold Amount of refined copper sold to market (CUP tokens, 8 decimals)
     * @param averagePurchasePrice Average purchase price per CUP token (8 decimals)
     * @param averageSalePrice Average sale price per CUP token (8 decimals)
     * @param isSettled Whether the epoch has been settled and revenue distributed
     */
    struct EpochRevenue {
        uint256 epochId;
        uint256 netRevenue;
        uint256 originalNetRevenue;
        uint256 cupPurchased;
        uint256 cupSold;
        uint256 averagePurchasePrice;
        uint256 averageSalePrice;
        bool isSettled;
    }

    /// @notice Basis points denominator (10,000 = 100%)
    /// @dev Used for percentage calculations throughout the contract.
    ///      Examples: 100 = 1%, 500 = 5%, 1000 = 10%, 10000 = 100%
    uint256 public constant BASIS_POINTS = 10_000;

    /// @notice Current Net Asset Value components of the protocol
    /// @dev Stores the latest NAV data including copper inventory, cash reserves, and liabilities.
    ///      Updated by owner through updateNAV() function to reflect real-world business state.
    NAVComponents public _nav;

    /// @notice Mapping of epoch ID to revenue data for tracking and settlement
    /// @dev Stores complete revenue information for each epoch including operational metrics.
    ///      Key: epochId (uint256), Value: EpochRevenue struct with all trading data.
    mapping(uint256 => EpochRevenue) public epochRevenues;

    /// @notice Current epoch ID being tracked
    /// @dev Synchronized with EpochManager contract. Incremented through advanceEpoch().
    ///      Used to validate epoch operations and prevent future epoch manipulation.
    uint256 public _currentEpochId;

    /// @notice Epoch manager contract for time-based operations
    /// @dev Provides epoch timing and validation. Used to ensure epoch operations
    ///      are performed within valid time windows and epoch IDs are current.
    IEpochManager public _epochManager;

    /// @notice ERC4626 vault contract where revenue is distributed
    /// @dev Target for CUP token minting during revenue distribution.
    ///      Increased vault assets make all xCUP shares more valuable for holders.
    IERC4626 public _vault;

    /// @notice Copper price oracle for NAV calculations
    /// @dev Chainlink-based oracle providing real-time copper spot prices.
    ///      Critical for accurate NAV calculations and revenue distribution.
    ICopperPriceConsumer public _copperPriceConsumer;

    /// @notice USDC token contract for revenue handling
    /// @dev Base currency for all revenue operations and fee collection.
    ///      Used for transferring revenue from caller to treasury and zapper.
    IERC20 private _usdc;

    /// @notice System fee percentage in basis points (e.g., 100 = 1%)
    /// @dev Fee deducted from revenue before distribution to vault.
    ///      Collected by treasury for protocol operations and maintenance.
    uint256 public _systemFeeBps;

    /// @notice Treasury address for fee collection
    /// @dev Receives system fees deducted from epoch revenue distributions.
    ///      Used for protocol operations, development, and maintenance costs.
    address public _treasury;

    /// @notice Zapper contract address for revenue transfers
    /// @dev Receives net revenue after fees for further processing.
    ///      Part of the revenue distribution flow to convert USDC to CUP tokens.
    address public _zapper;

    /// @notice Mapping of epoch ID to system fees collected
    /// @dev Tracks fees collected per epoch for transparency and accounting.
    ///      Key: epochId (uint256), Value: fee amount in USDC (6 decimals).
    mapping(uint256 => uint256) public _epochSystemFees;

    /**
     * @notice Emitted when NAV components are updated
     * @dev Fired after successful updateNAV() call with calculated values
     * @param totalNAV Total net asset value in USDC (6 decimals)
     * @param pricePerShare Price per vault share in USDC (6 decimals)
     */
    event NAVUpdated(uint256 totalNAV, uint256 pricePerShare);

    /**
     * @notice Emitted when epoch revenue is recorded
     * @dev Fired when recordEpochRevenue() successfully stores trading data
     * @param epochId The epoch identifier (must be > 0)
     * @param netRevenue Net revenue generated in USDC (6 decimals)
     * @param cupProcessed Amount of copper processed in CUP tokens (8 decimals)
     */
    event EpochRevenueRecorded(uint256 indexed epochId, uint256 netRevenue, uint256 cupProcessed);

    /**
     * @notice Emitted when revenue is distributed to the vault
     * @dev Fired when distributeRevenueToVault() successfully mints CUP tokens
     * @param epochId The epoch identifier
     * @param revenueDistributed Amount of revenue distributed after fees (USDC, 6 decimals)
     * @param distributedCupTokens Amount of CUP tokens minted to the vault (8 decimals)
     * @param systemFee Amount of fees collected for the treasury (USDC, 6 decimals)
     */
    event RevenueDistributed(
        uint256 indexed epochId, uint256 revenueDistributed, uint256 distributedCupTokens, uint256 systemFee
    );

    /**
     * @notice Emitted when a copper operation is completed
     * @dev Fired alongside EpochRevenueRecorded to provide operational metrics
     * @param epochId The epoch identifier
     * @param cupPurchased Amount of copper purchased (CUP tokens, 8 decimals)
     * @param cupSold Amount of copper sold (CUP tokens, 8 decimals)
     * @param netRevenue Net revenue generated from the operation (USDC, 6 decimals)
     */
    event CopperOperationCompleted(uint256 indexed epochId, uint256 cupPurchased, uint256 cupSold, uint256 netRevenue);

    /**
     * @notice Emitted when system fee is updated
     * @param oldFee Previous system fee in basis points
     * @param newFee New system fee in basis points
     */
    event SystemFeeUpdated(uint256 oldFee, uint256 newFee);

    /**
     * @notice Emitted when treasury address is updated
     * @param oldTreasury Previous treasury address
     * @param newTreasury New treasury address
     */
    event TreasuryUpdated(address indexed oldTreasury, address indexed newTreasury);

    /**
     * @notice Emitted when zapper address is updated
     * @param oldZapper Previous zapper address
     * @param newZapper New zapper address
     */
    event ZapperUpdated(address indexed oldZapper, address indexed newZapper);

    /**
     * @notice Emitted when tokens are recovered in emergency
     * @param token Address of the recovered token
     * @param to Address that received the tokens
     * @param amount Amount of tokens recovered
     */
    event EmergencyTokenRecovery(address indexed token, address indexed to, uint256 amount);

    /**
     * @notice Constructor for upgradeable contract
     * @dev Disables initializers to prevent implementation contract initialization
     *      Required for OpenZeppelin upgradeable pattern security
     */
    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /**
     * @notice Initializes the SettlementEngine contract
     * @dev This function replaces the constructor for upgradeable contracts.
     *      Sets up all contract dependencies and grants initial roles.
     *      Can only be called once due to initializer modifier.
     *
     *      Validation:
     *      - All addresses must be non-zero
     *      - systemFeeBps can be 0-10000 (0-100%)
     *
     *      Roles Granted:
     *      - DEFAULT_ADMIN_ROLE to deployer
     *      - REVENUE_MANAGER_ROLE to deployer
     *
     * @param vault Address of the ERC4626 vault contract for revenue distribution
     * @param treasury Address of the treasury for fee collection
     * @param zapper Address of the zapper contract for revenue transfers
     * @param epochManager Address of the epoch manager contract for time validation
     * @param copperPriceConsumer Address of the copper price oracle for NAV calculations
     * @param usdc Address of the USDC token contract for revenue handling
     * @param systemFeeBps System fee percentage in basis points (0-10000, where 10000 = 100%)
     */
    function initialize(
        address vault,
        address treasury,
        address zapper,
        address epochManager,
        address copperPriceConsumer,
        address usdc,
        uint256 systemFeeBps
    ) public initializer {
        if (vault == address(0)) revert InvalidVaultAddress();
        if (treasury == address(0)) revert InvalidTreasuryAddress();
        if (zapper == address(0)) revert InvalidZapperAddress();
        if (epochManager == address(0)) revert InvalidEpochManagerAddress();
        if (copperPriceConsumer == address(0)) revert InvalidCopperPriceConsumerAddress();
        if (usdc == address(0)) revert InvalidUSDCAddress();
        if (systemFeeBps > BASIS_POINTS) revert InvalidSystemFee();

        __Ownable_init(_msgSender());
        __Pausable_init();
        __AccessControl_init();
        __ReentrancyGuard_init();

        // Grant roles
        _grantRole(DEFAULT_ADMIN_ROLE, _msgSender());
        _grantRole(REVENUE_MANAGER_ROLE, _msgSender());

        _vault = IERC4626(vault);
        _treasury = treasury;
        _zapper = zapper;
        _epochManager = IEpochManager(epochManager);
        _copperPriceConsumer = ICopperPriceConsumer(copperPriceConsumer);

        _usdc = IERC20(usdc);

        _currentEpochId = IEpochManager(_epochManager).currentEpochId();
        _systemFeeBps = systemFeeBps;
    }

    /**
     * @notice Updates the Net Asset Value (NAV) components of the protocol
     * @dev Only callable by the contract owner. Calculates total assets and price per share.
     *
     *      Calculation Process:
     *      1. Calculate copper asset value: (cupInWarehouse + cupInTransit) × copperSpotPrice ÷ 1e10
     *      2. Calculate total assets: copperAssetValue + retainedEarnings + stablecoinBalance
     *      3. Calculate net assets: totalAssets - liabilities (minimum 0)
     *      4. Calculate price per share: netAssets × 1e6 ÷ vaultTotalSupply
     *
     *      The division by 1e10 in step 1 converts from:
     *      (CUP tokens × 8 decimals) × (price × 8 decimals) = 16 decimals
     *      to USDC 6 decimals format
     *
     * @param newNav New NAV components including copper inventory, cash, and liabilities
     */
    function updateNAV(NAVComponents calldata newNav) external onlyRole(REVENUE_MANAGER_ROLE) {
        _nav = newNav;

        // Calculate total asset value
        // Copper inventory at current spot price + cash + retained earnings
        uint256 copperAssetValue = ((_nav.cupInWarehouse + _nav.cupInTransit) * _nav.copperSpotPrice) / 1e10;
        uint256 totalAssets = copperAssetValue + _nav.retainedEarnings + _nav.stablecoinBalance;

        // Calculate net assets after liabilities
        uint256 netAssets = totalAssets > _nav.liabilities ? totalAssets - _nav.liabilities : 0;

        // Calculate price per share
        uint256 supply = _vault.totalSupply();
        uint256 pricePerShare = supply == 0 ? 1e6 : (netAssets * 1e6) / supply; // 6 decimal precision

        emit NAVUpdated(netAssets, pricePerShare);
    }

    /**
     * @notice Records revenue data for a completed epoch of copper trading
     * @dev Only callable by addresses with REVENUE_MANAGER_ROLE. Must be called before settlement.
     *      Stores complete trading cycle data for analytics and settlement processing.
     *
     *      Validation:
     *      - epochId must be > 0 and ≤ current epoch from EpochManager
     *      - netRevenue must be > 0
     *      - epoch must not already be settled
     *      - contract must not be paused
     *
     *      Business Flow:
     *      1. Purchase raw copper/scrap at averagePurchasePrice
     *      2. Process and refine copper (efficiency = cupSold/cupPurchased)
     *      3. Sell refined copper at averageSalePrice
     *      4. Calculate net revenue after all operational costs
     *
     * @param epochId Unique identifier for the epoch (must be > 0)
     * @param netRevenue Final net revenue after all costs (USDC, 6 decimals)
     * @param cupPurchased Amount of copper purchased as raw material (CUP tokens, 8 decimals)
     * @param cupSold Amount of refined copper sold (CUP tokens, 8 decimals)
     * @param averagePurchasePrice Average purchase price per CUP token (8 decimals)
     * @param averageSalePrice Average sale price per CUP token (8 decimals)
     */
    function recordEpochRevenue(
        uint256 epochId,
        uint256 netRevenue,
        uint256 cupPurchased,
        uint256 cupSold,
        uint256 averagePurchasePrice,
        uint256 averageSalePrice
    ) external onlyRole(REVENUE_MANAGER_ROLE) whenNotPaused {
        if (epochId == 0) revert ZeroEpochId();
        if (epochId > _epochManager.currentEpochId()) revert FutureEpochId();
        if (epochRevenues[epochId].isSettled) revert EpochAlreadySettled();
        if (netRevenue == 0) revert ZeroNetRevenue();

        epochRevenues[epochId] = EpochRevenue({
            epochId: epochId,
            netRevenue: netRevenue,
            originalNetRevenue: netRevenue,
            cupPurchased: cupPurchased,
            cupSold: cupSold,
            averagePurchasePrice: averagePurchasePrice,
            averageSalePrice: averageSalePrice,
            isSettled: false
        });

        emit EpochRevenueRecorded(epochId, netRevenue, cupSold);
        emit CopperOperationCompleted(epochId, cupPurchased, cupSold, netRevenue);
    }

    /**
     * @notice Settles recorded revenue for an epoch, marking it ready for distribution
     * @dev Only callable by addresses with REVENUE_MANAGER_ROLE. Updates retained earnings for NAV calculation.
     *      This is a critical step that finalizes epoch calculations and prepares for revenue distribution.
     *
     *      Settlement Process:
     *      1. Validates epoch exists and has recorded revenue
     *      2. Ensures epoch is not already settled
     *      3. Marks epoch as settled (prevents re-settlement)
     *      4. Adds net revenue to retained earnings for NAV calculation
     *
     *      After settlement, the epoch is ready for distributeRevenueToVault().
     *
     * @param epochId The epoch ID to settle (must exist and have recorded revenue)
     */
    function settleEpochRevenue(uint256 epochId) external onlyRole(REVENUE_MANAGER_ROLE) whenNotPaused {
        if (epochId > _epochManager.currentEpochId()) revert FutureEpochId();
        EpochRevenue storage revenue = epochRevenues[epochId];
        if (revenue.epochId != epochId) revert EpochRevenueNotFound();
        if (revenue.isSettled) revert EpochAlreadySettled();
        if (revenue.netRevenue == 0) revert NoRevenueToDistribute();

        // Mark as settled
        revenue.isSettled = true;

        // Update retained earnings - this will be reflected in NAV calculation
        _nav.retainedEarnings += revenue.netRevenue;

        // Revenue settlement completed - ready for distribution
        // Note: Actual distribution happens via distributeRevenueToVault()
    }

    /**
     * @notice Calculates the Return on Investment (ROI) for a specific epoch
     * @dev ROI = (Net Revenue ÷ Total Investment) × BASIS_POINTS
     *
     *      Calculation:
     *      - Total Investment = cupPurchased × averagePurchasePrice
     *      - ROI = (originalNetRevenue × 10000) ÷ totalInvestment
     *
     *      Returns 0 if no copper was purchased or total investment is 0.
     *      Uses originalNetRevenue to preserve analytics data even after distribution.
     *
     * @param epochId The epoch ID to calculate ROI for (must exist)
     * @return roi The ROI in basis points (e.g., 1000 = 10%, 5000 = 50%)
     */
    function calculateEpochROI(uint256 epochId) external view returns (uint256 roi) {
        EpochRevenue storage revenue = epochRevenues[epochId];
        if (revenue.epochId != epochId) revert EpochRevenueNotFound();

        if (revenue.cupPurchased > 0) {
            // ROI = (Net Revenue / Total Investment) * 100
            uint256 totalInvestment = revenue.cupPurchased * revenue.averagePurchasePrice;
            if (totalInvestment > 0) {
                roi = (revenue.originalNetRevenue * BASIS_POINTS) / totalInvestment; // Basis points
            }
        }
    }

    /**
     * @notice Retrieves revenue data for a specific epoch
     * @dev Returns complete EpochRevenue struct with all trading and financial data.
     *      Useful for analytics, reporting, and integration with external systems.
     *
     * @param epochId The epoch ID to query
     * @return The complete EpochRevenue struct for the specified epoch
     */
    function getEpochRevenue(uint256 epochId) external view returns (EpochRevenue memory) {
        return epochRevenues[epochId];
    }

    /**
     * @notice Provides a summary of current NAV calculations
     * @dev Calculates total assets, net assets, and price per share based on current NAV components.
     *      Uses the same calculation logic as updateNAV() but without modifying state.
     *
     *      Calculation Process:
     *      1. Calculate copper asset value: (cupInWarehouse + cupInTransit) × copperSpotPrice ÷ 1e10
     *      2. Calculate total assets: copperAssetValue + retainedEarnings + stablecoinBalance
     *      3. Calculate net assets: max(totalAssets - liabilities, 0)
     *      4. Calculate price per share: netAssets × 1e6 ÷ vaultTotalSupply (or 1e6 if supply is 0)
     *
     * @return totalAssets Total asset value including copper inventory (USDC, 6 decimals)
     * @return netAssets Net assets after subtracting liabilities (USDC, 6 decimals)
     * @return pricePerShare Price per vault share (USDC, 6 decimals)
     */
    function getNAVSummary() external view returns (uint256 totalAssets, uint256 netAssets, uint256 pricePerShare) {
        // Calculate total asset value including copper inventory
        uint256 copperAssetValue = ((_nav.cupInWarehouse + _nav.cupInTransit) * _nav.copperSpotPrice) / 1e10;
        totalAssets = copperAssetValue + _nav.retainedEarnings + _nav.stablecoinBalance;

        // Calculate net assets after liabilities
        netAssets = totalAssets > _nav.liabilities ? totalAssets - _nav.liabilities : 0;

        // Calculate price per share in USD (6 decimals)
        // netAssets: USD (6 decimals), supply: vault shares (6 decimals)
        // Result: USD per share (6 decimals)
        uint256 supply = _vault.totalSupply();
        pricePerShare = supply == 0 ? 1e6 : (netAssets * 1e6) / supply;
    }

    /**
     * @notice Retrieves revenue data for the current epoch
     * @dev Returns revenue data for the epoch ID stored in _currentEpochId.
     *      May return empty struct if no revenue has been recorded for current epoch.
     *
     * @return The EpochRevenue struct for the current epoch
     */
    function getCurrentEpochRevenue() external view returns (EpochRevenue memory) {
        return epochRevenues[_currentEpochId];
    }

    /**
     * @notice Advances to the next epoch and syncs with EpochManager
     * @dev Only callable by the contract owner. Updates internal epoch tracking.
     *      Increments _currentEpochId and synchronizes with EpochManager if needed.
     *
     *      Synchronization Logic:
     *      1. Increment internal _currentEpochId
     *      2. Get current epoch from EpochManager
     *      3. If they don't match, use EpochManager's epoch as authoritative
     */
    function advanceEpoch() external onlyOwner {
        _currentEpochId++;

        // Sync with EpochManager if needed
        uint256 managerEpochId = _epochManager.currentEpochId();
        if (_currentEpochId != managerEpochId) {
            _currentEpochId = managerEpochId;
        }
    }

    /**
     * @notice Calculates the efficiency ratio of copper processing for a specific epoch
     * @dev Efficiency = (cupSold ÷ cupPurchased) × BASIS_POINTS
     *
     *      Measures how much refined copper was produced from raw materials.
     *      Efficiency < 10000 indicates processing losses (normal in copper refining).
     *      Efficiency = 10000 indicates perfect conversion (100%).
     *
     *      Returns 0 if no copper was purchased for the epoch.
     *
     * @param epochId The epoch ID to analyze (must exist)
     * @return efficiency Processing efficiency in basis points (10000 = 100%)
     */
    function getCopperProcessingEfficiency(uint256 epochId) external view returns (uint256 efficiency) {
        EpochRevenue storage revenue = epochRevenues[epochId];
        if (revenue.epochId != epochId) revert EpochRevenueNotFound();

        if (revenue.cupPurchased > 0) {
            // Efficiency = (cupSold / cupPurchased) * 10000
            efficiency = (revenue.cupSold * BASIS_POINTS) / revenue.cupPurchased;
        }
    }

    /**
     * @notice Calculates the profit margin for a specific epoch
     * @dev Margin = (Net Revenue ÷ Total Sales Value) × BASIS_POINTS
     *
     *      Calculation:
     *      - Total Sales Value = cupSold × averageSalePrice
     *      - Margin = (originalNetRevenue × 10000) ÷ totalSalesValue
     *
     *      Measures profitability as percentage of sales revenue.
     *      Higher margins indicate better operational efficiency.
     *
     *      Returns 0 if no copper was sold or sale price is 0.
     *      Uses originalNetRevenue to preserve analytics data.
     *
     * @param epochId The epoch ID to analyze (must exist)
     * @return margin Profit margin in basis points (10000 = 100%)
     */
    function getProfitMargin(uint256 epochId) external view returns (uint256 margin) {
        EpochRevenue storage revenue = epochRevenues[epochId];
        if (revenue.epochId != epochId) revert EpochRevenueNotFound();

        if (revenue.cupSold > 0 && revenue.averageSalePrice > 0) {
            uint256 totalSalesValue = revenue.cupSold * revenue.averageSalePrice;
            if (totalSalesValue > 0) {
                margin = (revenue.originalNetRevenue * BASIS_POINTS) / totalSalesValue;
            }
        }
    }

    /**
     * @notice Distributes epoch revenue by minting CUP tokens to the vault
     * @dev This function increases the vault's total assets, making all xCUP shares more valuable.
     *      Only callable by addresses with REVENUE_MANAGER_ROLE when contract is not paused.
     *
     *      Distribution Process:
     *      1. Validate epoch is settled and has revenue to distribute
     *      2. Calculate system fees and net revenue after fees
     *      3. Transfer total revenue in USDC from caller to contract
     *      4. Transfer system fees to treasury
     *      5. Transfer net revenue to zapper for processing
     *      6. Get current copper price from oracle
     *      7. Calculate CUP tokens to mint: (netRevenue × 1e8) ÷ copperPrice
     *      8. Mint CUP tokens directly to vault (increases vault assets)
     *      9. Mark revenue as distributed (set netRevenue to 0)
     *
     *      The CUP token minting increases vault's totalAssets(), making all xCUP shares
     *      more valuable proportionally. This is how vault participants benefit from profits.
     *
     * @param epochId The epoch ID to distribute revenue for (must be settled)
     */
    function distributeRevenueToVault(uint256 epochId)
        external
        onlyRole(REVENUE_MANAGER_ROLE)
        whenNotPaused
        nonReentrant
    {
        if (epochId > _epochManager.currentEpochId()) revert FutureEpochId();
        EpochRevenue storage revenue = epochRevenues[epochId];

        if (revenue.epochId != epochId) revert EpochRevenueNotFound();
        if (!revenue.isSettled) revert EpochNotSettled();
        if (revenue.netRevenue == 0) revert NoRevenueToDistribute();

        // Calculate fees
        uint256 totalRevenue = revenue.netRevenue;
        uint256 systemFee = (totalRevenue * _systemFeeBps) / BASIS_POINTS;
        uint256 netRevenueAfterFees = totalRevenue - systemFee;

        // Store fees for this epoch
        _epochSystemFees[epochId] = systemFee;

        // Transfer revenue in USDC from caller
        _usdc.safeTransferFrom(msg.sender, address(this), totalRevenue);

        // Transfer fees to treasury
        if (systemFee > 0) {
            _usdc.safeTransfer(_treasury, systemFee);
        }

        // Transfer net revenue to zapper
        _usdc.safeTransfer(_zapper, netRevenueAfterFees);

        // Get the underlying CUP token
        IERC20Mintable cupToken = IERC20Mintable(_vault.asset());

        uint256 copperPriceUSD = _copperPriceConsumer.getPriceAsDecimal();

        if (copperPriceUSD == 0) revert InvalidCopperPrice();

        // Convert net revenue (after fees) to CUP tokens
        // revenueUSD: 6 decimals (e.g., 1000 USDC = 1,000,000,000)
        // copperPriceUSD: 8 decimals (e.g., $4.50 = 450,000,000)
        //
        // Formula: cupTokens = (revenueUSD * 10^8) / copperPriceUSD
        uint256 cupTokensToMint = (netRevenueAfterFees * 1e8) / copperPriceUSD;

        // Ensure we're not minting zero tokens (would be a waste of gas)
        if (cupTokensToMint == 0) revert ZeroCupTokensToMint();

        // This requires the SettlementEngine to have MINTER_ROLE on CUP token
        cupToken.mint(address(_vault), cupTokensToMint);

        // Mark revenue as distributed
        revenue.netRevenue = 0; // Prevent double distribution

        emit RevenueDistributed(epochId, netRevenueAfterFees, cupTokensToMint, systemFee);
    }

    /**
     * @notice Retrieves fee information for a specific epoch
     * @dev Returns the system fee amount collected during revenue distribution.
     *      Returns 0 if epoch hasn't been distributed or doesn't exist.
     *
     * @param epochId The epoch ID to query
     * @return systemFee System fee collected for this epoch in USDC (6 decimals)
     */
    function getEpochFees(uint256 epochId) external view returns (uint256 systemFee) {
        systemFee = _epochSystemFees[epochId];
    }

    /**
     * @notice Pauses all contract operations
     * @dev Only callable by the contract owner. Prevents all state-changing operations
     *      except unpause(). Used for emergency situations or maintenance.
     */
    function pause() external onlyOwner {
        _pause();
    }

    /**
     * @notice Unpauses all contract operations
     * @dev Only callable by the contract owner. Restores normal contract functionality
     *      after emergency pause or maintenance period.
     */
    function unpause() external onlyOwner {
        _unpause();
    }

    /**
     * @notice Updates the system fee percentage
     * @dev Only callable by the contract owner. Fee cannot exceed 100% (10000 basis points).
     *      Used to adjust protocol fees for treasury operations.
     *
     * @param newSystemFeeBps New system fee in basis points (0-10000)
     */
    function updateSystemFee(uint256 newSystemFeeBps) external onlyOwner {
        if (newSystemFeeBps > BASIS_POINTS) revert InvalidSystemFee();

        uint256 oldFee = _systemFeeBps;
        _systemFeeBps = newSystemFeeBps;

        emit SystemFeeUpdated(oldFee, newSystemFeeBps);
    }

    /**
     * @notice Updates the treasury address
     * @dev Only callable by the contract owner. Treasury cannot be zero address.
     *
     * @param newTreasury New treasury address for fee collection
     */
    function updateTreasury(address newTreasury) external onlyOwner {
        if (newTreasury == address(0)) revert InvalidTreasuryAddress();

        address oldTreasury = _treasury;
        _treasury = newTreasury;

        emit TreasuryUpdated(oldTreasury, newTreasury);
    }

    /**
     * @notice Updates the zapper contract address
     * @dev Only callable by the contract owner. Zapper cannot be zero address.
     *
     * @param newZapper New zapper contract address
     */
    function updateZapper(address newZapper) external onlyOwner {
        if (newZapper == address(0)) revert InvalidZapperAddress();

        address oldZapper = _zapper;
        _zapper = newZapper;

        emit ZapperUpdated(oldZapper, newZapper);
    }

    /**
     * @notice Reserved storage space for future contract upgrades
     */
    uint256[45] private __gap;
}
