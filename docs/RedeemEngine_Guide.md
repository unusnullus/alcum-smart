# RedeemEngine Contract - User Guide

## Overview

The `RedeemEngine` is a dedicated contract that handles all redemption operations for the Alcum Protocol. It was separated from the main `Zapper` contract to provide better security, fund isolation, and operational clarity.

### Key Features

-   **Two Redemption Modes**: Request-based (no commission) and direct (with commission)
-   **Dedicated Silo**: Separate Silo contract for USDC management during redemptions
-   **Commission System**: Configurable commission for direct redemptions
-   **Full Security**: Reentrancy protection, access control, and pausable functionality

## Architecture

```
┌─────────────────────────────────────────────────────────┐
│                    RedeemEngine                          │
├─────────────────────────────────────────────────────────┤
│  • Request-based redemption (no commission)             │
│  • Direct redemption (with commission)                   │
│  • Dedicated Redeem Silo for USDC management            │
│  • Commission management                                 │
└─────────────────────────────────────────────────────────┘
         │                    │                    │
         ▼                    ▼                    ▼
┌──────────────┐    ┌──────────────┐    ┌──────────────┐
│   xCUP Vault │    │ Redeem Silo  │    │ Price Oracle │
│  (ERC4626)   │    │   (USDC)     │    │  (Copper)    │
└──────────────┘    └──────────────┘    └──────────────┘
```

## Redemption Flows

### Flow 1: Request-Based Redemption (No Commission)

This flow is suitable for users who want to redeem without paying commission but are willing to wait for curator approval. **Note: xCUP shares are transferred to the contract immediately upon request.**

```
User Action                    Contract Function                    State Changes
     ↓                              ↓                                    ↓
1. Approve xCUP             xcup.approve(redeemEngine, shares)    Allowance set
     ↓                              ↓                                    ↓
2. Request Redeem           redeemEngine.requestRedeem(shares)      Shares transferred to contract, request created
     ↓                              ↓                                    ↓
3. Wait for Approval        [Curator Review Process]              Request pending
     ↓                              ↓                                    ↓
4. Curator Approves         redeemEngine.approveRedeem(...)        Request approved
     ↓                              ↓                                    ↓
5. User Claims              redeemEngine.claimRedeem(redeemId)      USDC to user, shares burned
     ↓                              ↓                                    ↓
6. Receive USDC             User receives USDC                     Redemption complete
```

**Step-by-Step**:

1. **Approve xCUP Shares** (Required first step):

    ```javascript
    await xcup.approve(redeemEngineAddress, shares);
    ```

2. **Request Redemption** (Shares are immediately transferred to contract):

    ```javascript
    const redeemId = await redeemEngine.requestRedeem(shares);
    // Shares are now held by the contract
    ```

3. **Curator Approves** (Curator only):

    ```javascript
    await redeemEngine.connect(curator).approveRedeem(redeemId, usdcAmount);
    ```

4. **User Claims** (Uses shares already in contract):
    ```javascript
    const usdcReceived = await redeemEngine.claimRedeem(redeemId);
    ```

### Flow 2: Direct Redemption (With Commission)

This flow allows immediate redemption with a commission fee. The commission stays in the redeem silo.

```
User Action                    Contract Function                    State Changes
     ↓                              ↓                                    ↓
1. Direct Redeem            redeemEngine.redeem(shares)            Shares burned, CUP withdrawn
     ↓                              ↓                                    ↓
2. Price Conversion          Convert CUP → USDC (via oracle)      USDC amount calculated
     ↓                              ↓                                    ↓
3. Commission Applied        Commission deducted                   Commission to silo
     ↓                              ↓                                    ↓
4. USDC Transfer            USDC to user (minus commission)        User receives USDC
     ↓                              ↓                                    ↓
5. Complete                  Redemption complete                    Commission in silo
```

**Step-by-Step**:

```javascript
// Direct redemption with commission
const usdcReceived = await redeemEngine.redeem(sharesToRedeem);
// Commission is automatically deducted and stays in redeem silo
```

## Core Functions

### 1. `requestRedeem(uint256 shares)`

Creates a new redeem request and **immediately transfers xCUP shares from the user to the contract**. The user must approve the contract to spend their xCUP shares before calling this function.

**Parameters**:

-   `shares`: Number of xCUP vault shares to redeem

**Returns**: `bytes32` - Unique redeem request ID

**Who can call**: Any user with xCUP shares

**Important**:

-   User must approve `redeemEngine` to spend their xCUP shares before calling this function
-   Shares are immediately transferred to the contract upon request
-   Shares remain in the contract until `claimRedeem` is called

**Example**:

```javascript
// Step 1: Approve shares first
const shares = ethers.parseUnits("1000", 6); // 1000 xCUP shares
await xcup.approve(redeemEngineAddress, shares);

// Step 2: Request redeem (shares are transferred to contract)
const redeemId = await redeemEngine.requestRedeem(shares);
console.log(`Redeem request created: ${redeemId}`);
// Shares are now held by the contract
```

### 2. `approveRedeem(bytes32 redeemId, uint256 usdcAmount)`

Approves a pending redeem request. Only curators can call this function.

**Parameters**:

-   `redeemId`: Unique identifier of the redeem request
-   `usdcAmount`: USDC amount to approve for payout

**Who can call**: Addresses with `VAULT_CURATOR_ROLE`

**Example**:

```javascript
const usdcAmount = ethers.parseUnits("4500", 6); // 4500 USDC
await redeemEngine.connect(curator).approveRedeem(redeemId, usdcAmount);
```

### 3. `claimRedeem(bytes32 redeemId)`

Claims an approved redeem request and receives USDC. **Uses xCUP shares that were already transferred to the contract during `requestRedeem`.**

**Parameters**:

-   `redeemId`: Unique identifier of the redeem request

**Returns**: `uint256` - Amount of USDC received

**Who can call**: User who created the redeem request

**Important**:

-   Shares must already be in the contract (transferred during `requestRedeem`)
-   No additional approval needed - shares are already in the contract
-   The contract will redeem the shares, convert CUP to USDC, and send USDC to the user

**Example**:

```javascript
// Shares are already in contract from requestRedeem
const usdcReceived = await redeemEngine.claimRedeem(redeemId);
console.log(`Received ${usdcReceived} USDC`);
```

### 4. `redeem(uint256 sharesToRedeem)`

Directly redeems xCUP shares for USDC with commission.

**Parameters**:

-   `sharesToRedeem`: Number of xCUP vault shares to redeem

**Returns**: `uint256` - Amount of USDC received (after commission)

**Who can call**: Any user with xCUP shares

**Example**:

```javascript
const shares = ethers.parseUnits("1000", 6);
const usdcReceived = await redeemEngine.redeem(shares);
// Commission is automatically deducted
```

### 5. `getRedeem(bytes32 redeemId)`

Returns full information about a redeem request.

**Parameters**:

-   `redeemId`: Unique identifier of the redeem request

**Returns**: `RedeemRequest` struct with:

-   `user`: Address of the requester
-   `shares`: Number of shares to redeem
-   `usdcAmount`: Approved USDC amount
-   `approved`: Whether the request is approved
-   `claimed`: Whether the request has been claimed

**Example**:

```javascript
const redeemInfo = await redeemEngine.getRedeem(redeemId);
console.log({
    user: redeemInfo.user,
    shares: redeemInfo.shares.toString(),
    usdcAmount: redeemInfo.usdcAmount.toString(),
    approved: redeemInfo.approved,
    claimed: redeemInfo.claimed,
});
```

### 6. `getRedeemCommission()`

Returns the current commission rate for direct redemptions.

**Returns**: `uint256` - Commission rate in basis points (e.g., 200 = 2%)

**Example**:

```javascript
const commissionBps = await redeemEngine.getRedeemCommission();
const commissionPercent = Number(commissionBps) / 100;
console.log(`Current commission: ${commissionPercent}%`);
```

### 7. `redeemSilo()`

Returns the address of the dedicated redeem Silo contract.

**Returns**: `address` - Redeem Silo contract address

**Example**:

```javascript
const siloAddress = await redeemEngine.redeemSilo();
console.log(`Redeem Silo: ${siloAddress}`);
```

## Admin Functions

### `setRedeemCommission(uint256 commissionBps)`

Sets the commission rate for direct redemptions.

**Parameters**:

-   `commissionBps`: Commission rate in basis points (e.g., 200 = 2%, max 10000 = 100%)

**Who can call**: Addresses with `DEFAULT_ADMIN_ROLE`

**Example**:

```javascript
// Set 2% commission
await redeemEngine.connect(admin).setRedeemCommission(200);
```

### `withdrawFromRedeemSilo(uint256 amount)`

Withdraws USDC from the redeem Silo to the contract owner.

**Parameters**:

-   `amount`: Amount of USDC to withdraw (6 decimals)

**Who can call**: Addresses with `VAULT_CURATOR_ROLE`

**Example**:

```javascript
const amount = ethers.parseUnits("10000", 6); // 10000 USDC
await redeemEngine.connect(curator).withdrawFromRedeemSilo(amount);
```

### `pause()` / `unpause()`

Pauses or unpauses the contract, preventing new redeem requests and claims.

**Who can call**: Contract owner

**Example**:

```javascript
// Pause contract
await redeemEngine.pause();

// Unpause contract
await redeemEngine.unpause();
```

## Commission System

The commission system applies only to direct redemptions (`redeem()` function). Request-based redemptions have no commission.

### How Commission Works

1. User calls `redeem(shares)`
2. Contract calculates total USDC amount based on copper price
3. Commission is calculated: `commissionAmount = totalUsdcAmount * commissionBps / 10000`
4. User receives: `usdcToWithdraw = totalUsdcAmount - commissionAmount`
5. Commission stays in the redeem silo

### Commission Examples

**Example 1: 0% Commission**

```javascript
// Commission: 0%
// User redeems 1000 shares worth 4500 USDC
// User receives: 4500 USDC
// Commission: 0 USDC
```

**Example 2: 2% Commission**

```javascript
// Commission: 2% (200 basis points)
// User redeems 1000 shares worth 4500 USDC
// Commission: 4500 * 200 / 10000 = 90 USDC
// User receives: 4500 - 90 = 4410 USDC
// Commission stays in silo: 90 USDC
```

**Example 3: 5% Commission**

```javascript
// Commission: 5% (500 basis points)
// User redeems 1000 shares worth 4500 USDC
// Commission: 4500 * 500 / 10000 = 225 USDC
// User receives: 4500 - 225 = 4275 USDC
// Commission stays in silo: 225 USDC
```

## Security Features

### 1. Reentrancy Protection

All state-changing functions are protected with `nonReentrant` modifier.

### 2. Access Control

-   `VAULT_CURATOR_ROLE`: Can approve redeem requests and withdraw from silo
-   `DEFAULT_ADMIN_ROLE`: Can set commission rates
-   `Owner`: Can pause/unpause the contract

### 3. Input Validation

-   Share amounts must be > 0
-   Users must own sufficient shares
-   Copper price must be > 0
-   Redeem silo must have sufficient USDC balance

### 4. Pausable Functionality

Contract can be paused in emergency situations to prevent new operations.

### 5. Fund Isolation

Dedicated Silo contract ensures redeem funds are isolated from other operations.

## Error Handling

### Common Errors

**"Shares to redeem must be greater than 0"**

-   Cause: Attempting to redeem zero shares
-   Solution: Use a positive share amount

**"Insufficient shares to redeem"**

-   Cause: User doesn't own enough xCUP shares when calling `requestRedeem`
-   Solution: Check user's xCUP balance before requesting

**"Insufficient shares in contract"**

-   Cause: Contract doesn't have the required shares when calling `claimRedeem` (shouldn't happen in normal flow)
-   Solution: Ensure `requestRedeem` was called successfully and shares were transferred

**"Copper price is 0"**

-   Cause: Oracle returned zero price
-   Solution: Wait for price update or contact administrators

**"Insufficient USDC in redeem silo"**

-   Cause: Redeem silo doesn't have enough USDC
-   Solution: Redeem silo must be funded before redemptions

**"InvalidRedeemRequest"**

-   Cause: Redeem request doesn't exist or is invalid
-   Solution: Use a valid redeem ID

**"NotApproved"**

-   Cause: Attempting to claim unapproved redeem request
-   Solution: Wait for curator approval

**"AlreadyClaimed"**

-   Cause: Attempting to claim already claimed redeem request
-   Solution: Each redeem request can only be claimed once

## Best Practices

### For Users

1. **Choose the Right Flow**:

    - Use request-based flow if you want to avoid commission
    - Use direct flow if you need immediate redemption

2. **Approve Before Requesting** (Request-based flow only):

    ```javascript
    // Always approve shares before calling requestRedeem
    await xcup.approve(redeemEngineAddress, shares);
    ```

3. **Check Share Balance**:

    ```javascript
    const balance = await xcup.balanceOf(userAddress);
    ```

4. **Monitor Redeem Status**:

    ```javascript
    const redeemInfo = await redeemEngine.getRedeem(redeemId);
    ```

5. **Check Commission Rate**:

    ```javascript
    const commission = await redeemEngine.getRedeemCommission();
    ```

6. **Understand Share Transfer**:
    - In request-based flow, shares are transferred to the contract immediately upon `requestRedeem`
    - Shares remain in the contract until `claimRedeem` is called
    - No need to approve again for `claimRedeem` - shares are already in the contract

### For Curators

1. **Review Requests Thoroughly**: Check all redeem requests before approval
2. **Ensure Silo Funding**: Make sure redeem silo has sufficient USDC
3. **Monitor Commission**: Track commission accumulation in redeem silo

### For Administrators

1. **Set Appropriate Commission**: Balance between revenue and user experience
2. **Monitor Silo Balance**: Ensure redeem silo is adequately funded
3. **Emergency Controls**: Use pause functionality when needed

## Integration Examples

### Full Request-Based Redemption Flow

```javascript
// 1. Approve xCUP shares first (required)
const shares = ethers.parseUnits("1000", 6);
await xcup.approve(redeemEngineAddress, shares);

// 2. User requests redemption (shares are transferred to contract)
const redeemId = await redeemEngine.requestRedeem(shares);
// Shares are now held by the contract

// 3. Wait for curator approval (monitor events)
redeemEngine.on("RedeemApproved", (approvedRedeemId, shares, usdcAmount) => {
    if (approvedRedeemId === redeemId) {
        console.log(`Redeem approved: ${usdcAmount} USDC`);
    }
});

// 4. User claims after approval (uses shares already in contract)
const usdcReceived = await redeemEngine.claimRedeem(redeemId);
console.log(`Received ${usdcReceived} USDC`);
```

### Direct Redemption with Commission

```javascript
// Direct redemption
const shares = ethers.parseUnits("1000", 6);
const commissionBps = await redeemEngine.getRedeemCommission();

// Calculate expected USDC (approximate)
const copperPrice = await redeemEngine.getCopperPrice();
const expectedCup = shares; // Simplified
const expectedUsdc = (expectedCup * copperPrice) / 10n ** 8n;
const commission = (expectedUsdc * BigInt(commissionBps)) / 10000n;
const expectedUsdcAfterCommission = expectedUsdc - commission;

// Execute redemption
const usdcReceived = await redeemEngine.redeem(shares);
console.log(`Received ${usdcReceived} USDC (commission: ${commissionBps / 100}%)`);
```

## Events

### `RedeemRequested`

Emitted when a new redeem request is created.

```solidity
event RedeemRequested(address indexed user, bytes32 indexed redeemId, uint256 shares);
```

### `RedeemApproved`

Emitted when a redeem request is approved by curator.

```solidity
event RedeemApproved(bytes32 indexed redeemId, uint256 shares, uint256 usdcAmount);
```

### `RedeemClaimed`

Emitted when a redeem request is claimed by user.

```solidity
event RedeemClaimed(address indexed user, bytes32 indexed redeemId, uint256 usdcAmount);
```

### `DirectRedeemExecuted`

Emitted when a direct redemption is executed.

```solidity
event DirectRedeemExecuted(address indexed user, uint256 shares, uint256 usdcAmount, uint256 commissionAmount);
```

### `RedeemCommissionUpdated`

Emitted when commission rate is updated.

```solidity
event RedeemCommissionUpdated(uint256 newCommissionBps);
```

### `RedeemSiloWithdrawn`

Emitted when USDC is withdrawn from redeem silo.

```solidity
event RedeemSiloWithdrawn(address indexed to, uint256 amount);
```

## Conclusion

The RedeemEngine provides a secure, flexible, and efficient system for redeeming xCUP shares. With two redemption modes, dedicated fund management, and comprehensive security features, it ensures users can exit their positions safely while maintaining protocol integrity.
