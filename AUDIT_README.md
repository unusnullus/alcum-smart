# Alcum Protocol - Security Audit Documentation

## Executive Summary

This document provides comprehensive information for security auditors reviewing the Alcum Protocol smart contracts. The Alcum Protocol is a DeFi platform that enables users to invest in copper-backed assets through a sophisticated ecosystem of smart contracts, combining real-world copper trading operations with blockchain technology.

**Protocol Version:** 1.0.0  
**Audit Date:** [To be filled by auditor]  
**Auditor:** [To be filled by auditor]  
**Network:** Ethereum Mainnet / Testnets

## Audit Scope

### In-Scope Contracts

The following smart contracts are included in the audit scope:

#### Core Protocol Contracts

1. **Zapper.sol** - Main entry point for user interactions and investment processing

    - **File:** `contracts/Zapper.sol`
    - **Lines of Code:** ~1,314 lines
    - **Key Functions:** Deposit management, approval system, token swapping, redemption, asynchronous redemption system
    - **Criticality:** HIGHEST

2. **xCUP.sol** - ERC-4626 compliant vault for copper investments

    - **File:** `contracts/xCUP.sol`
    - **Lines of Code:** ~627 lines
    - **Key Functions:** Vault operations, share management, controlled redemption, price calculations, Uniswap integration
    - **Criticality:** HIGHEST

3. **CUPToken.sol** - ERC-20 token representing copper-backed value

    - **File:** `contracts/CUPToken.sol`
    - **Lines of Code:** ~233 lines
    - **Key Functions:** Token minting, burning, access control
    - **Criticality:** HIGH

4. **SettlementEngine.sol** - Revenue settlement and NAV management

    - **File:** `contracts/SettlementEngine.sol`
    - **Lines of Code:** ~803 lines
    - **Key Functions:** Revenue recording, NAV calculations, profit distribution, CUP token minting to vault
    - **Criticality:** HIGH

5. **EpochManager.sol** - Time-based epoch management

    - **File:** `contracts/EpochManager.sol`
    - **Lines of Code:** ~225 lines
    - **Key Functions:** Epoch progression, time windows, role-based epoch management
    - **Criticality:** MEDIUM

6. **CopperPriceConsumer.sol** - Chainlink oracle integration

    - **File:** `contracts/CopperPriceConsumer.sol`
    - **Lines of Code:** ~240 lines
    - **Key Functions:** Price fetching, oracle management, configuration updates
    - **Criticality:** HIGH

7. **HostAdapter.sol** - External system integration

    - **File:** `contracts/HostAdapter.sol`
    - **Lines of Code:** ~349 lines
    - **Key Functions:** External deposit registration, beneficiary management, price snapshot approvals
    - **Criticality:** MEDIUM

8. **Silo.sol** - USDC storage contract
    - **File:** `contracts/Silo.sol`
    - **Lines of Code:** ~29 lines
    - **Key Functions:** USDC storage and management, unlimited approval to Zapper
    - **Criticality:** MEDIUM

#### Interface Contracts

-   `contracts/interfaces/ICopperPriceConsumer.sol`
-   `contracts/interfaces/IEpochManager.sol`
-   `contracts/interfaces/IERC20Mintable.sol`
-   `contracts/interfaces/IxCUP.sol`

#### Library Contracts

-   `contracts/libraries/RedeemLib.sol` - Asynchronous redemption system library

### Out-of-Scope

-   Mock contracts in `contracts/mock/`
-   Test contracts in `test/`
-   Deployment scripts in `scripts/`
-   Documentation files in `docs/`
-   External dependencies (OpenZeppelin, Chainlink, Uniswap)

## Technical Architecture

### System Overview

The Alcum Protocol consists of several interconnected smart contracts that manage the complete lifecycle of copper-backed investments:

```
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
└─────────────────┴─────────────────┴─────────────────┴─────────────────────┘
         │                 │                 │                 │
         ▼                 ▼                 ▼                 ▼
┌─────────────────────────────────────────────────────────────────────────────┐
│                          ASSET LAYER                                       │
├─────────────────┬─────────────────┬─────────────────┬─────────────────────┤
│   CUP Token     │   USDC/Stables  │  External Tokens│   Copper Inventory  │
│  (Copper Rep.)  │   (Base Currency)│  (ETH, BTC, etc)│   (Physical Assets) │
└─────────────────┴─────────────────┴─────────────────┴─────────────────────┘
```

## Testing Information

### Test Coverage

The protocol includes comprehensive test suites with the following coverage:

-   **Total Test Files:** 8
-   **Total Test Cases:** 307
-   **Test Framework:** Foundry
-   **All Tests Passing:** ✅ 307/307

### Test Breakdown by Contract

| Contract            | Test File                        | Test Cases | Status  |
| ------------------- | -------------------------------- | ---------- | ------- |
| Zapper              | `test/Zapper.t.sol`              | 116        | ✅ PASS |
| SettlementEngine    | `test/SettlementEngine.t.sol`    | 61         | ✅ PASS |
| xCUP                | `test/xCUP.t.sol`                | 36         | ✅ PASS |
| CopperPriceConsumer | `test/CopperPriceConsumer.t.sol` | 27         | ✅ PASS |
| EpochManager        | `test/EpochManager.t.sol`        | 30         | ✅ PASS |
| CUPToken            | `test/CUPToken.t.sol`            | 19         | ✅ PASS |
| HostAdapter         | `test/HostAdapter.t.sol`         | 17         | ✅ PASS |
| SimpleTest          | `test/SimpleTest.t.sol`          | 1          | ✅ PASS |

## Dependencies

### External Dependencies

-   **OpenZeppelin Contracts v5.0.2**: Access control, security patterns
-   **Chainlink Contracts v1.3.0**: Oracle integration
-   **Uniswap V2**: DEX integration for token swaps
-   **Foundry**: Testing framework

### Solidity Version

-   **Compiler Version:** 0.8.24
-   **Optimization:** Enabled
-   **Runs:** 200

## Deployment Information

### Contract Deployment Order

1. CUP Token
2. Copper Price Consumer
3. xCUP Vault
4. Epoch Manager
5. Settlement Engine
6. Silo
7. Zapper
8. Host Adapter

## Recommendations for Auditors

1. **Focus on Zapper Contract**: This is the most complex and critical contract with multiple redemption systems
2. **Review Reentrancy Protection**: Verify all external calls are properly protected, especially in redemption functions
3. **Test Edge Cases**: Pay special attention to boundary conditions and edge cases in deposit/redemption flows
4. **Verify Access Control**: Ensure role-based permissions are correctly implemented across all contracts
5. **Check Price Manipulation**: Review oracle integration and price snapshot mechanisms for potential manipulation vectors
6. **Analyze Gas Usage**: Verify gas costs are reasonable, especially for batch operations and redemption flows
7. **Review Upgrade Safety**: Verify upgradeable patterns and storage layout compatibility
8. **Test Asynchronous Systems**: Thoroughly test the asynchronous redemption system and its interaction with direct redemption
9. **Validate Commission Logic**: Ensure commission calculations are correct and cannot be manipulated
10. **Check Deposit ID Generation**: Verify nonce-based deposit ID generation prevents front-running attacks

## Contact Information

For questions or clarifications during the audit process:

-   **Technical Documentation**: See `docs/` directory
-   **Architecture Details**: `docs/Technical_Architecture.md`
-   **Developer Guide**: `docs/Developer_Quick_Reference.md`
-   **Settlement Engine Guide**: `docs/SettlementEngine_Guide.md`

## Conclusion

The Alcum Protocol represents a sophisticated DeFi platform with complex interactions between multiple smart contracts. The audit should focus on the security of user funds, proper access control implementation, and the integrity of the copper-backed asset system. Special attention should be paid to the Zapper contract as the main entry point with dual redemption systems, the xCUP vault as the primary fund management contract, and the SettlementEngine for revenue distribution mechanisms.

The protocol has undergone extensive testing with 307 test cases covering all major functionality. The system includes both direct and asynchronous redemption mechanisms, comprehensive role-based access control, and sophisticated price management systems that require thorough security review.

---

**Document Version:** 1.0  
**Last Updated:** [Current Date]  
**Prepared For:** Security Audit  
**Classification:** Confidential
