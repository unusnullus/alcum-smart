# SettlementEngine Contract Documentation

## Overview

The SettlementEngine is the core contract responsible for managing copper trading operations, calculating Net Asset Value (NAV), and distributing profits to xCUP token holders. It tracks the complete lifecycle of copper business operations from raw material purchase to refined copper sales.

## Table of Contents

1. [Contract Architecture](#contract-architecture)
2. [Core Data Structures](#core-data-structures)
3. [Function Reference](#function-reference)
4. [Complete Workflow Examples](#complete-workflow-examples)
5. [Business Model Integration](#business-model-integration)
6. [Security Features](#security-features)

## Contract Architecture

```
SettlementEngine
├── NAV Management (Asset valuation)
├── Epoch Revenue Tracking (Business operations)
├── Revenue Distribution (Profit sharing)
└── Analytics (Performance metrics)
```

### Dependencies
- **xCUP Vault**: ERC4626 vault for managing user investments
- **CUP Token**: Mintable ERC20 token representing copper value
- **EpochManager**: Manages 30-day investment cycles
- **Treasury**: Handles financial operations

## Core Data Structures

### NAVComponents
Represents the current state of all assets and liabilities:

```solidity
struct NAVComponents {
    uint256 cupInWarehouse;      // Refined copper inventory (in warehouse)
    uint256 copperSpotPrice;     // Current copper spot price per unit
    uint256 cupInTransit;        // Copper being processed/transported
    uint256 retainedEarnings;    // Accumulated profits from all epochs
    uint256 stablecoinBalance;   // Cash/stablecoin reserves
    uint256 liabilities;         // Outstanding debts and obligations
}
```

**Business Context**: This reflects the real-world copper business state:
- Physical copper inventory valued at current market prices
- Working capital and cash reserves
- Outstanding obligations and debt

### EpochRevenue
Tracks the results of each 30-day copper trading cycle:

```solidity
struct EpochRevenue {
    uint256 epochId;             // Unique identifier for the epoch
    uint256 netRevenue;          // Final profit after all costs
    uint256 cupPurchased;        // Raw copper/scrap purchased (tons)
    uint256 cupSold;             // Refined copper sold (tons)
    uint256 averagePurchasePrice; // Average price paid per unit
    uint256 averageSalePrice;    // Average price received per unit
    bool isSettled;              // Whether epoch calculations are finalized
}
```

**Business Context**: Captures one complete copper trading cycle:
- Raw material acquisition → Processing → Sales → Net profit calculation

## Function Reference

### 1. NAV Management Functions

#### `updateNAV(NAVComponents calldata newNav)`
**Purpose**: Updates the Net Asset Value with current asset valuations.

**Access**: Owner only

**Parameters**:
- `newNav`: Current asset and liability values

**Calculation Logic**:
```solidity
// Total physical and financial assets
copperAssetValue = (cupInWarehouse + cupInTransit) × copperSpotPrice
totalAssets = copperAssetValue + retainedEarnings + stablecoinBalance

// Net assets after obligations
netAssets = totalAssets - liabilities

// Price per xCUP share (18 decimal precision)
pricePerShare = netAssets × 1e18 ÷ totalSupply
```

**Events Emitted**: `NAVUpdated(uint256 totalNAV, uint256 pricePerShare)`

#### `getNAVSummary()`
**Purpose**: View function to get current NAV calculations.

**Returns**:
- `totalAssets`: Total value of all assets
- `netAssets`: Assets minus liabilities
- `pricePerShare`: Current value of each xCUP share

### 2. Revenue Recording Functions

#### `recordEpochRevenue(...)`
**Purpose**: Records the results of completed copper trading operations.

**Access**: Owner only

**Parameters**:
```solidity
uint256 epochId,              // Epoch identifier
uint256 netRevenue,           // Final profit amount
uint256 cupPurchased,         // Raw copper bought
uint256 cupSold,              // Refined copper sold
uint256 averagePurchasePrice, // Average cost per unit
uint256 averageSalePrice      // Average sale price per unit
```

**Validation**:
- Epoch ID must be valid
- Net revenue must be positive
- Epoch cannot already be settled

**Events Emitted**: 
- `EpochRevenueRecorded(epochId, netRevenue, cupProcessed)`
- `CopperOperationCompleted(epochId, cupPurchased, cupSold, netRevenue)`

#### `settleEpochRevenue(uint256 epochId)`
**Purpose**: Finalizes epoch calculations and prepares for revenue distribution.

**Access**: Owner only

**Process**:
1. Validates epoch exists and isn't already settled
2. Marks epoch as settled
3. Adds net revenue to retained earnings
4. Makes epoch ready for distribution

### 3. Revenue Distribution Functions

#### `distributeRevenueToVault(uint256 epochId)`
**Purpose**: Distributes epoch profits by increasing xCUP share value.

**Access**: Owner only

**Mechanism**:
1. Validates epoch is settled with positive revenue
2. Mints new CUP tokens equal to net revenue
3. Sends minted tokens to xCUP vault
4. This increases `totalAssets()` in vault → Higher share value

**Key Insight**: This is how xCUP holders benefit - their shares become more valuable!

### 4. Analytics Functions

#### `calculateEpochROI(uint256 epochId)`
**Purpose**: Calculates Return on Investment for a specific epoch.

**Formula**: `ROI = (netRevenue ÷ totalInvestment) × 10000` (basis points)

**Example**: 
- Investment: 100 units × $5 = $500
- Net Revenue: $150
- ROI = (150 ÷ 500) × 10000 = 3000 basis points = 30%

#### `getCopperProcessingEfficiency(uint256 epochId)`
**Purpose**: Measures processing efficiency of copper operations.

**Formula**: `Efficiency = (cupSold ÷ cupPurchased) × 10000`

**Example**:
- Purchased: 1.2 tons raw copper
- Sold: 1.2 tons refined copper
- Efficiency = (1.2 ÷ 1.2) × 10000 = 10000 = 100%

#### `getProfitMargin(uint256 epochId)`
**Purpose**: Calculates profit margin from sales operations.

**Formula**: `Margin = (netRevenue ÷ totalSalesValue) × 10000`

**Example**:
- Sales Value: $1000
- Net Revenue: $300
- Margin = (300 ÷ 1000) × 10000 = 3000 = 30%

### 5. Utility Functions

#### `getCurrentEpochRevenue()`
**Purpose**: Returns revenue data for the current epoch.

#### `getEpochRevenue(uint256 epochId)`
**Purpose**: Returns complete revenue data for any epoch.

#### `advanceEpoch()`
**Purpose**: Moves to the next epoch and syncs with EpochManager.

## Complete Workflow Examples

### Example 1: Basic Copper Trading Cycle

**Scenario**: Alcum processes 1 ton of copper scrap into refined copper

#### Step 1: Record Business Operation
```solidity
// Owner records completed copper trading operation
settlementEngine.recordEpochRevenue(
    1,           // epochId
    300000,      // netRevenue: $300 profit (in CUP tokens with 6 decimals)
    1200000,     // cupPurchased: 1.2 tons of scrap
    1200000,     // cupSold: 1.2 tons refined
    250,         // averagePurchasePrice: $0.25 per unit
    500          // averageSalePrice: $0.50 per unit
);
```

#### Step 2: Settle the Epoch
```solidity
// Owner finalizes the calculations
settlementEngine.settleEpochRevenue(1);
```

#### Step 3: Distribute Profits
```solidity
// Owner distributes profits to xCUP holders
settlementEngine.distributeRevenueToVault(1);
```

**Result**: All xCUP holders now have shares worth more due to the $300 profit!

### Example 2: Large-Scale Operation with Analytics

**Scenario**: Multi-ton copper processing with performance analysis

#### Step 1: Record Large Operation
```solidity
settlementEngine.recordEpochRevenue(
    2,           // epochId
    1500000,     // netRevenue: $1500 profit
    5000000,     // cupPurchased: 5 tons scrap
    4800000,     // cupSold: 4.8 tons refined (96% efficiency)
    300,         // averagePurchasePrice: $0.30 per unit
    625          // averageSalePrice: $0.625 per unit
);
```

#### Step 2: Analyze Performance
```solidity
// Check processing efficiency
uint256 efficiency = settlementEngine.getCopperProcessingEfficiency(2);
// Returns: 9600 (96% efficiency)

// Check profit margin
uint256 margin = settlementEngine.getProfitMargin(2);
// Returns: 5000 (50% profit margin)

// Check ROI
uint256 roi = settlementEngine.calculateEpochROI(2);
// Returns: 10000 (100% ROI)
```

#### Step 3: Settle and Distribute
```solidity
settlementEngine.settleEpochRevenue(2);
settlementEngine.distributeRevenueToVault(2);
```

### Example 3: NAV Management Update

**Scenario**: Monthly NAV update with current market conditions

```solidity
// Owner updates NAV with current asset valuations
settlementEngine.updateNAV(NAVComponents({
    cupInWarehouse: 10000000,    // 10 tons refined copper in storage
    copperSpotPrice: 8000,       // $8 per unit spot price
    cupInTransit: 2000000,       // 2 tons being processed
    retainedEarnings: 5000000,   // $5000 accumulated profits
    stablecoinBalance: 15000000, // $15000 cash reserves
    liabilities: 3000000         // $3000 in obligations
}));

// Check the results
(uint256 totalAssets, uint256 netAssets, uint256 pricePerShare) = 
    settlementEngine.getNAVSummary();

// totalAssets = (10M + 2M) × 8000 + 5M + 15M = 116M
// netAssets = 116M - 3M = 113M
// pricePerShare = 113M × 1e18 ÷ totalSupply
```

## Business Model Integration

### How Users Benefit

1. **Investment**: User deposits $1000 → Gets 1000 xCUP shares
2. **Copper Operations**: Alcum uses funds to buy/process/sell copper
3. **Profit Generation**: Operations generate $300 profit
4. **Value Increase**: SettlementEngine mints $300 worth of CUP to vault
5. **Withdrawal**: User's 1000 shares now worth $1300 when redeemed

### Revenue Flow

```
Copper Sales Revenue ($1000)
    ↓
Minus All Costs (processing, logistics, etc.)
    ↓
Net Revenue ($300) → Record in SettlementEngine
    ↓
Mint CUP Tokens ($300) → Send to xCUP Vault
    ↓
Increase Share Value → All xCUP holders benefit
```

## Security Features

### Access Control
- **Owner Only**: All financial operations require owner permission
- **Validation**: Comprehensive input validation on all functions
- **Single Settlement**: Each epoch can only be settled once

### Reentrancy Protection
- State changes before external calls
- Revenue marked as distributed to prevent double-spending

### Data Integrity
- Immutable epoch records once settled
- Comprehensive event logging for auditability
- Mathematical overflow protection

## Events and Monitoring

### Key Events for Integration

```solidity
// NAV updates for price feeds
event NAVUpdated(uint256 totalNAV, uint256 pricePerShare);

// Revenue recording for business tracking
event EpochRevenueRecorded(uint256 indexed epochId, uint256 netRevenue, uint256 cupProcessed);

// Profit distribution for user notifications
event RevenueDistributed(uint256 indexed epochId, uint256 revenueDistributed);

// Complete operation summary
event CopperOperationCompleted(uint256 indexed epochId, uint256 cupPurchased, uint256 cupSold, uint256 netRevenue);
```

## Best Practices

### For Contract Owners

1. **Regular NAV Updates**: Update NAV monthly or when significant market changes occur
2. **Timely Settlement**: Settle epochs promptly after operations complete
3. **Accurate Recording**: Ensure all copper quantities and prices are precisely recorded
4. **Performance Monitoring**: Use analytics functions to track business efficiency

### For Integration

1. **Event Monitoring**: Subscribe to events for real-time updates
2. **Error Handling**: Always check transaction success and handle errors gracefully
3. **Gas Estimation**: Estimate gas for complex operations like revenue distribution
4. **State Verification**: Verify epoch states before attempting operations

## Conclusion

The SettlementEngine contract provides a comprehensive framework for managing copper-backed investments with full transparency and automated profit distribution. By minting new CUP tokens to the vault, it ensures that all xCUP holders benefit proportionally from successful copper trading operations.

The contract's design aligns perfectly with the physical copper business model while providing on-chain transparency and automated profit sharing for decentralized investment management.