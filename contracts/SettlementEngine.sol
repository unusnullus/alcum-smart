// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Mintable} from "./interfaces/IERC20Mintable.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";

import {IEpochManager} from "./interfaces/IEpochManager.sol";

contract SettlementEngine is Ownable {
    struct NAVComponents {
        uint256 cupInWarehouse; // Refined copper inventory (in warehouse)
        uint256 copperSpotPrice; // Current copper spot price
        uint256 cupInTransit; // Copper being processed/transported
        uint256 retainedEarnings; // Accumulated profits from epochs
        uint256 stablecoinBalance; // Cash/stablecoin reserves
        uint256 liabilities; // Outstanding obligations
    }

    struct EpochRevenue {
        uint256 epochId;
        uint256 netRevenue; // Final revenue after all processing and costs
        uint256 cupPurchased; // Amount of copper purchased as raw material
        uint256 cupSold; // Amount of refined copper sold
        uint256 averagePurchasePrice; // Average purchase price per unit
        uint256 averageSalePrice; // Average sale price per unit
        bool isSettled;
    }

    NAVComponents public _nav;

    // Epoch revenue tracking
    mapping(uint256 => EpochRevenue) public epochRevenues;
    uint256 public _currentEpochId;

    address public _treasury;
    IEpochManager public _epochManager;
    IERC4626 public _vault;

    event NAVUpdated(uint256 totalNAV, uint256 pricePerShare);
    event EpochRevenueRecorded(uint256 indexed epochId, uint256 netRevenue, uint256 cupProcessed);
    event RevenueDistributed(uint256 indexed epochId, uint256 revenueDistributed);
    event CopperOperationCompleted(uint256 indexed epochId, uint256 cupPurchased, uint256 cupSold, uint256 netRevenue);

    constructor(address vault, address treasury, address epochManager) Ownable(_msgSender()) {
        require(vault != address(0), "Invalid Vault address");
        require(treasury != address(0), "Invalid Treasury address");
        require(epochManager != address(0), "Invalid Epoch Manager address");

        _vault = IERC4626(vault);
        _treasury = treasury;
        _epochManager = IEpochManager(epochManager);

        _currentEpochId = IEpochManager(_epochManager).currentEpochId();
    }

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
            cupPurchased: cupPurchased,
            cupSold: cupSold,
            averagePurchasePrice: averagePurchasePrice,
            averageSalePrice: averageSalePrice,
            isSettled: false
        });

        emit EpochRevenueRecorded(epochId, netRevenue, cupSold);
        emit CopperOperationCompleted(epochId, cupPurchased, cupSold, netRevenue);
    }

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

    function calculateEpochROI(uint256 epochId) external view returns (uint256 roi) {
        EpochRevenue storage revenue = epochRevenues[epochId];
        require(revenue.epochId == epochId, "Epoch revenue not found");

        if (revenue.cupPurchased > 0) {
            // ROI = (Net Revenue / Total Investment) * 100
            uint256 totalInvestment = revenue.cupPurchased * revenue.averagePurchasePrice;
            if (totalInvestment > 0) {
                roi = (revenue.netRevenue * 10000) / totalInvestment; // Basis points
            }
        }
    }

    function getEpochRevenue(uint256 epochId) external view returns (EpochRevenue memory) {
        return epochRevenues[epochId];
    }

    function getNAVSummary() external view returns (uint256 totalAssets, uint256 netAssets, uint256 pricePerShare) {
        // Calculate total asset value including copper inventory
        uint256 copperAssetValue = (_nav.cupInWarehouse + _nav.cupInTransit) * _nav.copperSpotPrice;
        totalAssets = copperAssetValue + _nav.retainedEarnings + _nav.stablecoinBalance;

        // Calculate net assets after liabilities
        netAssets = totalAssets > _nav.liabilities ? totalAssets - _nav.liabilities : 0;

        // Calculate price per share with proper precision
        uint256 supply = _vault.totalSupply();
        pricePerShare = supply == 0 ? 1e18 : (netAssets * 1e18) / supply;
    }

    function getCurrentEpochRevenue() external view returns (EpochRevenue memory) {
        return epochRevenues[_currentEpochId];
    }

    function advanceEpoch() external onlyOwner {
        _currentEpochId++;

        // Sync with EpochManager if needed
        uint256 managerEpochId = _epochManager.currentEpochId();
        if (_currentEpochId != managerEpochId) {
            _currentEpochId = managerEpochId;
        }
    }

    /// @notice Get the efficiency ratio of copper processing for an epoch
    /// @param epochId The epoch ID to analyze
    /// @return efficiency Processing efficiency in basis points (10000 = 100%)
    function getCopperProcessingEfficiency(uint256 epochId) external view returns (uint256 efficiency) {
        EpochRevenue storage revenue = epochRevenues[epochId];
        require(revenue.epochId == epochId, "Epoch revenue not found");

        if (revenue.cupPurchased > 0) {
            // Efficiency = (cupSold / cupPurchased) * 10000
            efficiency = (revenue.cupSold * 10000) / revenue.cupPurchased;
        }
    }

    /// @notice Get the profit margin for an epoch
    /// @param epochId The epoch ID to analyze
    /// @return margin Profit margin in basis points (10000 = 100%)
    function getProfitMargin(uint256 epochId) external view returns (uint256 margin) {
        EpochRevenue storage revenue = epochRevenues[epochId];
        require(revenue.epochId == epochId, "Epoch revenue not found");

        if (revenue.cupSold > 0 && revenue.averageSalePrice > 0) {
            uint256 totalSalesValue = revenue.cupSold * revenue.averageSalePrice;
            if (totalSalesValue > 0) {
                margin = (revenue.netRevenue * 10000) / totalSalesValue;
            }
        }
    }

    /// @notice Distribute revenue by minting new CUP tokens to the vault
    /// @dev This increases totalAssets() of the vault, making all xCUP shares more valuable
    function distributeRevenueToVault(uint256 epochId) external onlyOwner {
        EpochRevenue storage revenue = epochRevenues[epochId];

        require(revenue.epochId == epochId, "Epoch revenue not found");
        require(revenue.isSettled, "Epoch not yet settled");
        require(revenue.netRevenue > 0, "No revenue to distribute");

        // Get the underlying CUP token
        IERC20Mintable cupToken = IERC20Mintable(_vault.asset());

        // Mint new CUP tokens equivalent to the net revenue
        // This requires the SettlementEngine to have MINTER_ROLE on CUP token
        cupToken.mint(address(_vault), revenue.netRevenue);

        // Store original revenue amount for event
        uint256 distributedAmount = revenue.netRevenue;

        // Mark revenue as distributed
        revenue.netRevenue = 0; // Prevent double distribution

        emit RevenueDistributed(epochId, distributedAmount);
    }
}
