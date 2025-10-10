# Zapper Contract - Comprehensive User Guide

## What is the Zapper?

The Zapper is a sophisticated DeFi protocol contract that enables seamless investment in copper-backed assets. It serves as a comprehensive bridge that converts various cryptocurrencies (USDC, ETH, and other ERC20 tokens) into CUP tokens and deposits them into the xCUP vault through a curator-approved process.

### Key Features:
- **Multi-token Support**: Accept USDC, ETH, and various ERC20 tokens
- **Automated Swapping**: Integrate with Uniswap V2 for token conversions
- **Curator Approval System**: Professional oversight for deposit approvals
- **Flexible Claiming**: Support for both individual and batch operations
- **External Integrations**: Host-to-host deposit flows for institutional use
- **Price Protection**: Slippage protection and price snapshot mechanisms

## Core Components

### 1. Zapper Contract (`Zapper.sol`)
- **Main interface** for all user interactions
- **Handles currency conversion** from any token to USDC
- **Manages the investment process** from start to finish
- **Controls the approval system** for large investments

### 2. CUP Token (`CUPToken.sol`)
- **Copper-backed digital currency** (6 decimal places)
- **Represents copper value** in the system
- **Used for vault deposits** and withdrawals
- **Can be minted/burned** by authorized roles

### 3. xCUP Vault (`xCUP.sol`)
- **Investment vault** that holds CUP tokens
- **Issues xCUP shares** to investors
- **Manages the investment fund** for copper exposure
- **ERC-4626 compliant** vault standard

### 4. Copper Price Consumer (`CopperPriceConsumerMock.sol`)
- **Provides copper price data** to the system
- **Currently uses mock price** of $5 per unit
- **Can be upgraded** to real price feeds
- **Critical for calculating** investment values

## Core Functions and How They Work

### 1. `zapAndDeposit(tokenIn, amount, depositId, slippageBps)`
**Purpose**: Primary function to convert tokens and create a deposit for curator approval

**Enhanced Process Flow**:
1. Validates input parameters and applies slippage protection
2. Converts input token to USDC via Uniswap V2 (if not USDC)
3. Transfers USDC to Silo contract for secure storage
4. Creates deposit record with unique ID for curator review
5. Emits events for frontend tracking and integration

**Parameters**:
- `tokenIn`: Token address (ERC20) or address(0) for ETH
- `amount`: Amount in token's native decimals
- `depositId`: Unique identifier for the deposit (must be unique)
- `slippageBps`: Slippage tolerance in basis points (100 = 1%, 0 = use default)

**PRECONDITIONS**:
- amount > 0
- For ETH: msg.value must equal amount
- For ERC20s: sufficient balance and approval required
- depositId must be unique
- Contract must not be paused

**Example**:
```javascript
// Invest 100 USDC with 1% slippage
const depositId = ethers.utils.keccak256(ethers.utils.toUtf8Bytes("my_deposit_1"));
await zapper.zapAndDeposit(usdcAddress, 100000000, depositId, 100);

// Invest ETH with default slippage
const ethDepositId = ethers.utils.keccak256(ethers.utils.toUtf8Bytes("eth_deposit_1"));
await zapper.zapAndDeposit("0x0000000000000000000000000000000000000000", 
  ethers.utils.parseEther("1"), ethDepositId, 0, { value: ethers.utils.parseEther("1") });
```

### 2. `approveDeposit(depositId, approvedAmount)`
**Purpose**: Curator function to approve deposits with flexible amounts

**Enhanced Functionality**:
1. Reviews pending deposit for compliance and legitimacy
2. Can approve full or partial amounts based on vault capacity
3. Enables risk management through controlled approvals
4. Supports both individual and batch approval workflows

**Parameters**:
- `depositId`: Unique identifier for the deposit
- `approvedAmount`: Amount to approve (can be ≤ total deposit amount)

**PRECONDITIONS**:
- Caller must have VAULT_CURATOR_ROLE
- Current epoch must be active
- Deposit must exist and not be already approved
- approvedAmount must be > 0 and ≤ deposit.amount

**Who can call**: Only vault curators

**Example**:
```javascript
// Approve full deposit
await zapper.connect(curator).approveDeposit(depositId, 100000000);

// Approve partial deposit (50% of 100 USDC)
await zapper.connect(curator).approveDeposit(depositId, 50000000);
```

### 3. `claimDeposit(depositId)`
**Purpose**: User function to claim approved deposits and receive xCUP shares

**Enhanced Process**:
1. Validates user authorization (original depositor or beneficiary)
2. Calculates CUP amount using current copper price (or snapshot for external)
3. Handles partial claims (remaining amount stays pending)
4. Deposits CUP tokens to vault and receives xCUP shares
5. Transfers shares to beneficiary and emits comprehensive events

**Parameters**:
- `depositId`: Unique identifier for the approved deposit

**PRECONDITIONS**:
- Current epoch must be active
- Deposit must be approved with amount > 0
- Caller must be authorized (user or beneficiary)
- Contract must have sufficient CUP balance
- For regular deposits: copper price > 0

**Returns**: Number of xCUP vault shares received

**Example**:
```javascript
// Claim approved deposit
const shares = await zapper.connect(user).claimDeposit(depositId);
console.log(`Received ${shares} xCUP shares`);

// For external deposits, beneficiary can claim
const shares = await zapper.connect(beneficiary).claimDeposit(externalDepositId);
```

### 4. `getCopperPrice()`
**Purpose**: Gets current copper price from oracle

**What it does**:
1. Calls the Copper Price Consumer contract
2. Returns current copper price in USD
3. Used for calculating CUP amounts

**Returns**: `uint256` - Current copper price

## Investment Flows

### Flow 1: Standard User Deposit Flow

```
User Action                    Contract Function                    State Changes
     ↓                              ↓                                    ↓
1. Approve Token             token.approve(zapper, amount)         User allowance set
     ↓                              ↓                                    ↓
2. Zap and Deposit           zapper.zapAndDeposit(...)             USDC in Silo, deposit pending
     ↓                              ↓                                    ↓
3. Wait for Approval         [Curator Review Process]              Deposit in pending queue
     ↓                              ↓                                    ↓
4. Curator Approves          zapper.approveDeposit(...)            Deposit marked approved
     ↓                              ↓                                    ↓
5. User Claims               zapper.claimDeposit(...)              CUP → Vault, xCUP to user
     ↓                              ↓                                    ↓
6. Receive Shares            User has xCUP shares                  Investment complete
```

**Step-by-Step Process**:
1. **Approve USDC**: `await usdc.approve(zapperAddress, amount)`
2. **Call zapAndDeposit**: `await zapper.zapAndDeposit(usdcAddress, amount)`
3. **System calculates CUP**: Based on current copper price
4. **Deposit to vault**: CUP tokens go to xCUP vault
5. **Receive shares**: You get xCUP tokens representing your investment

### Flow 2: External/Host Integration Flow

```
Integration Action             Contract Function                    State Changes
     ↓                              ↓                                    ↓
1. Register Deposit          zapper.registerExternalDepositFor()   External deposit created
     ↓                              ↓                                    ↓
2. Update Beneficiary        zapper.setDepositBeneficiary()        Beneficiary set/updated
     ↓                              ↓                                    ↓
3. Curator Review            [Review Process]                      Pending approval
     ↓                              ↓                                    ↓
4. Approve with Price        zapper.approveExternalDepositWith...  Price snapshot locked
     ↓                              ↓                                    ↓
5. Beneficiary Claims        zapper.claimDeposit(...)              Fixed CUP amount used
     ↓                              ↓                                    ↓
6. Receive Shares            Beneficiary has xCUP shares           Integration complete
```

### Flow 3: Batch Operations Flow

```
Curator Action                 Contract Function                    Efficiency Benefits
     ↓                              ↓                                    ↓
1. Review All Pending        zapper.getPendingDeposits()           Comprehensive overview
     ↓                              ↓                                    ↓
2. Proportional Approval     zapper.approveDepositsProportionally() Fair distribution
     ↓                              ↓                                    ↓
3. OR Full Approval          zapper.approveAllDeposits()           Complete batch approval
     ↓                              ↓                                    ↓
4. Users Claim All           zapper.claimAllDeposits()             Batch claiming
     ↓                              ↓                                    ↓
5. Mass Distribution         Multiple xCUP transfers               Efficient processing
```

**Step-by-Step Process**:
1. **Approve token**: `await token.approve(zapperAddress, amount)`
2. **Call zapAndDeposit**: `await zapper.zapAndDeposit(tokenAddress, amount)`
3. **System creates deposit**: Generates unique `depositId` and stores deposit info
4. **Wait for curator**: Curator reviews the deposit request
5. **Curator approves**: `await zapper.approveDeposit(depositId)` (curator only)
6. **User claims**: `await zapper.claimDeposit(depositId)`
7. **Receive shares**: You get xCUP tokens

## Key Parameters You Need to Know

### For `zapAndDeposit(tokenIn, amount)`
- **tokenIn**: The token address you're investing (e.g., USDC, ETH)
- **amount**: Amount in token's native decimals (e.g., 100000000 for 100 USDC)

### For `approveDeposit(depositId)` and `claimDeposit(depositId)`
- **depositId**: Unique identifier generated when deposit is created

### Contract Addresses & Integration Info

**Core Contracts:**
- **Zapper Contract**: `[TO BE DEPLOYED]`
- **CUP Token**: `[TO BE DEPLOYED]`
- **xCUP Vault**: `[TO BE DEPLOYED]`
- **Copper Price Consumer**: `[TO BE DEPLOYED]`
- **Epoch Manager**: `[TO BE DEPLOYED]`

**Key Constants:**
- **Default Slippage**: 100 basis points (1%)
- **Epoch Duration**: 30 days (configurable)
- **USDC Decimals**: 6
- **CUP Decimals**: 6
- **Copper Price Decimals**: 8

**Role Identifiers:**
- **VAULT_CURATOR_ROLE**: `keccak256("VAULT_CURATOR_ROLE")`
- **HOST_INTEGRATION_ROLE**: `keccak256("HOST_INTEGRATION_ROLE")`
- **DEFAULT_ADMIN_ROLE**: `0x00` (Owner role)

## What Happens Behind the Scenes

### When You Call `zapAndDeposit`:

1. **Input Validation**
   ```solidity
   require(address(tokenIn) != address(0), "Invalid input token address");
   require(amount != 0, "Invalid amount");
   ```

2. **Currency Conversion** (if not USDC)
   ```solidity
   _tradeForToken(address(tokenIn), address(_usdc), amount);
   ```

3. **Copper Price Check**
   ```solidity
   uint256 currentCopperPrice = getCopperPrice();
   uint256 depositValue = amount * currentCopperPrice;
   ```

4. **Vault Deposit**
   ```solidity
   _cup.approve(address(_vault), depositValue);
   shares = _vault.deposit(depositValue, _msgSender());
   ```

### When You Call `claimDeposit`:

1. **Check Deposit Status**
   ```solidity
   require(deposit.user == _msgSender(), "Invalid user");
   require(deposit.approved, "Deposit not approved");
   ```

2. **Process Deposit**
   ```solidity
   _cup.approve(address(_vault), depositValue);
   shares = _vault.deposit(depositValue, _msgSender());
   ```

3. **Clean Up**
   ```solidity
   delete _approvedDeposits[depositId];
   ```

## Security Features & Safeguards

### 1. Advanced Slippage Protection
- **Configurable tolerance** (default 1%, customizable per transaction)
- **MEV attack prevention** through minimum output calculations
- **Sandwich attack resistance** via slippage bounds
- **Price impact monitoring** for large swaps

### 2. Comprehensive Input Validation
- **Zero-address protection** for all address parameters
- **Amount boundary checks** (> 0, within reasonable limits)
- **Deposit ID uniqueness** enforcement
- **ETH value matching** for native ETH deposits
- **Token approval verification** before operations

### 3. Multi-Layer Access Control
- **Role-based permissions** (Owner, Curator, Host Integration)
- **Time-based restrictions** (epoch-active operations)
- **Deposit ownership validation** (only owners can withdraw/claim)
- **Beneficiary authorization** (external deposit flexibility)

### 4. Reentrancy Protection
- **ReentrancyGuard** on all state-changing functions
- **External call isolation** in critical operations
- **State updates before external calls** pattern
- **Safe token transfer practices** throughout

### 5. Emergency & Operational Controls
- **Pausable functionality** for emergency stops
- **Owner withdrawal capabilities** for fund management
- **Epoch-based timing controls** for operational windows
- **Price oracle validation** before critical operations

### 6. Data Integrity Safeguards
- **Deposit state consistency** across all mappings
- **Array integrity maintenance** (swap-and-pop patterns)
- **Event emission** for all state changes
- **Comprehensive error messages** for debugging

## Common Use Cases & Examples

### Case 1: Standard USDC Investment
```javascript
// 1. Approve USDC
await usdc.approve(zapperAddress, 100000000); // 100 USDC

// 2. Create unique deposit ID
const depositId = ethers.utils.keccak256(
  ethers.utils.defaultAbiCoder.encode(
    ['address', 'uint256', 'uint256'],
    [userAddress, Date.now(), 100000000]
  )
);

// 3. Zap and deposit with slippage protection
const tx = await zapper.zapAndDeposit(usdcAddress, 100000000, depositId, 100);
const receipt = await tx.wait();

// 4. Wait for curator approval (monitor events)
zapper.on('DepositApproved', (approvedDepositId, approvedAmount) => {
  if (approvedDepositId === depositId) {
    console.log(`Deposit approved for ${approvedAmount} USDC`);
  }
});

// 5. Claim when approved
const shares = await zapper.claimDeposit(depositId);
console.log(`Received ${shares} xCUP shares`);
```

### Case 2: ETH Investment with Automatic Processing
```javascript
// 1. Direct ETH send (uses receive function)
const tx = await user.sendTransaction({
  to: zapperAddress,
  value: ethers.utils.parseEther('1.0')
});

// 2. OR explicit zap function
const depositId = ethers.utils.keccak256(ethers.utils.toUtf8Bytes('eth_deposit_1'));
const tx = await zapper.zapAndDeposit(
  '0x0000000000000000000000000000000000000000', // ETH
  ethers.utils.parseEther('1.0'),
  depositId,
  200, // 2% slippage for ETH
  { value: ethers.utils.parseEther('1.0') }
);

// 3. Monitor and claim as above
```

### Case 3: Batch Operations (Curator)
```javascript
// 1. Get all pending deposits
const pendingDeposits = await zapper.getPendingDeposits();
console.log(`${pendingDeposits.length} deposits pending approval`);

// 2. Approve proportionally (50% of total)
const totalPending = await zapper.getTotalPendingAmount();
const targetApproval = totalPending.div(2);
await zapper.connect(curator).approveDepositsProportionally(targetApproval);

// 3. OR approve all deposits
await zapper.connect(curator).approveAllDeposits();

// 4. Users can batch claim
const totalShares = await zapper.connect(user).claimAllDeposits();
```

### Case 4: External Integration Flow
```javascript
// 1. Host system registers deposit
const tag = ethers.utils.keccak256(ethers.utils.toUtf8Bytes('integration_ref_123'));
const depositId = await zapper.connect(hostIntegration)
  .registerExternalDepositFor(beneficiaryAddress, 5000000000, tag); // 5000 USDC

// 2. Update beneficiary if needed
await zapper.connect(hostIntegration)
  .setDepositBeneficiary(depositId, newBeneficiaryAddress);

// 3. Curator approves with price snapshot
const priceSnapshot = 450000000; // $4.50 with 8 decimals
await zapper.connect(curator)
  .approveExternalDepositWithPrice(depositId, 5000000000, priceSnapshot);

// 4. Beneficiary claims with locked price
const shares = await zapper.connect(beneficiary).claimDeposit(depositId);
```

## Error Handling

### Common Errors and Solutions

**"Invalid input token address"**
- **Cause**: Token address is zero
- **Solution**: Use correct token address

**"Invalid amount"**
- **Cause**: Amount is zero
- **Solution**: Use amount greater than zero

**"Deposit not approved"**
- **Cause**: Trying to claim before curator approval
- **Solution**: Wait for curator to approve

**"Insufficient CUP balance"**
- **Cause**: Zapper doesn't have enough CUP tokens
- **Solution**: Contact system administrators

## Monitoring Your Investment

### Check Your Balances
```javascript
// Check CUP balance
const cupBalance = await cupToken.balanceOf(userAddress);

// Check xCUP shares
const xcupShares = await xcupVault.balanceOf(userAddress);

// Check copper price
const copperPrice = await zapper.getCopperPrice();
```

### Event Monitoring & Integration
```javascript
// Comprehensive event monitoring
zapper.on('ZapAndDeposit', (router, tokenIn, amount, event) => {
  console.log(`Deposit created: ${amount} of token ${tokenIn}`);
});

zapper.on('DepositApproved', (depositId, approvedAmount, event) => {
  console.log(`Deposit ${depositId} approved for ${approvedAmount}`);
});

zapper.on('DepositClaimed', (depositId, user, shares, event) => {
  console.log(`User ${user} claimed ${shares} shares for deposit ${depositId}`);
});

zapper.on('DepositClaimedFor', (depositId, user, beneficiary, claimedBy, tag, shares) => {
  console.log(`External deposit ${depositId} claimed by ${claimedBy} for beneficiary ${beneficiary}`);
});

zapper.on('ProportionalApproval', (totalApproved, totalDeposited, proportion) => {
  const percentage = proportion.mul(100).div(ethers.utils.parseEther('1'));
  console.log(`Proportional approval: ${percentage}% (${totalApproved}/${totalDeposited})`);
});

zapper.on('ExternalDepositRegistered', (createdBy, beneficiary, depositId, tag, usdcAmount) => {
  console.log(`External deposit registered: ${usdcAmount} USDC for ${beneficiary}`);
});

// Error handling
zapper.on('error', (error) => {
  console.error('Zapper contract error:', error);
});
```

## Advanced Features

### Gasless Transactions (ERC20 Permit)
```javascript
// Use permit for gasless approvals
const permitParams = {
  value: amount,
  deadline: Math.floor(Date.now() / 1000) + 3600, // 1 hour
  v: signature.v,
  r: signature.r,
  s: signature.s
};

await zapper.zapAndDepositWithPermit(
  tokenAddress, amount, permitParams, depositId, slippageBps
);
```

### Withdrawal & Exit Strategies
```javascript
// Withdraw pending deposit before approval
await zapper.withdrawDeposit(depositId);

// Withdraw all pending deposits
const totalRefunded = await zapper.withdrawAllDeposits();

// Redeem xCUP shares for USDC
const usdcReceived = await zapper.redeem(sharesToRedeem);
```

### Price & Market Information
```javascript
// Get current copper price
const copperPrice = await zapper.getCopperPrice();
console.log(`Current copper price: $${copperPrice / 1e8}`);

// Get deposit information
const deposit = await zapper.getDeposit(depositId);
console.log('Deposit details:', {
  user: deposit.user,
  amount: deposit.amount,
  approved: deposit.approved,
  approvedAmount: deposit.approvedAmount,
  isExternal: deposit.isExternal,
  beneficiary: deposit.beneficiary
});

// Get user's deposits
const userDepositIds = await zapper.getUserDepositIds(userAddress);
const userDeposits = await zapper.getUserDeposits(userAddress);
```

## Best Practices

### For Users
1. **Always use unique deposit IDs** to avoid collisions
2. **Monitor gas prices** before transactions, especially for ETH swaps
3. **Set appropriate slippage** based on market conditions
4. **Keep track of deposit IDs** for claiming later
5. **Monitor epoch timing** for claim operations

### For Integrators
1. **Implement proper error handling** for all contract calls
2. **Use event monitoring** for real-time updates
3. **Validate all inputs** before contract interactions
4. **Handle partial approvals** in your UI logic
5. **Implement retry mechanisms** for failed transactions

### For Curators
1. **Review deposits thoroughly** before approval
2. **Use batch operations** for efficiency
3. **Consider vault capacity** when approving
4. **Monitor epoch timing** for approval windows
5. **Use proportional approvals** for fair distribution

## Troubleshooting

### Common Issues

**"Epoch not active"**
- Wait for next epoch or check epoch timing
- Some operations only work during active epochs

**"Deposit ID already exists"**
- Use a different, unique deposit ID
- Consider adding timestamp or nonce to ID generation

**"Insufficient allowance"**
- Approve sufficient tokens before deposit
- Check token balance and allowance

**"Copper price is 0"**
- Oracle issue, wait for price update
- Contact system administrators

**"Invalid ETH amount"**
- Ensure msg.value matches amount parameter for ETH deposits

## Conclusion

The enhanced Zapper system provides a comprehensive, secure, and flexible platform for investing in copper-backed assets. With features like:

- **Multi-token support** for diverse investment options
- **Curator approval system** for professional oversight
- **Batch operations** for operational efficiency
- **External integrations** for institutional use
- **Advanced security features** for user protection

The system enables both individual and institutional investors to gain exposure to copper markets through their existing cryptocurrencies, with professional oversight and comprehensive risk management. 