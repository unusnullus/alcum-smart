# Zapper System - Technical Architecture

## System Overview

The Zapper system is a DeFi (Decentralized Finance) application that enables users to invest in copper-backed assets through a streamlined token conversion and vault deposit process. The system consists of multiple smart contracts working together to provide a seamless investment experience.

## Architecture Diagram

```
┌─────────────────┐    ┌─────────────────┐    ┌─────────────────┐
│   User Wallet   │    │   Zapper        │    │   xCUP Vault    │
│                 │    │   Contract      │    │                 │
│ ┌─────────────┐ │    │ ┌─────────────┐ │    │ ┌─────────────┐ │
│ │ Various     │ │    │ │ Currency    │ │    │ │ Investment  │ │
│ │ Tokens      │ │    │ │ Conversion  │ │    │ │ Shares      │ │
│ │ (BTC, ETH,  │ │    │ │ Logic       │ │    │ │ (xCUP)      │ │
│ │  USDC, etc) │ │    │ │             │ │    │ │             │ │
│ └─────────────┘ │    │ └─────────────┘ │    │ └─────────────┘ │
└─────────────────┘    └─────────────────┘    └─────────────────┘
         │                       │                       │
         │                       │                       │
         ▼                       ▼                       ▼
┌─────────────────┐    ┌─────────────────┐    ┌─────────────────┐
│   Uniswap       │    │   Copper Price  │    │   CUP Token     │
│   Router        │    │   Consumer      │    │                 │
│                 │    │                 │    │                 │
│ ┌─────────────┐ │    │ ┌─────────────┐ │    │ ┌─────────────┐ │
│ │ Token Swap  │ │    │ │ Price Feed  │ │    │ │ Copper-     │ │
│ │ Engine       │ │    │ │ Integration │ │    │ │ Backed      │ │
│ │             │ │    │ │             │ │    │ │ Currency    │ │
│ └─────────────┘ │    │ └─────────────┘ │    │ └─────────────┘ │
└─────────────────┘    └─────────────────┘    └─────────────────┘
```

## Core Components

### 1. Zapper Contract (`Zapper.sol`)

**Purpose**: Main entry point for user interactions and investment processing.

**Key Functions**:
- `zapAndDeposit()`: Primary function for converting tokens and depositing to vault
- `approveDeposit()`: Curator function to approve large deposits
- `claimDeposit()`: User function to claim approved deposits
- `getCopperPrice()`: Retrieves current copper price from oracle

**Security Features**:
- Role-based access control (RBAC)
- Pausable functionality for emergencies
- Input validation and balance checks
- Slippage protection (1% tolerance)

**State Management**:
```solidity
mapping(bytes32 depositId => Deposit) private _approvedDeposits;
struct Deposit {
    address user;
    bytes32 depositId;
    uint256 amount;
    bool approved;
}
```

### 2. CUP Token (`CUPToken.sol`)

**Purpose**: ERC-20 token representing copper-backed value.

**Characteristics**:
- 6 decimal places (like USDC)
- Mintable and burnable by authorized roles
- Access control for minting/burning operations
- Initial supply: 1000e6 tokens

**Roles**:
- `MINTER_ROLE`: Can create new tokens
- `BURNER_ROLE`: Can destroy tokens
- `DEFAULT_ADMIN_ROLE`: Can manage roles

### 3. xCUP Vault (`xCUP.sol`)

**Purpose**: ERC-4626 compliant vault for managing copper investments.

**Features**:
- Standard vault interface for deposits/withdrawals
- Share-based ownership model
- Automatic share calculation
- Integration with CUP token

### 4. Copper Price Consumer (`CopperPriceConsumerMock.sol`)

**Purpose**: Provides real-time copper price data to the system.

**Current Implementation**:
- Mock price feed returning $5 per unit
- Chainlink-compatible interface
- Extensible for real price feeds

**Future Integration**:
- Chainlink oracle integration
- Multiple price source support
- Fallback mechanisms

### 5. Settlement Engine (`SettlementEngine.sol`)

**Purpose**: Manages final settlement and asset conversion processes.

**Responsibilities**:
- Asset conversion coordination
- Settlement verification
- Accounting and record keeping

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
| pause/unpause | ✅ | ❌ | ❌ |
| approveDeposit | ❌ | ✅ | ❌ |
| zapAndDeposit | ❌ | ❌ | ✅ |
| claimDeposit | ❌ | ❌ | ✅ |

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
- Individual contract function testing
- Edge case validation
- Gas consumption analysis

### Integration Tests
- End-to-end workflow testing
- Cross-contract interaction validation
- Real-world scenario simulation

### Security Tests
- Access control validation
- Reentrancy attack prevention
- Overflow/underflow protection

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

- Use upgradeable proxy pattern for main contracts
- Maintain state compatibility across upgrades
- Implement proper upgrade validation

### Backward Compatibility

- Maintain existing function signatures
- Preserve state variable layout
- Ensure event compatibility

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