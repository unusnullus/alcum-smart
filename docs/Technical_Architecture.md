# Alcum Protocol - Technical Architecture

## System Overview

The Alcum Protocol is a comprehensive DeFi (Decentralized Finance) platform that enables users to invest in copper-backed assets through a sophisticated ecosystem of smart contracts. The protocol combines real-world copper trading operations with blockchain technology, providing users with exposure to copper markets through tokenized assets and vault-based investment strategies.

The system manages the complete lifecycle from user deposits through various tokens, curator-approved investments, copper trading operations, revenue settlement, and profit distribution back to investors.

## Architecture Diagram

```
                    ALCUM PROTOCOL ARCHITECTURE

┌─────────────────────────────────────────────────────────────────────────────┐
│                              USER LAYER                                    │
├─────────────────┬─────────────────┬─────────────────┬─────────────────────┤
│   Direct Users  │  Host Systems   │   Curators      │   Protocol Admin    │
│   (Web3 Wallet) │  (HostAdapter)  │  (Approval)     │   (Management)      │
└─────────────────┴─────────────────┴─────────────────┴─────────────────────┘
         │                 │                 │                 │
         ▼                 ▼                 ▼                 ▼
┌─────────────────────────────────────────────────────────────────────────────┐
│                           PROTOCOL LAYER                                   │
├─────────────────┬─────────────────┬─────────────────┬─────────────────────┤
│     Zapper      │   xCUP Vault    │  EpochManager   │  SettlementEngine   │
│   (Entry Point) │  (ERC4626)      │  (Time Cycles)  │  (Revenue Mgmt)     │
│                 │                 │                 │                     │
│ • Token Swaps   │ • Share Mgmt    │ • Epoch Control │ • Revenue Recording │
│ • Deposit Mgmt  │ • Controlled    │ • Time Windows  │ • NAV Calculation   │
│ • Approval Flow │   Redemption    │ • Cycle Advance │ • Profit Distrib.   │
└─────────────────┴─────────────────┴─────────────────┴─────────────────────┘
         │                 │                 │                 │
         ▼                 ▼                 ▼                 ▼
┌─────────────────────────────────────────────────────────────────────────────┐
│                          ASSET LAYER                                       │
├─────────────────┬─────────────────┬─────────────────┬─────────────────────┤
│   CUP Token     │   USDC/Stables  │  External Tokens│   Copper Inventory  │
│  (Copper Rep.)  │   (Base Currency)│  (ETH, BTC, etc)│   (Physical Assets) │
└─────────────────┴─────────────────┴─────────────────┴─────────────────────┘
         │                 │                 │                 │
         ▼                 ▼                 ▼                 ▼
┌─────────────────────────────────────────────────────────────────────────────┐
│                        INFRASTRUCTURE LAYER                                │
├─────────────────┬─────────────────┬─────────────────┬─────────────────────┤
│  Chainlink      │   Uniswap V2    │   OpenZeppelin  │   Real World        │
│  (Price Oracle) │  (DEX/Swaps)    │  (Security)     │  (Copper Trading)   │
└─────────────────┴─────────────────┴─────────────────┴─────────────────────┘
```

## Core Components

### 1. Zapper Contract (`Zapper.sol`)

**Purpose**: Main entry point for user interactions and investment processing with curator approval system.

**Key Functions**:

-   `zapAndDeposit()`: Converts various tokens to USDC and creates deposit requests
-   `zapAndDepositWithPermit()`: Same as above but with ERC20 permit for gasless approvals
-   `approveDeposit()`: Curator function to approve individual deposits
-   `approveDepositsProportionally()`: Curator function for batch proportional approvals
-   `approveAllDeposits()`: Curator function to approve all pending deposits
-   `claimDeposit()`: User function to claim approved deposits and receive xCUP shares
-   `claimAllDeposits()`: User function to claim all their approved deposits
-   `registerExternalDepositFor()`: Host integration function for external deposits
-   `withdrawDeposit()`: User function to withdraw pending deposits before approval
-   `withdrawAllDeposits()`: User function to withdraw all pending deposits
-   `getCopperPrice()`: Retrieves current copper price from oracle

**Security Features**:

-   Role-based access control with VAULT_CURATOR_ROLE and HOST_INTEGRATION_ROLE
-   Pausable functionality for emergencies
-   ReentrancyGuard protection on all external calls
-   Epoch-based time windows for deposits
-   Input validation and balance checks
-   Slippage protection (configurable, default 1%)
-   Nonce-based deposit ID generation (prevents front-running)

**State Management**:

```solidity
struct Deposit {
    address user;              // originator (payer) for on-chain deposits
    bytes32 depositId;         // unique identifier
    uint256 amount;            // pending USDC value
    uint256 approvedAmount;    // approved USDC value
    bool approved;             // approved flag
    address beneficiary;       // who will receive xCUP on claim
    address createdBy;         // who initiated the deposit
    address claimedBy;         // who executed the claim
    bool isExternal;           // true if created via external adapter flow
    bytes32 tag;               // integration tag/ID for marking
    uint256 approvedCupAmount; // fixed CUP amount approved (for external)
    uint256 priceSnapshot;     // price used for approval (for external)
}
```

### 2. CUP Token (`CUPToken.sol`)

**Purpose**: ERC-20 token representing refined copper assets in the Alcum ecosystem.

**Characteristics**:

-   6 decimal places (aligned with USDC precision)
-   Mintable and burnable by authorized roles
-   Upgradeable contract pattern
-   Access control for minting/burning operations

**Roles**:

-   `MINTER_ROLE`: Can create new tokens (typically SettlementEngine)
-   `BURNER_ROLE`: Can destroy tokens (for redemption processes)
-   `DEFAULT_ADMIN_ROLE`: Can manage roles and contract administration

**Key Functions**:

-   `mint()`: Creates new tokens for revenue distribution
-   `burn()`: Destroys tokens during redemption
-   `decimals()`: Returns 6 (matching USDC precision)

### 3. xCUP Vault (`xCUP.sol`)

**Purpose**: ERC-4626 compliant vault for managing copper investments with controlled redemption access.

**Features**:

-   Standard ERC4626 vault interface for deposits/withdrawals
-   Share-based ownership model with automatic calculation
-   Controlled redemption (only REDEEMER_ROLE can withdraw/redeem)
-   Integration with copper price oracles and Uniswap for price calculations
-   Pausable functionality for emergency situations

**Key Functions**:

-   `withdraw()`: Withdraws assets by burning shares (restricted to REDEEMER_ROLE)
-   `redeem()`: Redeems shares for underlying assets (restricted to REDEEMER_ROLE)
-   `getXcupPriceInToken()`: Calculates xCUP price in various tokens
-   `getTokenToXcupExchangeRate()`: Calculates exchange rates for deposits
-   `getCopperPrice()`: Retrieves current copper price
-   `setCopperPriceConsumer()`: Updates price consumer address (owner only)
-   `setUniswapRouter()`: Updates Uniswap router address (owner only)
-   `setUsdcToken()`: Updates USDC token address (owner only)
-   `setWethToken()`: Updates WETH token address (owner only)

**Price Integration**:

-   Copper price consumer for real-time pricing
-   Uniswap V2 router for token exchange rates
-   USDC as base currency for calculations
-   WETH integration for ETH price calculations

### 4. Copper Price Consumer (`CopperPriceConsumer.sol`)

**Purpose**: Chainlink oracle consumer for fetching copper spot prices.

**Features**:

-   Chainlink oracle integration for reliable price data
-   Manual price updates for emergency situations or testing
-   Price freshness validation (configurable max age)
-   Role-based access control for price updates

**Key Functions**:

-   `requestCopperPrice()`: Requests latest price from Chainlink oracle
-   `fulfill()`: Oracle callback to receive price data
-   `updatePrice()`: Manual price update (PRICE_UPDATER_ROLE)
-   `getPriceAsDecimal()`: Returns human-readable price
-   `setOracle()`: Updates oracle address (DEFAULT_ADMIN_ROLE)
-   `setJobId()`: Updates job ID (DEFAULT_ADMIN_ROLE)
-   `setFee()`: Updates oracle fee (DEFAULT_ADMIN_ROLE)

**Configuration**:

-   Oracle address, job ID, and fee management
-   Price precision: 8 decimals
-   Role-based access control for configuration updates

### 5. Settlement Engine (`SettlementEngine.sol`)

**Purpose**: Manages epoch-based copper trading revenue settlement and NAV calculations.

**Core Responsibilities**:

-   Records epoch revenue data from copper trading operations
-   Calculates and maintains Net Asset Value (NAV) components
-   Settles epoch revenues and updates retained earnings
-   Distributes net revenues by minting CUP tokens to the vault
-   Tracks copper inventory, cash reserves, and liabilities

**Key Functions**:

-   `recordEpochRevenue()`: Records trading results for an epoch
-   `settleEpochRevenue()`: Marks epoch as settled and updates retained earnings
-   `distributeRevenueToVault()`: Mints CUP tokens to vault based on net revenue
-   `updateNAV()`: Updates Net Asset Value components
-   `calculateEpochROI()`: Calculates return on investment for epochs
-   `getNAVSummary()`: Provides comprehensive NAV analysis

**NAV Components**:

```solidity
struct NAVComponents {
    uint256 cupInWarehouse;     // Refined copper inventory (CUP tokens)
    uint256 copperSpotPrice;    // Current copper spot price (8 decimals)
    uint256 cupInTransit;       // Copper being processed (CUP tokens)
    uint256 retainedEarnings;   // Accumulated profits (USDC, 6 decimals)
    uint256 stablecoinBalance;  // Cash reserves (USDC, 6 decimals)
    uint256 liabilities;        // Outstanding obligations (USDC, 6 decimals)
}
```

**Revenue Tracking**:

```solidity
struct EpochRevenue {
    uint256 epochId;
    uint256 netRevenue;         // Final revenue after costs
    uint256 originalNetRevenue; // Original revenue for analytics
    uint256 cupPurchased;       // Raw copper purchased
    uint256 cupSold;            // Refined copper sold
    uint256 averagePurchasePrice;
    uint256 averageSalePrice;
    bool isSettled;
}
```

### 6. Epoch Manager (`EpochManager.sol`)

**Purpose**: Manages time-based epochs for organizing trading activities and revenue settlement cycles.

**Features**:

-   Fixed-duration epochs (typically 7 days)
-   Epoch progression control
-   Time-based operation windows
-   Integration with other protocol contracts

**Key Functions**:

-   `nextEpoch()`: Advances to the next epoch (EPOCH_MANAGER_ROLE)
-   `currentEpochId()`: Returns current epoch identifier
-   `timeLeftInEpoch()`: Calculates remaining time in current epoch
-   `epochStart()`: Returns timestamp when current epoch started
-   `epochDuration()`: Returns duration of epochs in seconds
-   `setEpochDuration()`: Updates duration for future epochs (EPOCH_MANAGER_ROLE)

### 7. Redeem Engine (`RedeemEngine.sol`)

**Purpose**: Separate contract for handling all redemption operations with dedicated Silo management.

**Features**:

-   Request-based redemption flow (request → approve → claim) without commission
-   Direct redemption with configurable commission
-   Dedicated Silo contract for USDC management during redemptions
-   Isolated from main Zapper operations for better security and fund separation
-   Full access control and reentrancy protection

**Key Functions**:

-   `requestRedeem()`: Creates a new redeem request (user)
-   `approveRedeem()`: Approves a pending redeem request (VAULT_CURATOR_ROLE)
-   `claimRedeem()`: Claims an approved redeem request (user)
-   `redeem()`: Direct redemption with commission (user)
-   `setRedeemCommission()`: Sets commission rate for direct redemptions (DEFAULT_ADMIN_ROLE)
-   `withdrawFromRedeemSilo()`: Withdraws USDC from redeem silo (VAULT_CURATOR_ROLE)
-   `getRedeem()`: Returns redeem request information
-   `getRedeemCommission()`: Returns current commission rate
-   `redeemSilo()`: Returns address of dedicated redeem Silo

**Redemption Flows**:

1. **Request-Based Flow** (No Commission):

    - User approves `redeemEngine` to spend xCUP shares
    - User calls `requestRedeem(shares)` - **shares are immediately transferred to contract**
    - Curator calls `approveRedeem(redeemId, usdcAmount)`
    - User calls `claimRedeem(redeemId)` - uses shares already in contract to receive USDC

2. **Direct Flow** (With Commission):
    - User calls `redeem(sharesToRedeem)`
    - Commission is deducted and stays in redeem silo
    - User receives USDC minus commission immediately

**State Management**:

```solidity
struct RedeemRequest {
    address user;           // requester
    uint256 shares;         // xCUP shares to redeem
    uint256 usdcAmount;     // approved payout
    bool approved;          // approved by admin
    bool claimed;           // claimed by user
}
```

**Security Features**:

-   Role-based access control (VAULT_CURATOR_ROLE for approvals)
-   ReentrancyGuard on all state-changing functions
-   Pausable functionality for emergency stops
-   Dedicated Silo for fund isolation
-   Commission validation (max 100%)
-   Input validation and balance checks

### 8. Host Adapter (`HostAdapter.sol`)

**Purpose**: Isolated adapter for host-to-host integrations with role separation.

**Features**:

-   Middleware layer between external systems and Zapper
-   Role-based access control for different operations
-   External deposit registration and management
-   Beneficiary management for deposits

**Key Functions**:

-   `registerExternalDepositFor()`: Registers external deposits (HOST_OPERATOR_ROLE)
-   `setDepositBeneficiary()`: Updates beneficiary before approval (HOST_OPERATOR_ROLE)
-   `approveExternalDepositWithPrice()`: Approves with price snapshot (CURATOR_OPERATOR_ROLE)

**Roles**:

-   `HOST_OPERATOR_ROLE`: Backend operators for deposit registration
-   `CURATOR_OPERATOR_ROLE`: Curators for deposit approval with pricing

## Data Flow

### Investment Process Flow

1. **User Initiation**

    ```
    User calls zapAndDeposit(tokenIn, amount)
    ```

2. **Input Validation**

    ```solidity
    require(address(tokenIn) != address(0), "Invalid input token address");
    require(amount != 0, "Invalid amount");
    ```

3. **Currency Conversion**

    - If input is USDC: Direct processing
    - If other token: Convert via Uniswap router
    - Apply 1% slippage protection

4. **Price Calculation**

    ```solidity
    uint256 currentCopperPrice = getCopperPrice();
    uint256 depositValue = amount * currentCopperPrice;
    ```

5. **Vault Deposit**
    ```solidity
    _cup.approve(address(_vault), depositValue);
    shares = _vault.deposit(depositValue, _msgSender());
    ```

### Approval Process Flow

1. **Deposit Request**

    - Generate unique deposit ID
    - Store deposit information
    - Emit events for tracking

2. **Curator Review**

    - Curator reviews deposit request
    - Approves or declines based on criteria
    - Updates deposit status

3. **User Claim**
    - User claims approved deposits
    - Tokens are transferred to vault
    - User receives xCUP shares

## Security Architecture

### Access Control

**Role-Based Permissions**:

```solidity
bytes32 public constant VAULT_CURATOR_ROLE = keccak256("VAULT_CURATOR_ROLE");
bytes32 public constant MINTER_ROLE = keccak256("MINTER_ROLE");
bytes32 public constant BURNER_ROLE = keccak256("BURNER_ROLE");
```

**Permission Matrix**:
| Function | Owner | Curator | User |
|----------|-------|---------|------|
| **Zapper Functions** |
| pause/unpause | ✅ | ❌ | ❌ |
| approveDeposit | ❌ | ✅ | ❌ |
| zapAndDeposit | ❌ | ❌ | ✅ |
| claimDeposit | ❌ | ❌ | ✅ |
| withdrawDeposit | ❌ | ❌ | ✅ |
| **RedeemEngine Functions** |
| pause/unpause (RedeemEngine) | ✅ | ❌ | ❌ |
| approveRedeem | ❌ | ✅ | ❌ |
| requestRedeem | ❌ | ❌ | ✅ |
| claimRedeem | ❌ | ❌ | ✅ |
| redeem (direct) | ❌ | ❌ | ✅ |
| setRedeemCommission | ✅ | ❌ | ❌ |
| withdrawFromRedeemSilo | ❌ | ✅ | ❌ |

### Input Validation

**Address Validation**:

```solidity
require(cup != address(0), "Invalid CUP address");
require(vault != address(0), "Invalid Vault address");
```

**Amount Validation**:

```solidity
require(amount != 0, "Invalid amount");
require(depositValue > 0, "Deposit value is too low");
```

### Slippage Protection

**Implementation**:

```solidity
uint256 minOutput = amounts[1] * 99 / 100; // 1% slippage tolerance
```

**Purpose**: Protects users from excessive price movements during conversion.

### Emergency Controls

**Pausable Functionality**:

```solidity
function pause() external onlyOwner {
    _pause();
}

function unpause() external onlyOwner {
    _unpause();
}
```

## Integration Points

### External Dependencies

1. **Uniswap V2 Router**

    - Token swapping functionality
    - Price calculation
    - Liquidity provision

2. **Chainlink Oracle** (Future)

    - Real-time copper price feeds
    - Decentralized price data
    - Multiple source aggregation

3. **ERC-4626 Vault Standard**
    - Standardized vault interface
    - Interoperability with other DeFi protocols
    - Consistent user experience

### Internal Dependencies

1. **OpenZeppelin Contracts**

    - AccessControl for role management
    - Pausable for emergency controls
    - SafeERC20 for secure token transfers
    - Ownable for ownership management

2. **ERC-20 Standard**
    - Token compatibility
    - Standard transfer functions
    - Approval mechanisms

## Gas Optimization

### Efficient Patterns

1. **Batch Operations**: Group multiple operations to reduce gas costs
2. **Storage Optimization**: Use packed structs where possible
3. **Event Optimization**: Minimize event data for cost reduction
4. **Function Visibility**: Use appropriate visibility modifiers

### Gas-Efficient Functions

```solidity
// Optimized transfer function
function _transferTokenInAndApprove(IERC20 tokenIn, uint256 amount) internal {
    tokenIn.safeTransferFrom(_msgSender(), address(this), amount);

    if (tokenIn.allowance(address(this), router()) < amount) {
        tokenIn.forceApprove(router(), amount);
    }
}
```

## Testing Strategy

### Unit Tests

-   Individual contract function testing
-   Edge case validation
-   Gas consumption analysis

### Integration Tests

-   End-to-end workflow testing
-   Cross-contract interaction validation
-   Real-world scenario simulation

### Security Tests

-   Access control validation
-   Reentrancy attack prevention
-   Overflow/underflow protection

## Deployment Strategy

### Contract Deployment Order

1. **CUP Token**: Deploy base token contract
2. **Copper Price Consumer**: Deploy price feed contract
3. **xCUP Vault**: Deploy vault contract
4. **Zapper**: Deploy main contract with all dependencies
5. **Settlement Engine**: Deploy settlement contract

### Configuration Parameters

```solidity
constructor(
    address cup,           // CUP token address
    address usdc,          // USDC token address
    address vault,         // xCUP vault address
    address router,        // Uniswap router address
    address copperPriceConsumer // Price feed address
)
```

## Monitoring and Analytics

### Key Metrics

1. **Transaction Volume**: Total value processed through zapper
2. **User Activity**: Number of unique users and transactions
3. **Conversion Rates**: Success rate of token conversions
4. **Gas Usage**: Average gas consumption per operation
5. **Error Rates**: Failed transaction analysis

### Event Tracking

```solidity
event ZapIn(address indexed router, address indexed tokenIn, uint256 amount);
event ZapInAndDeposit(address indexed router, address indexed tokenIn, uint256 amount, uint256 shares);
event DepositClaimed(bytes32 depositId, address user, uint256 shares);
event DepositApproved(bytes32 depositId);
```

## Upgrade Strategy

### Proxy Pattern Considerations

-   Use upgradeable proxy pattern for main contracts
-   Maintain state compatibility across upgrades
-   Implement proper upgrade validation

### Backward Compatibility

-   Maintain existing function signatures
-   Preserve state variable layout
-   Ensure event compatibility

## Risk Management

### Technical Risks

1. **Smart Contract Vulnerabilities**

    - Regular security audits
    - Bug bounty programs
    - Formal verification

2. **Oracle Failures**

    - Multiple price feed sources
    - Fallback mechanisms
    - Emergency pause functionality

3. **Network Congestion**
    - Gas optimization
    - Batch processing
    - Priority fee management

### Economic Risks

1. **Price Manipulation**

    - Slippage protection
    - Minimum transaction sizes
    - Curator oversight

2. **Liquidity Issues**
    - Sufficient liquidity pools
    - Emergency withdrawal mechanisms
    - Diversified asset backing

## Future Enhancements

### Planned Features

1. **Multi-Asset Support**: Support for additional commodities
2. **Advanced Analytics**: Enhanced reporting and analytics
3. **Mobile Integration**: Mobile app development
4. **Cross-Chain Support**: Multi-chain deployment

### Technical Improvements

1. **Gas Optimization**: Further gas cost reduction
2. **Scalability**: Layer 2 integration
3. **Interoperability**: Cross-protocol integration
4. **Automation**: Advanced automation features

## Conclusion

The Zapper system provides a robust, secure, and user-friendly platform for copper-backed investments. The modular architecture ensures maintainability and extensibility while the comprehensive security measures protect user funds and system integrity.

The system is designed to scale with user growth while maintaining performance and security standards. Regular audits, monitoring, and community feedback will ensure continuous improvement and reliability.
