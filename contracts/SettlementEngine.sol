// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Mintable} from "./interfaces/IERC20Mintable.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";

import {IEpochManager} from "./interfaces/IEpochManager.sol";
import {ICopperPriceConsumer} from "./interfaces/ICopperPriceConsumer.sol";

/**
 * @title SettlementEngine
 * @dev This contract handles the settlement of epoch-based copper trading revenues and distributes them
 *      to vault participants through minting CUP tokens. It tracks Net Asset Value (NAV) components
 *      including copper inventory, cash reserves, and liabilities.
 */
contract SettlementEngine is Initializable, OwnableUpgradeable, PausableUpgradeable {
    using SafeERC20 for IERC20;

    /**
     * @notice Components used to calculate the Net Asset Value (NAV) of the protocol
     * @dev All monetary values are denominated in USDC (6 decimals) and copper amounts in CUP tokens (8 decimals)
     * @param cupInWarehouse Refined copper inventory stored in warehouse (CUP tokens)
     * @param copperSpotPrice Current copper spot price in USD (8 decimals, e.g., $4.50 = 450,000,000)
     * @param cupInTransit Copper being processed or transported (CUP tokens)
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
     * @dev Tracks both operational metrics and financial outcomes for analytics and settlement
     * @param epochId Unique identifier for the epoch
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
    uint256 public constant BASIS_POINTS = 10_000;

    /// @notice Current Net Asset Value components of the protocol
    NAVComponents public _nav;

    /// @notice Mapping of epoch ID to revenue data for tracking and settlement
    mapping(uint256 => EpochRevenue) public epochRevenues;

    /// @notice Current epoch ID being tracked
    uint256 public _currentEpochId;

    /// @notice Epoch manager contract for time-based operations
    IEpochManager public _epochManager;

    /// @notice ERC4626 vault contract where revenue is distributed
    IERC4626 public _vault;

    /// @notice Copper price oracle for NAV calculations
    ICopperPriceConsumer public _copperPriceConsumer;

    /// @notice USDC token contract for revenue handling
    IERC20 private _usdc;

    /// @notice System fee percentage in basis points (e.g., 100 = 1%)
    uint256 public _systemFeeBps;

    /// @notice Treasury address for fee collection
    address public _treasury;

    /// @notice Mapping of epoch ID to system fees collected
    mapping(uint256 => uint256) public _epochSystemFees;

    /**
     * @notice Emitted when NAV components are updated
     * @param totalNAV Total net asset value in USDC
     * @param pricePerShare Price per vault share in USDC
     */
    event NAVUpdated(uint256 totalNAV, uint256 pricePerShare);

    /**
     * @notice Emitted when epoch revenue is recorded
     * @param epochId The epoch identifier
     * @param netRevenue Net revenue generated in USDC
     * @param cupProcessed Amount of copper processed in CUP tokens
     */
    event EpochRevenueRecorded(uint256 indexed epochId, uint256 netRevenue, uint256 cupProcessed);

    /**
     * @notice Emitted when revenue is distributed to the vault
     * @param epochId The epoch identifier
     * @param revenueDistributed Amount of revenue distributed after fees
     * @param distributedCupTokens Amount of CUP tokens minted to the vault
     * @param systemFee Amount of fees collected for the treasury
     */
    event RevenueDistributed(
        uint256 indexed epochId,
        uint256 revenueDistributed,
        uint256 distributedCupTokens,
        uint256 systemFee
    );

    /**
     * @notice Emitted when a copper operation is completed
     * @param epochId The epoch identifier
     * @param cupPurchased Amount of copper purchased
     * @param cupSold Amount of copper sold
     * @param netRevenue Net revenue generated from the operation
     */
    event CopperOperationCompleted(uint256 indexed epochId, uint256 cupPurchased, uint256 cupSold, uint256 netRevenue);

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /**
     * @notice Initializes the SettlementEngine contract
     * @dev This function replaces the constructor for upgradeable contracts
     * @param vault Address of the ERC4626 vault contract
     * @param treasury Address of the treasury for fee collection
     * @param epochManager Address of the epoch manager contract
     * @param copperPriceConsumer Address of the copper price oracle
     * @param usdc Address of the USDC token contract
     * @param systemFeeBps System fee percentage in basis points
     */
    function initialize(
        address vault,
        address treasury,
        address epochManager,
        address copperPriceConsumer,
        address usdc,
        uint256 systemFeeBps
    ) public initializer {
        require(vault != address(0), "Invalid Vault address");
        require(treasury != address(0), "Invalid Treasury address");
        require(epochManager != address(0), "Invalid Epoch Manager address");
        require(copperPriceConsumer != address(0), "Invalid Copper Price Consumer address");
        require(usdc != address(0), "Invalid USDC address");

        __Ownable_init(_msgSender());
        __Pausable_init();

        _vault = IERC4626(vault);
        _treasury = treasury;
        _epochManager = IEpochManager(epochManager);
        _copperPriceConsumer = ICopperPriceConsumer(copperPriceConsumer);

        _usdc = IERC20(usdc);

        _currentEpochId = IEpochManager(_epochManager).currentEpochId();
        _systemFeeBps = systemFeeBps;
    }

    /**
     * @notice Updates the Net Asset Value (NAV) components of the protocol
     * @dev Only callable by the contract owner. Calculates total assets and price per share
     * @param newNav New NAV components including copper inventory, cash, and liabilities
     */
    function updateNAV(NAVComponents calldata newNav) external onlyOwner {
        _nav = newNav;

        // Calculate total asset value
        // Copper inventory at current spot price + cash + retained earnings
        uint256 copperAssetValue = (_nav.cupInWarehouse + _nav.cupInTransit) * _nav.copperSpotPrice;
        uint256 totalAssets = copperAssetValue + _nav.retainedEarnings + _nav.stablecoinBalance;

        // Calculate net assets after liabilities
        uint256 netAssets = totalAssets > _nav.liabilities ? totalAssets - _nav.liabilities : 0;

        // Calculate price per share
        uint256 supply = _vault.totalSupply();
        uint256 pricePerShare = supply == 0 ? 1e18 : (netAssets * 1e18) / supply; // 18 decimal precision

        emit NAVUpdated(netAssets, pricePerShare);
    }

    /**
     * @notice Records revenue data for a completed epoch of copper trading
     * @dev Only callable by the contract owner. Must be called before settlement
     * @param epochId Unique identifier for the epoch
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
    ) external onlyOwner {
        require(epochId > 0, "Invalid epoch ID");
        require(!epochRevenues[epochId].isSettled, "Epoch already settled");
        require(netRevenue > 0, "Net revenue must be positive");

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
     * @dev Only callable by the contract owner. Updates retained earnings for NAV calculation
     * @param epochId The epoch ID to settle
     */
    function settleEpochRevenue(uint256 epochId) external onlyOwner {
        EpochRevenue storage revenue = epochRevenues[epochId];
        require(revenue.epochId == epochId, "Epoch revenue not found");
        require(!revenue.isSettled, "Epoch already settled");
        require(revenue.netRevenue > 0, "No revenue to distribute");

        // Mark as settled
        revenue.isSettled = true;

        // Update retained earnings - this will be reflected in NAV calculation
        _nav.retainedEarnings += revenue.netRevenue;

        // Revenue settlement completed - ready for distribution
        // Note: Actual distribution happens via distributeRevenueToVault()
    }

    /**
     * @notice Calculates the Return on Investment (ROI) for a specific epoch
     * @dev ROI = (Net Revenue / Total Investment) * BASIS_POINTS
     * @param epochId The epoch ID to calculate ROI for
     * @return roi The ROI in basis points (e.g., 1000 = 10%)
     */
    function calculateEpochROI(uint256 epochId) external view returns (uint256 roi) {
        EpochRevenue storage revenue = epochRevenues[epochId];
        require(revenue.epochId == epochId, "Epoch revenue not found");

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
     * @param epochId The epoch ID to query
     * @return The complete EpochRevenue struct for the specified epoch
     */
    function getEpochRevenue(uint256 epochId) external view returns (EpochRevenue memory) {
        return epochRevenues[epochId];
    }

    /**
     * @notice Provides a summary of current NAV calculations
     * @dev Calculates total assets, net assets, and price per share based on current NAV components
     * @return totalAssets Total asset value including copper inventory (USDC, 6 decimals)
     * @return netAssets Net assets after subtracting liabilities (USDC, 6 decimals)
     * @return pricePerShare Price per vault share (USDC, 6 decimals)
     */
    function getNAVSummary() external view returns (uint256 totalAssets, uint256 netAssets, uint256 pricePerShare) {
        // Calculate total asset value including copper inventory
        uint256 copperAssetValue = (_nav.cupInWarehouse + _nav.cupInTransit) * _nav.copperSpotPrice;
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
     * @return The EpochRevenue struct for the current epoch
     */
    function getCurrentEpochRevenue() external view returns (EpochRevenue memory) {
        return epochRevenues[_currentEpochId];
    }

    /**
     * @notice Advances to the next epoch and syncs with EpochManager
     * @dev Only callable by the contract owner. Updates internal epoch tracking
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
     * @dev Efficiency = (cupSold / cupPurchased) * BASIS_POINTS
     * @param epochId The epoch ID to analyze
     * @return efficiency Processing efficiency in basis points (10000 = 100%)
     */
    function getCopperProcessingEfficiency(uint256 epochId) external view returns (uint256 efficiency) {
        EpochRevenue storage revenue = epochRevenues[epochId];
        require(revenue.epochId == epochId, "Epoch revenue not found");

        if (revenue.cupPurchased > 0) {
            // Efficiency = (cupSold / cupPurchased) * 10000
            efficiency = (revenue.cupSold * BASIS_POINTS) / revenue.cupPurchased;
        }
    }

    /**
     * @notice Calculates the profit margin for a specific epoch
     * @dev Margin = (Net Revenue / Total Sales Value) * BASIS_POINTS
     * @param epochId The epoch ID to analyze
     * @return margin Profit margin in basis points (10000 = 100%)
     */
    function getProfitMargin(uint256 epochId) external view returns (uint256 margin) {
        EpochRevenue storage revenue = epochRevenues[epochId];
        require(revenue.epochId == epochId, "Epoch revenue not found");

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
     *      Revenue is first collected in USDC, system fees are deducted and sent to treasury,
     *      then the net revenue is burned and equivalent CUP tokens are minted to the vault.
     * @param epochId The epoch ID to distribute revenue for
     */
    function distributeRevenueToVault(uint256 epochId) external onlyOwner {
        EpochRevenue storage revenue = epochRevenues[epochId];

        require(revenue.epochId == epochId, "Epoch revenue not found");
        require(revenue.isSettled, "Epoch not yet settled");
        require(revenue.netRevenue > 0, "No revenue to distribute");

        // Calculate fees
        uint256 totalRevenue = revenue.netRevenue;
        uint256 systemFee = (totalRevenue * _systemFeeBps) / BASIS_POINTS;
        uint256 netRevenueAfterFees = totalRevenue - systemFee;

        // Store fees for this epoch
        _epochSystemFees[epochId] = systemFee;

        // Transfer revenue in USDC and burn to maintain business logic
        _usdc.safeTransferFrom(msg.sender, address(this), totalRevenue);

        // Burn the net revenue amount (after fees)
        IERC20Mintable(address(_usdc)).burn(netRevenueAfterFees);

        // Transfer fees to treasury
        if (systemFee > 0) {
            _usdc.safeTransfer(_treasury, systemFee);
        }

        // Get the underlying CUP token
        IERC20Mintable cupToken = IERC20Mintable(_vault.asset());

        uint256 copperPriceUSD = _copperPriceConsumer.getPriceAsDecimal();

        require(copperPriceUSD > 0, "Invalid copper price");

        // Convert net revenue (after fees) to CUP tokens
        // revenueUSD: 6 decimals (e.g., 1000 USDC = 1,000,000,000)
        // copperPriceUSD: 8 decimals (e.g., $4.50 = 450,000,000)
        //
        // Formula: cupTokens = (revenueUSD * 10^8) / copperPriceUSD
        uint256 cupTokensToMint = (netRevenueAfterFees * 1e8) / copperPriceUSD;

        // This requires the SettlementEngine to have MINTER_ROLE on CUP token
        cupToken.mint(address(_vault), cupTokensToMint);

        // Mark revenue as distributed
        revenue.netRevenue = 0; // Prevent double distribution

        emit RevenueDistributed(epochId, netRevenueAfterFees, cupTokensToMint, systemFee);
    }

    /**
     * @notice Retrieves fee information for a specific epoch
     * @param epochId The epoch ID to query
     * @return systemFee System fee collected for this epoch in USDC
     */
    function getEpochFees(uint256 epochId) external view returns (uint256 systemFee) {
        systemFee = _epochSystemFees[epochId];
    }

    /**
     * @notice Pauses all contract operations
     * @dev Only callable by the contract owner
     */
    function pause() external onlyOwner {
        _pause();
    }

    /**
     * @notice Unpauses all contract operations
     * @dev Only callable by the contract owner
     */
    function unpause() external onlyOwner {
        _unpause();
    }
}
