# Proportional Approval Tests Documentation

## Overview

The `approveDepositsProportionally` function allows vault curators to approve multiple pending deposits proportionally based on a target total amount. This document describes the comprehensive test coverage implemented for this function.

## Function Behavior

The function:
1. **Validates inputs**: Ensures target amount > 0 and pending deposits exist
2. **Calculates totals**: Sums all valid pending deposit amounts  
3. **Computes proportion**: `(targetTotal * 1e18) / totalPending`
4. **Applies proportionally**: Each deposit gets `(depositAmount * proportion) / 1e18`
5. **Emits events**: Individual `DepositApproved` events and one `ProportionalApproval` event

## Test Coverage

### ✅ **Basic Functionality Tests**

| Test | Description | Scenario |
|------|-------------|----------|
| `testApproveDepositsProportionally_BasicScenario` | Standard usage with 3 users | 100, 200, 300 token deposits → 50% approval |
| `testApproveDepositsProportionally_MaxTarget` | Full approval scenario | Target equals total pending (100%) |
| `testApproveDepositsProportionally_SmallTarget` | Minimal approval scenario | Target is only 10% of total |

### ✅ **Multi-User Scenarios**

| Test | Description | Users | Amounts |
|------|-------------|-------|---------|
| `testApproveDepositsProportionally_MultipleUsersWithVaryingAmounts` | All 5 test users | user1-5 | 10, 500, 1500, 50, 2500 tokens |
| **Account Setup** | All users have sufficient balances | user1-5 | 10,000 ERC20Mock, USDC, CUP each |

### ✅ **Edge Cases & Error Conditions**

| Test | Expected Revert | Condition |
|------|----------------|-----------|
| `testApproveDepositsProportionally_RevertZeroTarget` | `"Target amount must be greater than 0"` | Target = 0 |
| `testApproveDepositsProportionally_RevertNoPendingDeposits` | `"No pending deposits"` | No deposits created |
| `testApproveDepositsProportionally_RevertTargetExceedsTotal` | `"Target amount exceeds total pending"` | Target > total pending |
| `testApproveDepositsProportionally_RevertWhenPaused` | Pausable revert | Contract paused |
| `testApproveDepositsProportionally_RevertWhenEpochNotActive` | `"Epoch not active"` | Epoch ended |
| `testApproveDepositsProportionally_RevertNonCurator` | AccessControl revert | Non-curator calls |

### ✅ **Precision & Mathematical Tests**

| Test | Description | Purpose |
|------|-------------|---------|
| `testApproveDepositsProportionally_PrecisionTest` | Minimal amounts (1, 999, 1000) | Test precision edge cases |
| `testApproveDepositsProportionally_ExactCalculationExample` | Detailed calculation logging | Verify mathematical accuracy |

### ✅ **State Interaction Tests**

| Test | Description | Scenario |
|------|-------------|----------|
| `testApproveDepositsProportionally_SkipsAlreadyApprovedDeposits` | Mixed approved/pending | Pre-approve one deposit, then run proportional |
| `testApproveDepositsProportionally_EventEmission` | Event verification | Check all expected events are emitted |

## Test Accounts

```solidity
address internal owner  = 0xC8fb6C1b2377670f5FD1bD3f58926B2d7B7b0971; // Contract owner
address internal admin  = 0x1234567890123456789012345678901234567890; // VAULT_CURATOR_ROLE
address internal user1  = 0x1111111111111111111111111111111111111111; // Test depositor
address internal user2  = 0x2222222222222222222222222222222222222222; // Test depositor  
address internal user3  = 0x3333333333333333333333333333333333333333; // Test depositor
address internal user4  = 0x4444444444444444444444444444444444444444; // Test depositor
address internal user5  = 0x5555555555555555555555555555555555555555; // Test depositor
```

## Mathematical Example

Given deposits of 1000, 2000, 3000 tokens:
- **Total pending**: 6000 tokens worth
- **Target**: 3600 (60% of total)  
- **Proportion**: `(3600 * 1e18) / 6000 = 0.6e18`
- **Approvals**: 
  - User1: `(1000 * 0.6e18) / 1e18 = 600`
  - User2: `(2000 * 0.6e18) / 1e18 = 1200` 
  - User3: `(3000 * 0.6e18) / 1e18 = 1800`

## Running Tests

```bash
# Run all proportional approval tests
forge test --match-contract ZapperProportionalApprovalTest -vv

# Run specific calculation example with detailed logs  
forge test --match-test testApproveDepositsProportionally_ExactCalculationExample -vvv

# Or use the provided script
./test_proportional_approval.sh
```

## Dependencies

- **Foundry**: Testing framework
- **OpenZeppelin**: Access control and utilities
- **Uniswap V2**: DEX integration for token swaps
- **Custom Contracts**: CUPToken, xCUP, EpochManager, Zapper

## Notes

- Tests use mainnet fork for realistic DEX interactions
- ERC20Mock token is used for consistent test token amounts  
- Deposit values are calculated based on swap rates (approximated in tests)
- All tests include proper setup/teardown and state isolation
- Event emissions are thoroughly tested for audit compliance