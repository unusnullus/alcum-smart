# Zapper Contract - User Guide

## What is the Zapper?

The Zapper is a smart contract that helps you invest in copper-backed assets by converting your cryptocurrencies into CUP tokens and then depositing them into the xCUP vault. It's like a bridge that automatically converts your digital money into copper investments.

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

### 1. `zapAndDeposit(tokenIn, amount)`
**Purpose**: Main function to convert tokens and invest in the vault

**What it does**:
1. Takes your input token (any ERC-20) and amount
2. Converts it to USDC via Uniswap
3. Calculates CUP amount based on copper price
4. Deposits CUP into xCUP vault
5. Returns xCUP shares to you

**Parameters**:
- `tokenIn`: Address of the token you're investing (e.g., USDC, ETH, BTC)
- `amount`: How much you want to invest (in token decimals)

**Example**:
```javascript
// Invest 100 USDC
await zapper.zapAndDeposit(usdcAddress, 100000000); // 100 USDC with 6 decimals
```

### 2. `approveDeposit(depositId)`
**Purpose**: Curator function to approve large investments

**What it does**:
1. Reviews a pending deposit request
2. Approves or declines based on criteria
3. Updates deposit status for user to claim

**Parameters**:
- `depositId`: Unique identifier for the deposit request

**Who can call**: Only users with `VAULT_CURATOR_ROLE`

### 3. `claimDeposit(depositId)`
**Purpose**: User function to claim approved deposits

**What it does**:
1. Checks if deposit is approved
2. Transfers CUP tokens to vault
3. Issues xCUP shares to user
4. Clears the deposit record

**Parameters**:
- `depositId`: Unique identifier for the deposit request

### 4. `getCopperPrice()`
**Purpose**: Gets current copper price from oracle

**What it does**:
1. Calls the Copper Price Consumer contract
2. Returns current copper price in USD
3. Used for calculating CUP amounts

**Returns**: `uint256` - Current copper price

## Investment Flows

### Flow 1: Direct Investment (Small Amounts)

```
User Action                    Contract Function
     ↓                              ↓
1. Approve USDC              token.approve(zapper, amount)
     ↓                              ↓
2. Zap and Deposit           zapper.zapAndDeposit(usdc, amount)
     ↓                              ↓
3. Convert to CUP            Calculate based on copper price
     ↓                              ↓
4. Deposit to Vault          vault.deposit(cupAmount, user)
     ↓                              ↓
5. Receive Shares            User gets xCUP shares
```

**Step-by-Step Process**:
1. **Approve USDC**: `await usdc.approve(zapperAddress, amount)`
2. **Call zapAndDeposit**: `await zapper.zapAndDeposit(usdcAddress, amount)`
3. **System calculates CUP**: Based on current copper price
4. **Deposit to vault**: CUP tokens go to xCUP vault
5. **Receive shares**: You get xCUP tokens representing your investment

### Flow 2: Approval Required (Large Amounts)

```
User Action                    Contract Function
     ↓                              ↓
1. Approve Token             token.approve(zapper, amount)
     ↓                              ↓
2. Zap and Deposit           zapper.zapAndDeposit(token, amount)
     ↓                              ↓
3. Generate Deposit ID       Create unique depositId
     ↓                              ↓
4. Wait for Approval         Curator reviews deposit
     ↓                              ↓
5. Curator Approves          zapper.approveDeposit(depositId)
     ↓                              ↓
6. User Claims               zapper.claimDeposit(depositId)
     ↓                              ↓
7. Receive Shares            User gets xCUP shares
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

### Important Addresses
- **Zapper Contract**: `0xD10B1B9eC5E0bd43107CCb501AC3a5E8Cbc2b358`
- **CUP Token**: `0xa7bE870C21b79EcA2E16baaB1294436e37aD72D6`
- **xCUP Vault**: `0x3d47C937F0706dB77339aa1c26aBCc12C644c882`
- **Copper Price Consumer**: `0xdAfD3DB6a8EaD46d912935cE0eb1277539eecAeC`

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

## Safety Features

### 1. Slippage Protection
- **1% tolerance** on token swaps
- **Prevents bad trades** due to price movements
- **Automatic calculation** of minimum output

### 2. Input Validation
- **Checks token addresses** are valid
- **Ensures amounts** are greater than zero
- **Validates user permissions** for each function

### 3. Role-Based Access
- **Only curators** can approve deposits
- **Only deposit owners** can claim their deposits
- **Only owner** can pause/unpause system

### 4. Emergency Controls
- **Pause function** for emergencies
- **Protects user funds** during issues
- **Allows maintenance** and updates

## Common Use Cases

### Case 1: Small Investment (Direct)
```javascript
// 1. Approve USDC
await usdc.approve(zapperAddress, 100000000); // 100 USDC

// 2. Invest directly
const tx = await zapper.zapAndDeposit(usdcAddress, 100000000);
const receipt = await tx.wait();

// 3. Get shares from event
const event = receipt.events.find(e => e.event === 'ZapInAndDeposit');
const shares = event.args.shares;
```

### Case 2: Large Investment (Approval Required)
```javascript
// 1. Approve token
await token.approve(zapperAddress, largeAmount);

// 2. Create deposit (returns depositId)
const tx = await zapper.zapAndDeposit(tokenAddress, largeAmount);
const receipt = await tx.wait();

// 3. Get depositId from event
const event = receipt.events.find(e => e.event === 'ZapIn');
const depositId = event.args.depositId;

// 4. Wait for curator approval (off-chain)

// 5. Claim after approval
const shares = await zapper.claimDeposit(depositId);
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

### Track Events
```javascript
// Listen for deposit events
zapper.on("ZapInAndDeposit", (router, tokenIn, amount, shares) => {
    console.log(`Invested ${amount} of ${tokenIn} for ${shares} shares`);
});

// Listen for approval events
zapper.on("DepositApproved", (depositId) => {
    console.log(`Deposit ${depositId} approved`);
});
```

## Conclusion

The Zapper system provides a streamlined way to invest in copper-backed assets. The core flow is simple: approve tokens → zap and deposit → receive shares. For large investments, there's an additional approval step for security.

The system automatically handles currency conversion, price calculations, and vault deposits, making it easy for users to gain exposure to copper markets through their existing cryptocurrencies. 