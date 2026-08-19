# Alcum v2 — Trust Model

**Product:** Alcum OpenRWA Protocol v2  
**Audience:** security auditors, protocol ops, issuers  
**Scope:** the nine contracts in [v2_Contract_Reference.md](./v2_Contract_Reference.md)  

This document states **who is trusted, for what, and what the contracts enforce on-chain**. It describes the protocol's intentional permissioning model — not a list of open defects.

**Conflict rule:** Solidity wins. If this file disagrees with code, the code is the model.

---

## 1. One-line summary

v2 is a **permissioned RWA settlement layer with a permissionless user surface**.

- Users can deposit and request redemptions without a whitelist.
- **Pricing, inventory, epoch PnL, yield deployment, and minting of the RWA token are trusted operator actions**, constrained by roles, pause switches, and a few hard on-chain caps (redeem payout ≤ oracle NAV, recall must actually return tokens, epoch must have ended before settle).
- The protocol does **not** attempt to be an ungoverned AMM or an over-collateralised lending market. Off-chain custody of the real-world asset is part of the product model.

---

## 2. Trust domains

```
┌─────────────────────────────────────────────────────────────────┐
│  PROTOCOL DOMAIN (shared singletons)                            │
│  owner of Registry, Factory, Router, SharedSettlementEngine     │
│  Trusted for: upgrades of shared code, global pause,            │
│  fee config, rescue of stray tokens, super-curator /            │
│  super-revenue roles, factory implementation pointers           │
└──────────────────────────────┬──────────────────────────────────┘
                               │ does not own per-vault proxies
┌──────────────────────────────▼──────────────────────────────────┐
│  ISSUER DOMAIN (per vault after createVault)                    │
│  owner of RWAVault, CapitalFacility, EpochManager               │
│  Trusted for: vault upgrade, facility whitelist, pause vault,   │
│  grant/revoke facility & epoch roles, RWA token minter grants   │
└──────────────────────────────┬──────────────────────────────────┘
                               │ vaultOperator[vaultId] (optional)
┌──────────────────────────────▼──────────────────────────────────┐
│  OPERATOR DOMAIN (hot wallet or issuer multisig)                │
│  curator + host + revenue for that vaultId; optionally          │
│  FACILITY_OPERATOR_ROLE and EPOCH_MANAGER_ROLE                  │
│  Trusted for: policy price, redeem amount (≤ cap), external     │
│  deposit registration, epoch numbers, NAV report, yield deploy  │
└──────────────────────────────┬──────────────────────────────────┘
                               │
┌──────────────────────────────▼──────────────────────────────────┐
│  UNTRUSTED                                                      │
│  End users, keepers who call claim*, Uniswap traders,           │
│  anyone calling permissionless createVault (spam / fake vaults) │
└─────────────────────────────────────────────────────────────────┘
```

**Isolation rule:** operator of vault A must not be able to move funds of vault B. Shared contracts enforce this by keying every mutation on `vaultId` and checking `vaultOperator[vaultId]` (or a global role). Shared **code** compromise (router upgrade) breaks isolation — that sits in the protocol domain.

---

## 3. Actors and recommended key setup

| Actor | Typical key | Capabilities if key is misused | Recommended custody |
|---|---|---|---|
| **Protocol owner** | `Ownable.owner()` on Registry / Factory / Router / Settlement | Upgrade shared implementation; pause all user flows; set fee to 100%; rescue ERC-20 on router/settlement (except vault shares); rotate global roles; point factory at new implementation pointers for *future* vaults | Timelock + 3-of-5 (or stricter) protocol multisig. **Never a hot wallet.** |
| **Protocol `DEFAULT_ADMIN_ROLE`** | Same contracts, AccessControl | Grant/revoke `VAULT_CURATOR_ROLE`, `REVENUE_MANAGER_ROLE`, `FACTORY_ROLE`, `VAULT_FACTORY_ROLE`, `GOVERNOR_ROLE` | Same address as protocol owner unless split-admin is deliberate |
| **Governor / timelock** | `GOVERNOR_ROLE` on Registry | Soft-pause a vault; rotate oracle, epoch manager, treasury | On-chain governor timelock |
| **Issuer owner** | `Ownable` + admin on that vault’s RWAVault / Facility / EpochManager | Upgrade *that* vault; whitelist a yield protocol; pause *that* vault; grant facility/epoch roles | Issuer multisig. Separate from the operator hot wallet |
| **Vault operator** | `vaultOperator[vaultId]` | Approve/decline deposits and redeems; register external deposits; record/settle/distribute epoch revenue; `updateNAV` | Production: **split**. If one EOA holds all of this plus facility + epoch roles, it is a full-stack hot wallet for that vault |
| **Facility operator** | `FACILITY_OPERATOR_ROLE` | `deployCapital` (transfer + calldata) and recall | Multisig. Not the same EOA as curator if yield is enabled |
| **Epoch manager role** | `EPOCH_MANAGER_ROLE` | `nextEpoch`, `setEpochDuration` (next epoch only) | Can be the operator, but duration changes should be rare and dual-controlled |
| **Host integrator** | `HOST_INTEGRATION_ROLE` or operator | Register external deposits (no tokens move until claim, which pulls from facility) | Backend with monitoring; cannot drain facility by decline (external decline is a no-op transfer) |
| **User / keeper** | none | Zap, request redeem, claim approved tickets | Untrusted |
| **RWA token admin** | minter on `assetToken` | Mint unlimited underlying into router/settlement/vault if they also grant themselves minter | Issuer-controlled; must grant minter **only** to Router and Settlement |
| **Oracle operator** | `IAssetOracle` | Skew redeem cap, view quotes, and (if `averageBuyPrice` is 0) distribution mint | Independent feed; heartbeat and deviation alerts off-chain |
| **Uniswap V2 pool** | public market | Spot swap within user `slippageBps` | User-chosen slippage; router hard cap 10% |
| **Whitelisted yield protocol** | `deployCapital` target | Hold idle USDC; return it on recall | Due diligence + owner-only whitelist |

`Ownable.owner()` and `DEFAULT_ADMIN_ROLE` **can diverge**. After `transferOwnership` without transferring admin, two different keys control the same proxy. **Keep them identical** unless a written split-admin runbook exists.

---

## 4. What the contracts enforce (code is the source of truth)

These are **hard** on-chain properties enforced by the implementation:

| # | Property | Where |
|---|---|---|
| C1 | Users cannot `withdraw`/`redeem` vault underlying unless `REDEEMER_ROLE` | `RWAVault` |
| C2 | Router cannot pull more idle USDC than the facility holds | ERC-20 balance + `approveRedeem` idle check |
| C3 | Queued redeem payout cannot exceed oracle-implied NAV of locked shares | `RedeemPayoutTooHigh` |
| C4 | External deposit decline does not move facility USDC | `declineDeposit` |
| C5 | `recallCapital` does not reduce `_deployed` unless idle balance increased by the recalled amount | `RecallFailed` |
| C6 | `settleEpochRevenue` requires epoch ended and `epochId == currentEpochId` | `EpochNotFinished`, `EpochIdMismatch` |
| C7 | Settled epoch revenue cannot be overwritten; distributed revenue cannot be paid twice | `isSettled`, `netRevenue = 0` |
| C8 | If vesting is configured, unlocked `claimDeposit` is blocked | `VestingRequired` |
| C9 | Factory does not retain facility/epoch operator roles after `createVault` | `_relinquishFactoryRoles` |
| C10 | `rescueTokens` on router/settlement cannot take registered vault share tokens | `CannotRescueVaultShares` |
| C11 | `reportedInventoryOnly` requires an EpochManager | factory + registry |
| C12 | Vaults are isolated by `vaultId` mappings; operator of A is not curator of B unless they also hold the global role | Router / Settlement |
| C13 | Epoch 0 starts at `block.timestamp` with a fixed `_epochEnd`; `setEpochDuration` does not move the current end | `EpochManager` |
| C14 | Empty-vault ERC-4626 conversion uses a virtual offset ≥ 3 | `RWAVault._decimalsOffset` |

---

## 5. Operator-controlled parameters

These flows are **curator / operator policy**, enforced by role — not by an on-chain oracle or automated valuation module.

### 5.1 Policy price on deposit

`approveDeposit` / `approveExternalDeposit` take `assetPrice` from the **curator**, not from `IAssetOracle.price()`.

- Curator-chosen `assetPrice` determines how many shares are minted for the USDC sent to treasury on claim (warehouse quote, NAV, or other issuer policy).

Oracle is used for decimals, redeem cap, views, and (fallback) distribution mint — not for deposit approval.

### 5.2 Redeem amount inside the cap

Curator picks `tokenAmount` **≤** oracle NAV. They may pay **less** than the oracle cap (haircut, fees, illiquidity). They cannot pay more than the cap enforced by `RedeemPayoutTooHigh`.

### 5.3 External deposits and facility funding

`registerExternalDeposit` does not pull USDC. Claim **does** pull `approvedAmount` from CapitalFacility to treasury. Ops must have funded the facility to match the fiat wire. If they over-approve relative to actual cash, they spend **issuer/facility** USDC, not other vaults’ shares.

### 5.4 Epoch PnL and mint

`netRevenue`, `averageBuyPrice`, inventory (when `reportedInventoryOnly`) are operator-reported.

- Mint size = `netAfterFee * 10**dec / mintPrice` with `mintPrice = averageBuyPrice` (else live oracle).
- `netRevenue` and `averageBuyPrice` drive mint size; USDC for distribution is transferred from the revenue manager’s wallet at `distributeRevenueToVault` time.

`getNAVSummary` is a **report**. It is not `convertToAssets`. Queued redeem payouts use the oracle cap in `approveRedeem`, not `getNAVSummary`.

### 5.5 Direct ERC-4626 deposit

Anyone holding `assetToken` can `RWAVault.deposit` / `mint` without the router queue. Withdrawals still require `REDEEMER_ROLE`. Issuers gate access at the RWA token layer when required.

### 5.6 Permissionless `createVault`

Any address may register a vault with its chosen oracle and asset token. On-chain isolation by `vaultId` is preserved. Frontends and indexers allowlist the `vaultId` values they support.

### 5.7 Yield deployment

`deployCapital` sends idle USDC to a whitelisted target and may `call` calldata (≤ 4096 bytes). Only `FACILITY_OPERATOR_ROLE` may invoke it. Recall accounting requires a matching increase in `idleBalance()`; `totalBalance()` is an accounting sum, while `idleBalance()` reflects tokens in the contract.

### 5.8 Uniswap zap

Quotes and swaps execute in one transaction with user-configured `slippageBps` (router max 10%). Deadline is `block.timestamp`. This is standard Uniswap V2 behaviour, not an on-chain oracle module.

### 5.9 Unlimited router allowance

Each CapitalFacility grants the shared OpenLiquidityRouter unlimited allowance so approved redemptions can pull idle USDC without a per-tx approve. Rotating the router address is `onlyOwner` on the facility.

### 5.10 RWA minter

Documented mint paths: Router (`claimDeposit`) and Settlement (`distributeRevenueToVault`). Issuer runbooks should list all `assetToken` minter holders.

---

## 6. Key custody impact matrix

| Key | Capabilities if misused | Out of scope for that key |
|---|---|---|
| Random user | Zap with user slippage; add pending queue entries (gas cost) | Pull facility, mint RWA, redeem underlying, settle epochs |
| Vault operator (curator+host+revenue) | Policy-price deposits; underpay redeems (within cap); fake epoch PnL + mint if they fund USDC; register bogus external deposits that later drain **facility they control** | Touch another `vaultId`; upgrade shared router; bypass redeem cap; silent-recall fake idle |
| Facility operator | Send idle to a whitelisted (or newly whitelisted, if they are also owner) protocol via calldata | Change whitelist unless they are also issuer owner |
| Issuer owner | Upgrade that vault/facility; whitelist yield protocols; pause that vault; grant local roles on that stack | Upgrade shared Router/Settlement; pause all vaults; change protocol fee |
| Protocol owner | Upgrade router → drain all idle facilities; 100% fee; global pause; grant themselves curator on all vaults | Instantly seize RWA sitting in a vault **without** redeem role on that vault — unless they also upgrade RWAVault impl *and* the issuer has already transferred that upgrade key, which they have not |
| Oracle | Raise redeem cap (operator still has to approve); distort views; if buy price unused, distort mint | Directly transfer USDC |
| Yield protocol | Keep or lose deployed USDC | Access USDC that was never deployed (`idleBalance`) |
| Uniswap pool | Extract slippage from zapper | Take facility idle or vault shares |

---

## 7. Pause and freeze map

| Switch | Who | What stops | What still works |
|---|---|---|---|
| Router `pause` | Protocol owner | All zap / approve / claim / queued redeem on **all** vaults | Direct `RWAVault.deposit`; RFQ (out of this scope); already-held shares |
| Settlement `pause` | Protocol owner | Record / settle / distribute | Deposits if router unpaused |
| Registry `active = false` | Owner / governor | New zap, register external, requestRedeem, approve, **and claim** for that vault (`_activeVault` / `_requireActiveVault`) | Other vaults; RFQ if it checks `active` separately |
| RWAVault `pause` | Issuer | `deposit`/`mint`/`withdraw`/`redeem` on that vault | Facility, router queues (claim will fail at ERC-4626) |
| EpochManager `pause` | Issuer | `nextEpoch`, `setEpochDuration` | Router still gates on `timeLeftInEpoch()` |
| Epoch ended (`timeLeftInEpoch()==0`) | time | Deposit approve/claim | Queued redeem request/claim/decline; settle+distribute |

Ops expectation: protocol pause is the incident response for a shared-router incident. Issuer pause is the incident response for a single-asset vault.

---

## 8. Assets in custody vs assets in accounting

| Location | What it is | Who can take it | Trusted number? |
|---|---|---|---|
| CapitalFacility `idleBalance` | Real ERC-20 | Router (allowance), facility operator (deploy), issuer (upgrade) | **Yes** |
| CapitalFacility `_deployed` | Accounting | Reduced only after successful pull or `acknowledge` with idle ≥ amount | **No** — tracks deployed amounts, not guaranteed recoverability |
| RWAVault `totalAssets` | Real `assetToken` in the vault | `REDEEMER_ROLE` redeem; minter can add more | **Yes** for on-chain inventory |
| Off-chain warehouse | Physical / legal RWA | Custodian | **No** on-chain. `reportedInventoryOnly` exists exactly because of this |
| Router `_redeems` shares | User shares locked for queued redeem | User on decline/claim; protocol owner **cannot** rescue that share token | **Yes** |
| Settlement contract USDC mid-`distribute` | Transient | Owner rescue of *non-share* tokens if a tx is stuck | Treat as ops-trusted |

---

## 9. Dependencies trusted as-is

| Dependency | Trust |
|---|---|
| OpenZeppelin 5.0.2 UUPS / AccessControl / ERC4626 / SafeERC20 | Standard library; UUPS `_authorizeUpgrade` is `onlyOwner` |
| Uniswap V2 router + pools | Spot market; manipulable in-block |
| `IAssetOracle` implementation | Whatever the issuer/protocol set (Chainlink, custom, etc.). No on-chain heartbeat in these nine contracts |
| `ITokenVesting` | Router trusts it to lock shares; creator role on vesting is a separate grant |
| `IFeeDistributor` | Full fee amount is approved to it; distributor receives the fee slice per its implementation |
| Settlement token (USDC) | Assumed non-rebasing, 6 decimals, standard ERC-20. Fee-on-transfer not supported |
| RWA `assetToken` | Assumed mintable by router/settlement, standard ERC-20, decimals compatible with vault offset logic |

---

## 10. Explicit non-goals

The protocol **does not** provide:

- Trustless on-chain valuation of the physical RWA
- Automatic liquidation if warehouse inventory is fake
- MEV-free swaps
- A guarantee that `totalBalance()` of the facility is recoverable
- A curated registry of “official” vaults
- Separation of curator / host / revenue unless the issuer configures separate keys
- Timelock on issuer-side upgrades (issuer may add one themselves)

---

## 11. Pre-mainnet operational checklist

Print this page, fill the right column, attach to the deployment package.

| Item | Required answer |
|---|---|
| Protocol owner address and signers | Multisig / timelock, not EOA |
| Owner == `DEFAULT_ADMIN_ROLE` on shared contracts? | Yes / documented split |
| Global `VAULT_CURATOR_ROLE` and `REVENUE_MANAGER_ROLE` holders | Named; ideally same as protocol ops multisig, not a laptop |
| Per-vault operator vs issuer owner | Split: issuer multisig owns proxies; operator is a restricted backend |
| `FACILITY_OPERATOR_ROLE` | Multisig; yield whitelist empty until DD is done |
| RWA minter set | Router + Settlement only (+ documented break-glass) |
| Oracle | Feed address, heartbeat, who can change it (registry governor) |
| `createVault` | Permissionless on-chain; frontend/indexer allowlist documented |
| Direct `RWAVault.deposit` | RWA token access control documented; direct deposit policy defined |
| Fee `systemFeeBps` and `feeDistributor` | Values set; distributor address verified or `address(0)` |
| Pause runbook | Who calls router pause within X minutes |
| Upgrade runbook | Timelock delay on protocol UUPS documented |

---

## 12. Related documents

- Per-contract ABI and flows: [v2_Contract_Reference.md](./v2_Contract_Reference.md)

