// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";

import {IEpochManager} from "./interfaces/IEpochManager.sol";

contract SettlementEngine is Ownable {
    struct NAVComponents {
        uint256 cupInWarehouse;
        uint256 copperSpotPrice;
        uint256 cupInTransit;
        uint256 retainedEarnings;
        uint256 stablecoinBalance;
        uint256 liabilities;
    }

    struct EpochRevenue {
        uint256 epochId;
        uint256 totalRevenue;
        uint256 processingCosts;
        uint256 logisticsCosts;
        uint256 tradingCosts;
        uint256 netProfit;
        uint256 cupPurchased;
        uint256 cupSold;
        uint256 averagePurchasePrice;
        uint256 averageSalePrice;
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
    event EpochRevenueRecorded(uint256 indexed epochId, uint256 totalRevenue, uint256 netProfit);
    event RevenueDistributed(uint256 indexed epochId, uint256 totalDistributed, uint256 sharesMinted);

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
        uint256 totalAssets = (_nav.cupInWarehouse * _nav.copperSpotPrice) +
            _nav.cupInTransit +
            _nav.retainedEarnings +
            _nav.stablecoinBalance;
        uint256 netAssets = totalAssets - _nav.liabilities;
        uint256 supply = _vault.totalSupply();
        uint256 pricePerShare = supply == 0 ? 0 : netAssets / supply;

        emit NAVUpdated(netAssets, pricePerShare);
    }

    function recordEpochRevenue(
        uint256 epochId,
        uint256 totalRevenue,
        uint256 processingCosts,
        uint256 logisticsCosts,
        uint256 tradingCosts,
        uint256 cupPurchased,
        uint256 cupSold,
        uint256 averagePurchasePrice,
        uint256 averageSalePrice
    ) external onlyOwner {
        require(epochId > 0, "Invalid epoch ID");
        require(!epochRevenues[epochId].isSettled, "Epoch already settled");

        uint256 netProfit = totalRevenue - processingCosts - logisticsCosts - tradingCosts;

        epochRevenues[epochId] = EpochRevenue({
            epochId: epochId,
            totalRevenue: totalRevenue,
            processingCosts: processingCosts,
            logisticsCosts: logisticsCosts,
            tradingCosts: tradingCosts,
            netProfit: netProfit,
            cupPurchased: cupPurchased,
            cupSold: cupSold,
            averagePurchasePrice: averagePurchasePrice,
            averageSalePrice: averageSalePrice,
            isSettled: false
        });

        emit EpochRevenueRecorded(epochId, totalRevenue, netProfit);
    }

    function settleEpochRevenue(uint256 epochId) external onlyOwner {
        EpochRevenue storage revenue = epochRevenues[epochId];
        require(revenue.epochId == epochId, "Epoch revenue not found");
        require(!revenue.isSettled, "Epoch already settled");
        require(revenue.netProfit > 0, "No profit to distribute");

        // Mark as settled
        revenue.isSettled = true;

        // Calculate shares to mint based on profit
        uint256 totalSupply = _vault.totalSupply();
        uint256 sharesToMint = 0;

        if (totalSupply > 0) {
            // Calculate shares based on profit ratio
            uint256 totalAssets = (_nav.cupInWarehouse * _nav.copperSpotPrice) +
                _nav.cupInTransit +
                _nav.retainedEarnings +
                _nav.stablecoinBalance;

            if (totalAssets > 0) {
                sharesToMint = (revenue.netProfit * totalSupply) / totalAssets;
            }
        }

        if (revenue.netProfit > 0) {
            // Distribute revenue to xCUP holders
            // This increases the value of existing shares through revenue distribution
            // We need to cast to xCUP to call distributeRevenue
            // For now, we'll store the profit for later distribution
            // The actual distribution will be handled by a separate function
        }

        emit RevenueDistributed(epochId, revenue.netProfit, sharesToMint);
    }

    function calculateEpochROI(uint256 epochId) external view returns (uint256 roi) {
        EpochRevenue storage revenue = epochRevenues[epochId];
        require(revenue.epochId == epochId, "Epoch revenue not found");

        if (revenue.cupPurchased > 0) {
            // ROI = (Net Profit / Total Investment) * 100
            uint256 totalInvestment = revenue.cupPurchased * revenue.averagePurchasePrice;
            if (totalInvestment > 0) {
                roi = (revenue.netProfit * 10000) / totalInvestment; // Basis points
            }
        }
    }

    function getEpochRevenue(uint256 epochId) external view returns (EpochRevenue memory) {
        return epochRevenues[epochId];
    }

    function getNAVSummary() external view returns (uint256 totalAssets, uint256 netAssets, uint256 pricePerShare) {
        totalAssets =
            (_nav.cupInWarehouse * _nav.copperSpotPrice) +
            _nav.cupInTransit +
            _nav.retainedEarnings +
            _nav.stablecoinBalance;
        netAssets = totalAssets - _nav.liabilities;
        uint256 supply = _vault.totalSupply();
        pricePerShare = supply == 0 ? 0 : netAssets / supply;
    }

    function getCurrentEpochRevenue() external view returns (EpochRevenue memory) {
        return epochRevenues[currentEpochId];
    }

    function advanceEpoch() external onlyOwner {
        currentEpochId++;
    }

    function distributeRevenueToVault(uint256 epochId) external onlyOwner {
        EpochRevenue storage revenue = epochRevenues[epochId];
        require(revenue.epochId == epochId, "Epoch revenue not found");
        require(revenue.isSettled, "Epoch not yet settled");
        require(revenue.netProfit > 0, "No profit to distribute");

        // Cast to xCUP contract to call distributeRevenue
        // This is a simplified approach - in production you'd want proper interface
        bytes memory callData = abi.encodeWithSignature(
            "distributeRevenue(uint256,uint256)",
            epochId,
            revenue.netProfit
        );

        (bool success, ) = address(_vault).call(callData);
        require(success, "Revenue distribution failed");
    }
}
