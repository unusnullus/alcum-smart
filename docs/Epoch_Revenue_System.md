# Epoch Revenue Calculation System

## Overview

The Alcum Copper Bank (ACB) epoch revenue calculation system tracks and distributes profits from copper trading operations across 30-day investment cycles (epochs). This system ensures transparent and fair distribution of profits to xCUP token holders based on their proportional ownership.

## Architecture Components

### 1. SettlementEngine
The core component responsible for:
- Recording epoch revenue data
- Calculating net profits
- Managing NAV (Net Asset Value) updates
- Coordinating revenue distribution

### 2. xCUP (ERC4626 Vault)
The investment token that:
- Tracks revenue per share for each epoch
- Manages user revenue claims
- Distributes profits to token holders

### 3. EpochManager
Manages the 30-day investment cycles and ensures proper epoch transitions.

## Revenue Calculation Process

### Step 1: Revenue Recording
At the end of each epoch, the SettlementEngine records comprehensive revenue data:

```solidity
struct EpochRevenue {
    uint256 epochId;
    uint256 totalRevenue;        // Total revenue from copper sales
    uint256 processingCosts;     // Costs for copper processing
    uint256 logisticsCosts;      // Transportation and storage costs
    uint256 tradingCosts;        // Trading and transaction costs
    uint256 netProfit;           // Calculated net profit
    uint256 cupPurchased;        // Amount of CUP purchased
    uint256 cupSold;             // Amount of CUP sold
    uint256 averagePurchasePrice; // Average purchase price per CUP
    uint256 averageSalePrice;    // Average sale price per CUP
    bool isSettled;              // Settlement status
}
```

### Step 2: Profit Calculation
Net profit is calculated as:
```
Net Profit = Total Revenue - Processing Costs - Logistics Costs - Trading Costs
```

### Step 3: Revenue Distribution
Profits are distributed proportionally to xCUP holders based on their share ownership:

```solidity
Revenue Per Share = Net Profit / Total xCUP Supply
User Revenue = User Shares × Revenue Per Share
```

## Business Model Integration

### Copper Trading Cycle
1. **Purchase Phase**: Buy copper scrap/concentrate at market prices
2. **Processing Phase**: Refine copper to 99.9%+ purity
3. **Sales Phase**: Sell refined copper at premium prices
4. **Profit Distribution**: Distribute profits to xCUP holders

### Example Scenario
- **Investment**: User deposits 10 USDC (equivalent to 1.2 tons of copper scrap)
- **Processing**: 1.2 tons of scrap → 1.2 tons of refined copper
- **Sales**: 1.2 tons sold at premium price (equivalent to 1.7 tons of scrap)
- **Profit**: After costs, equivalent to 1.3 tons of scrap
- **Distribution**: Profit increases xCUP value for all holders

## Key Functions

### SettlementEngine Functions

#### `recordEpochRevenue()`
Records comprehensive revenue data for an epoch:
```solidity
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
) external onlyOwner
```

#### `settleEpochRevenue()`
Finalizes epoch calculations and prepares for distribution:
```solidity
function settleEpochRevenue(uint256 epochId) external onlyOwner
```

#### `calculateEpochROI()`
Calculates Return on Investment for an epoch:
```solidity
function calculateEpochROI(uint256 epochId) external view returns (uint256 roi)
```

### xCUP Functions

#### `distributeRevenue()`
Distributes revenue to all xCUP holders:
```solidity
function distributeRevenue(uint256 epochId, uint256 totalRevenue) external onlySettlementEngine
```

#### `claimRevenue()`
Allows users to claim their share of epoch revenue:
```solidity
function claimRevenue(uint256 epochId) external returns (uint256 claimedAmount)
```

#### `getClaimableRevenue()`
View function to check claimable revenue for a specific epoch:
```solidity
function getClaimableRevenue(address user, uint256 epochId) external view returns (uint256)
```

## Revenue Distribution Flow

1. **Epoch End**: Business operations complete for the 30-day period
2. **Revenue Recording**: SettlementEngine records all revenue and cost data
3. **Profit Calculation**: Net profit is calculated after deducting all costs
4. **Settlement**: Epoch is marked as settled and ready for distribution
5. **Distribution**: Revenue is distributed to xCUP vault
6. **User Claims**: Users can claim their proportional share of revenue

## ROI Calculation

The system calculates ROI (Return on Investment) for each epoch:

```
ROI = (Net Profit / Total Investment) × 100
```

Where:
- **Net Profit**: Revenue minus all costs
- **Total Investment**: Value of CUP purchased during the epoch

## Security Features

### Access Control
- Only owner can record and settle epoch revenue
- Only SettlementEngine can distribute revenue to xCUP
- Users can only claim their own revenue

### Validation Checks
- Epoch revenue can only be recorded once
- Revenue can only be distributed after settlement
- Users cannot claim revenue twice for the same epoch

### Transparency
- All revenue data is publicly viewable
- Revenue per share calculations are transparent
- Users can verify their claimable amounts

## Integration with Existing System

### Zapper Integration
- Users deposit through Zapper
- Zapper converts to CUP and deposits in xCUP vault
- Revenue distribution increases xCUP value
- Users can redeem through Zapper for higher value

### Oracle Integration
- Copper prices from Chainlink Oracle
- Real-time price updates for accurate valuations
- Transparent price discovery for all operations

## Example Usage

```solidity
// 1. Record epoch revenue
settlementEngine.recordEpochRevenue(
    1,           // epochId
    100000e6,    // totalRevenue (100,000 CUP)
    15000e6,     // processingCosts
    5000e6,      // logisticsCosts
    3000e6,      // tradingCosts
    20000e6,     // cupPurchased
    25000e6,     // cupSold
    5000,        // averagePurchasePrice
    6000         // averageSalePrice
);

// 2. Settle the epoch
settlementEngine.settleEpochRevenue(1);

// 3. Distribute revenue to vault
settlementEngine.distributeRevenueToVault(1);

// 4. Users claim their revenue
uint256 userRevenue = xcup.claimRevenue(1);
```

## Benefits

1. **Transparency**: All revenue and cost data is publicly viewable
2. **Fair Distribution**: Revenue distributed proportionally to share ownership
3. **Automated**: System handles complex calculations automatically
4. **Auditable**: All operations are recorded on-chain
5. **Scalable**: Supports multiple epochs and growing user base

This system ensures that xCUP holders benefit directly from the success of Alcum Copper Bank's trading operations, creating a transparent and profitable investment vehicle backed by physical copper assets. 