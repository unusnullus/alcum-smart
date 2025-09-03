# Zapper Contract Security Audit Report

## Executive Summary

The Zapper contract has been analyzed for security vulnerabilities. Several critical and high-severity issues were identified, primarily related to reentrancy attacks, deposit ID generation, and state management. This report provides detailed analysis and recommended fixes.

## Critical Vulnerabilities

### 1. **CRITICAL: Reentrancy Vulnerability in `withdrawDeposit`**

**Location:** Lines 325-340
**Severity:** Critical

**Issue:** The `withdrawDeposit` function performs state changes after external calls, making it vulnerable to reentrancy attacks.

```solidity
function withdrawDeposit(bytes32 depositId) external whenNotPaused {
    Deposit storage deposit = _approvedDeposits[depositId];
    // ... checks ...
    uint256 refundAmount = deposit.amount;
    delete _approvedDeposits[depositId];  // State change
    _removePendingDeposit(depositId);     // State change
    
    // External call AFTER state changes
    _usdc.safeTransferFrom(address(silo()), _msgSender(), refundAmount);
}
```

**Attack Vector:** A malicious token contract could reenter the function during the `safeTransferFrom` call, potentially allowing double withdrawals.

**Fix:**
```solidity
function withdrawDeposit(bytes32 depositId) external whenNotPaused {
    Deposit storage deposit = _approvedDeposits[depositId];
    
    require(deposit.user == _msgSender(), "Invalid user");
    require(deposit.user != address(0), "Deposit not found");
    require(!deposit.approved, "Deposit already approved");
    
    uint256 refundAmount = deposit.amount;
    address user = _msgSender();
    
    // Clear state BEFORE external call
    delete _approvedDeposits[depositId];
    _removePendingDeposit(depositId);
    
    // External call after state changes
    require(_usdc.balanceOf(address(silo())) >= refundAmount, "Insufficient USDC balance");
    _usdc.safeTransferFrom(address(silo()), user, refundAmount);
    
    emit DepositWithdrawn(depositId, user, refundAmount);
}
```

### 2. **CRITICAL: Reentrancy Vulnerability in `declineDeposit`**

**Location:** Lines 365-380
**Severity:** Critical

**Issue:** Similar to `withdrawDeposit`, state changes occur after external calls.

**Fix:**
```solidity
function declineDeposit(bytes32 depositId) external whenNotPaused whenEpochActive onlyRole(VAULT_CURATOR_ROLE) {
    Deposit storage deposit = _approvedDeposits[depositId];
    
    require(deposit.user != address(0), "Deposit not found");
    require(!deposit.approved, "Deposit already approved");
    
    uint256 refundAmount = deposit.amount;
    address user = deposit.user;
    
    // Clear state BEFORE external call
    delete _approvedDeposits[depositId];
    _removePendingDeposit(depositId);
    
    // External call after state changes
    require(_usdc.balanceOf(address(_silo)) >= refundAmount, "Insufficient USDC balance");
    _usdc.safeTransferFrom(address(_silo), user, refundAmount);
    
    emit DepositDeclined(depositId, user, refundAmount);
}
```

### 3. **CRITICAL: Reentrancy Vulnerability in `redeem`**

**Location:** Lines 490-520
**Severity:** Critical

**Issue:** Multiple external calls without proper reentrancy protection.

**Fix:**
```solidity
function redeem(uint256 sharesToRedeem) external returns (uint256 usdcToWithdraw) {
    require(sharesToRedeem > 0, "Shares to redeem must be greater than 0");
    
    uint256 ownedShares = _vault.balanceOf(_msgSender());
    require(ownedShares >= sharesToRedeem, "Insufficient shares to redeem");
    
    // Transfer shares to contract first
    IERC20(address(_vault)).safeTransferFrom(_msgSender(), address(this), sharesToRedeem);
    
    // Approve vault to spend shares
    _vault.approve(address(_vault), sharesToRedeem);
    
    // Redeem shares for CUP
    uint256 withdrawnCup = _vault.redeem(sharesToRedeem, address(this), address(this));
    
    uint256 copperPrice = getCopperPrice();
    require(copperPrice > 0, "Copper price is 0");
    
    usdcToWithdraw = withdrawnCup / copperPrice;
    
    // Transfer USDC from silo to contract
    _usdc.safeTransferFrom(address(_silo), address(this), usdcToWithdraw);
    
    // Verify balance before transfer
    require(_usdc.balanceOf(address(this)) >= usdcToWithdraw, "Insufficient USDC balance");
    
    // Transfer to user
    _usdc.safeTransfer(_msgSender(), usdcToWithdraw);
    
    emit Withdraw(_msgSender(), usdcToWithdraw);
}
```

## High Severity Vulnerabilities

### 4. **HIGH: Predictable Deposit ID Generation**

**Location:** Line 230
**Severity:** High

**Issue:** Deposit IDs are generated using `block.timestamp`, making them predictable and potentially allowing front-running attacks.

```solidity
depositId = keccak256(abi.encodePacked(_msgSender(), block.timestamp, amount));
```

**Fix:**
```solidity
// Add a nonce to prevent predictability
mapping(address => uint256) private _userNonces;

function _recordDeposit(uint256 amount) internal returns (bytes32 depositId) {
    uint256 nonce = _userNonces[_msgSender()]++;
    depositId = keccak256(abi.encodePacked(_msgSender(), nonce, amount));
    
    _approvedDeposits[depositId] = Deposit({
        user: _msgSender(),
        depositId: depositId,
        amount: amount,
        approvedAmount: 0,
        approved: false
    });
    _pendingDepositIds.push(depositId);
}
```

### 5. **HIGH: Missing Reentrancy Guard**

**Location:** Throughout contract
**Severity:** High

**Issue:** No reentrancy protection mechanism implemented.

**Fix:** Add OpenZeppelin's ReentrancyGuard:

```solidity
import {ReentrancyGuardUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";

contract Zapper is Initializable, AccessControlUpgradeable, OwnableUpgradeable, PausableUpgradeable, ReentrancyGuardUpgradeable {
    // ... existing code ...
    
    function initialize(...) public initializer {
        // ... existing initialization ...
        __ReentrancyGuard_init();
    }
    
    // Add nonReentrant modifier to vulnerable functions
    function withdrawDeposit(bytes32 depositId) external whenNotPaused nonReentrant {
        // ... implementation ...
    }
    
    function declineDeposit(bytes32 depositId) external whenNotPaused whenEpochActive onlyRole(VAULT_CURATOR_ROLE) nonReentrant {
        // ... implementation ...
    }
    
    function redeem(uint256 sharesToRedeem) external nonReentrant returns (uint256 usdcToWithdraw) {
        // ... implementation ...
    }
}
```

## Medium Severity Vulnerabilities

### 6. **MEDIUM: Precision Loss in Price Calculations**

**Location:** Lines 470, 500
**Severity:** Medium

**Issue:** Division operations can cause precision loss, especially with small amounts.

**Fix:**
```solidity
// Use higher precision for calculations
uint256 cupValue = (approvedAmount * currentCopperPrice) / 1e6; // Assuming 6 decimals for USDC

// For redeem function
usdcToWithdraw = (withdrawnCup * 1e6) / copperPrice; // Multiply first, then divide
```

### 7. **MEDIUM: Hardcoded WETH Address**

**Location:** Line 260
**Severity:** Medium

**Issue:** WETH address is hardcoded, making the contract non-portable across networks.

**Fix:**
```solidity
// Use router's WETH address
if (address(tokenIn) != _router.WETH()) {
    tokenIn.forceApprove(router(), amount);
} else {
    require(msg.value == amount, "Invalid ETH amount");
}
```

### 8. **MEDIUM: Missing Zero Address Validation**

**Location:** Line 175
**Severity:** Medium

**Issue:** Not all addresses are validated for zero address in initialize function.

**Fix:**
```solidity
function initialize(
    address cup,
    address usdc,
    address vault,
    address router,
    address copperPriceConsumer,
    address epochManager
) public initializer {
    require(cup != address(0), "Invalid CUP address");
    require(usdc != address(0), "Invalid USDC address");
    require(vault != address(0), "Invalid Vault address");
    require(router != address(0), "Invalid Router address");
    require(copperPriceConsumer != address(0), "Invalid Copper Price Consumer address");
    require(epochManager != address(0), "Invalid Epoch Manager address");
    
    // ... rest of initialization ...
}
```

## Low Severity Vulnerabilities

### 9. **LOW: Gas Limit Issues in Loops**

**Location:** Lines 215, 400
**Severity:** Low

**Issue:** Unbounded loops could cause gas limit issues with large arrays.

**Fix:** Consider pagination or limiting array sizes.

### 10. **LOW: Missing Events for Critical Operations**

**Location:** Throughout contract
**Severity:** Low

**Issue:** Some state changes don't emit events.

**Fix:** Add events for all critical state changes.

## Recommendations

1. **Immediate Actions:**
   - Implement reentrancy guards on all external call functions
   - Fix deposit ID generation to use nonces
   - Add proper state management (checks-effects-interactions pattern)

2. **Code Quality:**
   - Add comprehensive unit tests for edge cases
   - Implement fuzzing tests for complex functions
   - Add formal verification for critical paths

3. **Monitoring:**
   - Implement circuit breakers for emergency situations
   - Add comprehensive logging and monitoring
   - Consider implementing timelock for critical operations

4. **Architecture:**
   - Consider separating concerns into multiple contracts
   - Implement upgradeable patterns more securely
   - Add emergency pause mechanisms

## Conclusion

The Zapper contract has several critical security vulnerabilities that must be addressed before deployment. The most critical issues are reentrancy vulnerabilities that could lead to fund loss. Implementing the suggested fixes and conducting thorough testing is essential for secure deployment.
