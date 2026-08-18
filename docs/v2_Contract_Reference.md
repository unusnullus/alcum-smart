# Alcum v2 — Contract Reference

**Product:** Alcum OpenRWA Protocol v2  
**Document type:** Per-contract technical reference (architecture, ABI, money flows, invariants, trust model)  
**Source of truth:** Solidity under `contracts/v2/` and the two shared files listed below. Code wins on conflicts.  

Related: [v2_Trust_Model.md](./v2_Trust_Model.md) · [v2-protocol.md](./v2-protocol.md)

---

## 0. Scope

This document describes **only** the following contracts:

| File | Role |
|---|---|
| `contracts/v2/VaultRegistry.sol` | Authoritative directory of vaults |
| `contracts/v2/VaultFactory.sol` | Atomic deploy + register + role wiring |
| `contracts/v2/RWAVault.sol` | ERC-4626 share vault for any tokenised RWA |
| `contracts/v2/CapitalFacility.sol` | Per-vault settlement-token liquidity buffer |
| `contracts/v2/OpenLiquidityRouter.sol` | Shared deposit + queued-redeem entry point |
| `contracts/v2/SharedSettlementEngine.sol` | Epoch revenue, fees, NAV, asset mint into vault |
| `contracts/v2/libraries/VaultLib.sol` | Shared structs and queue helpers |
| `contracts/EpochManager.sol` | Per-vault time-boxed epoch clock |
| `contracts/libraries/SwapLib.sol` | Uniswap V2 zap helper used by the router |

**Precision conventions used everywhere:**

| Quantity | Decimals |
|---|---|
| Settlement token (USDC / USDT) | 6 |
| Vault shares (`RWAVault.decimals()`) | 6 |
| Oracle price (`IAssetOracle`) | 8 (Chainlink USD style: `$4.50` → `450_000_000`) |
| System fee | basis points, denominator `10_000` |
| Swap slippage | basis points, router cap `1_000` (10%) |

---

## 1. Architecture

v2 is two layers:

1. **Shared protocol layer** (singletons, protocol-owned): `VaultRegistry`, `VaultFactory`, `OpenLiquidityRouter`, `SharedSettlementEngine`. Callers pass a `vaultId`; shared contracts resolve addresses from the registry.
2. **Per-vault stack** (issuer-owned after `createVault`): `RWAVault` + `CapitalFacility` + optional `EpochManager`.

```
Actors: users · issuers · vault operators · protocol admin
                    │
                    ▼
┌─────────────────────────────────────────────────────────────┐
│ SHARED                                                       │
│  VaultRegistry          VaultFactory                         │
│  OpenLiquidityRouter    SharedSettlementEngine               │
│  SwapLib (library)      VaultLib (library)                   │
└──────────────────────────┬──────────────────────────────────┘
                           │ vaultId → VaultRecord
         ┌─────────────────┼─────────────────┐
         ▼                 ▼                 ▼
   Vault A stack     Vault B stack     Vault N …
   RWAVault          RWAVault          …
   CapitalFacility   CapitalFacility
   EpochManager?     EpochManager?
```

Users never need implementation addresses for the main flows: they pass `vaultId`.

### 1.1 Ownership after `createVault`

| Contract | Owner / `DEFAULT_ADMIN_ROLE` |
|---|---|
| Registry, Factory, Router, Settlement | Protocol admin (factory `initialize` caller / protocol multisig) |
| New `RWAVault`, `CapitalFacility`, `EpochManager` | **Issuer** (`msg.sender` of `createVault`) |

`Ownable.owner()` and `DEFAULT_ADMIN_ROLE` can diverge after later grants. Keep them on the same address unless a split-admin setup is intentional.

### 1.2 What factory does **not** do (issuer checklist)

1. Grant `MINTER_ROLE` (or equivalent mint rights) on the RWA token to **OpenLiquidityRouter** and **SharedSettlementEngine**. Without this, `claimDeposit` and `distributeRevenueToVault` revert.
2. Call `nextEpoch()` — not required for epoch 0 (it starts at `block.timestamp`). Operator still advances epochs after each close.
3. Seed `CapitalFacility` with settlement tokens.

---

## 2. VaultLib — shared data

**File:** `contracts/v2/libraries/VaultLib.sol`  
**Kind:** `library` (no state, no upgrade). Used by Registry, Router, Settlement.

### 2.1 `VaultRecord`

Stored in `VaultRegistry`. Read by Router and Settlement on every mutating flow.

| Field | Meaning |
|---|---|
| `vault` | `RWAVault` proxy |
| `assetToken` | Underlying RWA ERC-20 (must be mintable by router + settlement) |
| `settlementToken` | Deposit / redeem / fee currency (typically USDC) |
| `capitalFacility` | Per-vault USDC buffer |
| `rfqEngine` | Shared RFQ address copied into the record (not used by the nine contracts except as metadata) |
| `assetOracle` | `IAssetOracle` (8-decimal price) |
| `uniswapRouter` | Uniswap V2 router for zap + view quotes |
| `epochManager` | Per-vault clock, or `address(0)` for epoch-less vaults |
| `active` | Soft pause. `false` blocks new deposits / queued redeems at the router |
| `treasury` | Custodian. Receives USDC on deposit claim; receives redeemed RWA on queued redeem; fee fallback |
| `reportedInventoryOnly` | If `true` (requires epochs), NAV warehouse inventory is operator-reported, never `vault.balanceOf` |

### 2.2 `Deposit` (stored in OpenLiquidityRouter)

| Field | Meaning |
|---|---|
| `user` | Zap depositor, or host integrator for external deposits |
| `depositId` | Unique id (caller-supplied for zap; keccak-derived for external) |
| `amount` | Settlement tokens recorded at creation |
| `approvedAmount` | Curator-approved amount (`≤ amount`) |
| `approvedAssetAmount` | `approvedAmount * 10**oracleDecimals / assetPrice` |
| `priceSnapshot` | Oracle price locked at approval (8 dec) |
| `beneficiary` | Share recipient; `address(0)` → `user` |
| `createdBy` / `claimedBy` | Audit trail. Non-zero `claimedBy` = claimed |
| `approved` / `isExternal` / `tag` | State + off-chain correlation tag |

**Index rule:** zap deposits are listed in `userDeposits[user]`. External deposits are listed under `beneficiary`. Claim / decline **must** remove from the same key.

### 2.3 `RedeemRequest`

| Field | Meaning |
|---|---|
| `user` | Share owner; only they can `claimRedeem` |
| `shares` | Locked in the router until claim or decline |
| `tokenAmount` | Curator-approved settlement payout |
| `approved` / `claimed` | State machine |

Duplicate `redeemId` reverts with `RedeemAlreadyExists`.

### 2.4 Helpers

- `recordDeposit` / `recordExternalDeposit` / `approveDeposit` / `approveExternalDeposit`
- `recordRedeemRequest`
- `removeFromArray` / `removeUserEntry` — O(n) swap-and-pop. Fine for curator-sized queues; a griefing depositor can inflate gas for later curator calls.

**External deposit id:**

```
keccak256(abi.encodePacked(createdBy, block.timestamp, tokenAmount, beneficiary, tag, nonce))
```

Collision loop: increment `nonce` up to 100 times, then revert `DepositAlreadyExists`.

---

## 3. VaultRegistry

**File:** `contracts/v2/VaultRegistry.sol`  
**Kind:** UUPS proxy · `Ownable` + `AccessControl`  
**Initialize:** `initialize(admin_)` — `admin_` becomes owner and `DEFAULT_ADMIN_ROLE`. `nextVaultId = 1`.

### 3.1 Why it exists

Shared contracts must not hardcode per-vault addresses. The registry is the single on-chain phone book and the governance surface for soft-pausing a vault and rotating oracle / treasury / epoch manager without redeploying the stack.

### 3.2 Roles

| Role | Who | Can |
|---|---|---|
| `FACTORY_ROLE` | `VaultFactory` | `registerVault` |
| `GOVERNOR_ROLE` | Timelock (via `grantGovernorRole`) or owner | `setVaultActive`, `setVaultOracle`, `setVaultEpochManager`, `setVaultTreasury` |
| `owner` | Protocol multisig | Same as governor + grant roles + UUPS upgrade |

### 3.3 Functions

| Function | Access | Behaviour |
|---|---|---|
| `registerVault(...)` | `FACTORY_ROLE` | Assigns sequential `vaultId`, stores `VaultRecord` with `active = true`. Reverts on zero addresses (except `epochManager`), duplicate vault address, or `reportedInventoryOnly && epochManager == 0`. |
| `setVaultActive(id, bool)` | owner / governor | Soft pause. Existing claims / RFQ fills are **not** blocked by the registry itself; consumers decide. |
| `setVaultOracle` / `setVaultEpochManager` / `setVaultTreasury` | owner / governor | Rotate references. New oracle must still implement `IAssetOracle` with 8 decimals (not checked on-chain). `setVaultEpochManager` does **not** allow `address(0)`. |
| `getVault(id)` | view | Full record. Reverts `VaultLib.VaultNotFound` if never registered. |
| `isActive(id)` | view | Returns `false` for unknown ids (default mapping) — **does not revert**. |
| `totalVaults()` | view | `nextVaultId - 1` |
| `vaultIdByAddress(vault)` | view | Reverse lookup. `0` = not found. |

### 3.4 Events

`VaultRegistered` · `VaultStatusChanged` · `VaultOracleUpdated` · `VaultEpochManagerUpdated` · `VaultTreasuryUpdated` · `GovernorGranted`

### 3.5 Invariants

- Vault ids start at **1**. Id `0` is reserved as “not found”.
- Same vault proxy cannot register twice.
- `reportedInventoryOnly` requires a non-zero `epochManager`.

---

## 4. VaultFactory

**File:** `contracts/v2/VaultFactory.sol`  
**Kind:** UUPS proxy · `Ownable`  
**Initialize:** stores registry + implementation addresses + shared Router / RFQ / Settlement. Caller becomes owner.

Factory **must** hold `FACTORY_ROLE` on the registry and `VAULT_FACTORY_ROLE` on Router and Settlement **before** the first `createVault`.

### 4.1 Why it exists

Hand-deploying an issuer stack is error-prone (forgotten `REDEEMER_ROLE`, forgotten facility allowance, forgotten registry row). Factory does deploy + register + wiring in **one transaction**.

### 4.2 `createVault` — ordered steps

`createVault` is **permissionless**. `msg.sender` becomes issuer-admin of the new stack. Shared protocol contracts are unaffected.

1. `_validate(p)` — non-zero `assetToken`, `settlementToken`, `assetOracle`, `uniswapRouter`, `wethToken`, `treasury`. If `useEpochs`, `epochDuration > 0`. If `reportedInventoryOnly`, `useEpochs` must be true.
2. If `useEpochs`: deploy `ERC1967Proxy(EpochManager_impl, initialize(duration))`.
3. Deploy `ERC1967Proxy(RWAVault_impl, initialize(asset, name, symbol, oracle, uni, settlement, weth))`.
4. Deploy `ERC1967Proxy(CapitalFacility_impl, initialize(settlement, router, factory))` — factory is temporary admin; facility `forceApprove`s the router `type(uint256).max`.
5. `registry.registerVault(...)` → sequential `vaultId`, `active = true`.
6. Grant `REDEEMER_ROLE` on the new vault to **OpenLiquidityRouter** and **RFQEngine**.
7. If `operator ≠ 0`: grant `FACILITY_OPERATOR_ROLE` and (if epochs) `EPOCH_MANAGER_ROLE`; call `setVaultOperator` on Router and Settlement.
8. `_relinquishFactoryRoles` — factory **revokes** its own `FACILITY_OPERATOR_ROLE` and `EPOCH_MANAGER_ROLE` so it cannot deploy/recall capital or advance epochs after hand-off.
9. Transfer `DEFAULT_ADMIN_ROLE` + `Ownable` of all three proxies to `msg.sender`; factory revokes its admin.
10. Emit `VaultCreated`.

### 4.3 `CreateVaultParams`

See source. Notable flags:

- `useEpochs = false` → `epochManager = address(0)`. Router treats the vault as always epoch-active. Settlement `settleEpochRevenue` reverts `NoEpochManager`.
- `operator = address(0)` → skip operator wiring; issuer grants roles later.
- `reportedInventoryOnly` → warehouse NAV is never taken from on-vault token balance.

### 4.4 Admin setters (owner)

`setOpenLiquidityRouter` · `setRFQEngine` · `setRWAVaultImplementation` · `setCapitalFacilityImplementation` · `setEpochManagerImplementation` · `setSharedSettlementEngine`

Changing implementations affects **future** `createVault` calls only. Already deployed vaults keep their proxy targets until the **issuer** upgrades them.

### 4.5 Registry policy

`createVault` is permissionless: any address may register a vault with its chosen oracle and asset token. Frontends and indexers should allowlist `vaultId` values they support. Vault isolation by `vaultId` is enforced on-chain regardless of registry contents.

---

## 5. RWAVault

**File:** `contracts/v2/RWAVault.sol`  
**Kind:** UUPS proxy · ERC-4626 + `Ownable` + `AccessControl` + `Pausable` + `ReentrancyGuard`  
**Initialize:** `initialize(assetToken, name, symbol, oracle, uniRouter, settlementToken, weth)`. Deployer (`VaultFactory`) gets `DEFAULT_ADMIN_ROLE` and ownership, then factory transfers both to the issuer.

### 5.1 Why it exists

LP ownership of a tokenised RWA as an ERC-4626 share token. **Deposits of underlying are open** (the router deposits on claim; anyone holding the asset token can also `deposit` / `mint` directly). **Withdraw / redeem of underlying are restricted to `REDEEMER_ROLE`** so KYC / settlement policy cannot be bypassed.

### 5.2 Roles and pause

| Role / gate | Effect |
|---|---|
| `REDEEMER_ROLE` | `withdraw` / `redeem`. Granted at create to Router and RFQEngine |
| `owner` | Pause, upgrade, set oracle / router / settlement / WETH / swap intermediary |
| `whenNotPaused` | Blocks `deposit`, `mint`, `withdraw`, `redeem` |

Direct ERC-4626 `deposit` / `mint` do not pass through the curator queue. Issuers typically gate access at the RWA token layer or pause direct deposits when the asset is unrestricted.

### 5.3 Share math

- `decimals()` is hardcoded to **6**.
- `_decimalsOffset()` returns `max(3, assetDecimals - shareDecimals)` when asset decimals exceed share decimals, otherwise **3**. Empty-vault conversion is `shares = assets * 10**offset`, not 1:1.

### 5.4 Price views (do not move funds)

- `getAssetPrice()` → `assetOracle.price()`.
- `getShareValueIn(quoteToken, shareAmount)` — oracle USD of underlying, then Uniswap if `quoteToken` is not the settlement token. `quoteToken = address(0)` → WETH.
- `getTokenToShareRate(inputToken, tokenAmount)` — inverse: token → settlement via Uniswap → asset via oracle → shares via ERC-4626.

Quote paths: direct 2-hop, then optional 3-hop via `swapIntermediary` (must be a token with liquid pairs to both legs). `NoLiquidPath` if neither works.

`setSwapIntermediary(address(0))` disables the 3-hop fallback.

### 5.5 Admin

`setAssetOracle` · `setUniswapRouter` · `setSettlementToken` · `setWethToken` · `setSwapIntermediary` · `pause` / `unpause`

Changing `settlementToken` does **not** migrate facility balances. Treat it as a pre-launch / emergency tool.

---

## 6. CapitalFacility

**File:** `contracts/v2/CapitalFacility.sol`  
**Kind:** UUPS proxy · `Ownable` + `AccessControl` + `ReentrancyGuard`  
**Initialize:** `initialize(token_, authorizedSpender_, admin_)`. Grants admin `DEFAULT_ADMIN_ROLE` + `FACILITY_OPERATOR_ROLE`. `forceApprove(authorizedSpender, max)`.

Typically `token_ = USDC`, `authorizedSpender_ = OpenLiquidityRouter`.

### 6.1 Why it exists

Per-vault idle settlement buffer. Redemption payouts are pulled by the router via unlimited allowance — no extra approve tx. Between settlements, an operator may deploy idle USDC into **whitelisted** DeFi protocols.

**Invariant:** redemption liquidity (`idleBalance`) always takes precedence over yield. Curator must recall before `approveRedeem` if funds are deployed.

### 6.2 Balances

| View | Meaning |
|---|---|
| `idleBalance()` | `token.balanceOf(this)` — actually sitting in the contract |
| `deployedIn(protocol)` | Internal accounting of amount sent to that protocol |
| `totalBalance()` | `idleBalance + totalDeployed` — accounting sum; use `idleBalance()` for redemption liquidity |

### 6.3 Deploy

`deployCapital(protocol, amount, data)` — `FACILITY_OPERATOR_ROLE`, `nonReentrant`.

1. Protocol must be whitelisted, `amount > 0`, `data.length ≤ 4096`.
2. `idleBalance ≥ amount`.
3. `safeTransfer(protocol, amount)`.
4. If `data` non-empty: `protocol.call(data)` — revert `DeploymentFailed` on failure.
5. Update `_deployed` / `totalDeployed` / `_activeProtocols`.

**Access control:** `deployCapital` requires `FACILITY_OPERATOR_ROLE` and a whitelisted protocol. Whitelist changes are `onlyOwner`. See [v2_Trust_Model.md](./v2_Trust_Model.md) for recommended key custody.

### 6.4 Recall (two paths)

**Pull path — `recallCapital(protocol, amount)`**

1. Reads idle balance.
2. Attempts `transferFrom(protocol, this, toRecall)`.
3. **Reverts `RecallFailed` unless idle balance increased by `toRecall`.**
4. Only then updates `_deployed` / `totalDeployed`.

Accounting updates only after idle balance increases by the recalled amount (`RecallFailed` otherwise).

**Push path — `acknowledgeCapitalRecall(protocol, amount)`**

Use when the protocol already sent tokens back (no `transferFrom` approval). Requires `idleBalance() ≥ amount` so redemption liquidity is actually present, then reduces `_deployed`.

`recallAll()` walks `_activeProtocols` and calls the pull path for each.

### 6.5 Spender rotation

`setAuthorizedSpender(new)` — `onlyOwner`. Resets old allowance to 0, sets new to `max`. The authorized spender may pull idle tokens up to the facility balance.

---

## 7. OpenLiquidityRouter

**File:** `contracts/v2/OpenLiquidityRouter.sol`  
**Kind:** UUPS proxy · `AccessControl` + `Ownable` + `Pausable` + `ReentrancyGuard`  
**Initialize:** `initialize(registry_, admin_)`. Admin gets `DEFAULT_ADMIN_ROLE` + `VAULT_CURATOR_ROLE`.

This is the **only user entry point** among the nine contracts for deposits and queued (T+n) redemptions. Instant T+0 exits go through `RFQEngine` (out of scope).

### 7.1 Roles

| Role / mapping | Who | Rights |
|---|---|---|
| `VAULT_CURATOR_ROLE` | Protocol super-curator | Approve / decline deposits and redeems for **all** vaults |
| `HOST_INTEGRATION_ROLE` | Protocol host integrator | `registerExternalDeposit` for all vaults |
| `VAULT_FACTORY_ROLE` | VaultFactory | `setVaultOperator` |
| `vaultOperator[vaultId]` | Issuer backend | Curator **and** host rights **only** for that `vaultId` |
| `owner` | Protocol multisig | Pause, upgrade, vesting config, registry, rescue, rotate operator |

`_checkCurator` / `_checkHostIntegration`: `msg.sender == vaultOperator[vaultId]` **OR** holds the global role.

### 7.2 Deposit path A — zap (on-chain)

```
user: zapAndDeposit(vaultId, tokenIn, amount, depositId, slippageBps)
  → if tokenIn == settlementToken: transferFrom user → CapitalFacility
  → else SwapLib.zapIn(..., swapIntermediary from RWAVault) → USDC to CapitalFacility
  → VaultLib.recordDeposit (pending, unapproved)

curator: approveDeposit(vaultId, depositId, approvedAmount, assetPrice)
  → requires active vault + epoch still running
  → approvedAssetAmount = approvedAmount * 10**oracleDec / assetPrice
  → removed from pending queue

user (or keeper): claimDeposit(vaultId, depositId)
  → blocked if vesting is configured for this vault (see 7.4)
  → pull approvedAmount USDC: Facility → treasury
  → mint approvedAssetAmount assetToken to router
  → ERC-4626 deposit into RWAVault, shares to beneficiary
```

`depositId` is **caller-supplied**. Reuse reverts `DepositAlreadyExists` — it does not steal another user’s funds.

`slippageBps` max **1000** (10%). Users set slippage per swap; lower values reduce execution variance on thin pools.

`zapAndDeposit` / `approveDeposit` / `claimDeposit` require the epoch to be running when the vault has an EpochManager (`timeLeftInEpoch() > 0`). After the epoch ends, curator must `nextEpoch()` before new approvals/claims.

### 7.3 Deposit path B — external (off-chain cash)

```
host: registerExternalDeposit(vaultId, beneficiary, tokenAmount, tag)
  → no tokens move
  → id derived from caller, timestamp, amount, beneficiary, tag, nonce

curator: approveExternalDeposit(...)  // same pricing as zap

claim: same as claimDeposit — Facility MUST already hold USDC
       (ops funds it to represent the fiat wire)
```

**Decline:** `declineDeposit` refunds zap deposits from the facility to `user`. **External deposits are cancelled with no token movement** (they never funded the facility). Refunding them would drain idle redemption liquidity to the host integrator.

### 7.4 Vesting

`setVaultVestingConfig(vaultId, vestingContract, defaultCliff, defaultDuration)` — owner.

When `vestingContract ≠ 0`:

- `claimDeposit` **reverts `VestingRequired`**. This prevents a third party from front-running `claimDepositWithVesting` and delivering unlocked shares.
- `claimDepositWithVesting(vaultId, depositId, cliff, duration)` deposits shares **into the vesting contract** and creates a linear schedule for the beneficiary. `cliff`/`duration` of `0` use vault defaults. Router must hold the vesting-creator role on that contract.

### 7.5 Queued redeem

```
user: requestRedeem(vaultId, shares, redeemId)
  → shares locked in the router

curator: approveRedeem(vaultId, redeemId, tokenAmount)
  → tokenAmount must be > 0
  → tokenAmount ≤ convertToAssets(shares) * oracle.price / 10**oracleDec
       else RedeemPayoutTooHigh
  → idle facility balance ≥ tokenAmount else InsufficientFacilityBalance

user: claimRedeem
  → burns shares; underlying RWA goes to vault treasury (custodian)
  → USDC pulled Facility → user

curator: declineRedeem → shares returned to user (only if not yet approved)
```

The facility is a **USDC** buffer. It must never receive the redeemed RWA token.

### 7.6 Epoch gate

`_checkEpochActive`: if `epochManager ≠ 0` and `timeLeftInEpoch() == 0` → `EpochNotActive`. Applies to approve/decline/claim deposit (not to `requestRedeem` / `claimRedeem` / `declineRedeem`, so users can still exit after epoch close).

### 7.7 Rescue

`rescueTokens(token, to, amount)` — owner. **Cannot** rescue a token whose address is a registered vault (`vaultIdByAddress ≠ 0`). That protects locked shares sitting in `_redeems`.

### 7.8 Pause

`pause` / `unpause` — owner. `whenNotPaused` on zap, approve, decline, claim, register, request/approve/claim/decline redeem.

---

## 8. SharedSettlementEngine

**File:** `contracts/v2/SharedSettlementEngine.sol`  
**Kind:** UUPS proxy · `Ownable` + `AccessControl` + `Pausable` + `ReentrancyGuard`  
**Initialize:** `initialize(registry_, systemFeeBps_, admin_)`. Admin gets `DEFAULT_ADMIN_ROLE` + `REVENUE_MANAGER_ROLE`. `systemFeeBps_ ≤ 10_000`.

### 8.1 Why it exists

One place to record off-chain epoch PnL, take a protocol fee, move net USDC into the vault’s facility, and mint equivalent RWA into the vault so **share price rises for all holders**.

### 8.2 Roles

| Who | Rights |
|---|---|
| `REVENUE_MANAGER_ROLE` | Record / settle / distribute / `updateNAV` for **all** vaults |
| `vaultOperator[vaultId]` | Same rights **only** for that vault |
| `VAULT_FACTORY_ROLE` | `setVaultOperator` |
| `owner` | Fee config, pause, upgrade, rescue |

### 8.3 Epoch revenue lifecycle

Must run **in order**. Cannot skip settle.

```
1. recordEpochRevenue(vaultId, epochId, netRevenue, assetBought, assetSold, averageBuyPrice, averageSellPrice)
     - no tokens move
     - epochId ≠ 0, netRevenue ≠ 0
     - if assetBought > 0, averageBuyPrice ≠ 0 (same for sold / sell price)
     - unsettled record for the same (vaultId, epochId) may be overwritten
     - settled records cannot be overwritten

2. settleEpochRevenue(vaultId, epochId)
     - vault must have an EpochManager
     - timeLeftInEpoch() must be 0 (epoch actually ended)
     - epochId must equal EpochManager.currentEpochId()
     - snapshots IERC4626(vault).totalSupply()
     - isSettled = true
     - NAV.retainedEarnings += netRevenue
     - does NOT call nextEpoch() — operator does that separately

3. distributeRevenueToVault(vaultId, epochId)
     - caller must have approved `netRevenue` of settlement token
     - pull USDC from caller
     - fee = netRevenue * systemFeeBps / 10_000
     - route fee (see 8.4)
     - send netAfterFee to CapitalFacility
     - mintPrice = averageBuyPrice if non-zero, else live oracle
     - assetToMint = netAfterFee * 10**oracleDec / mintPrice
     - mint assetToken into the RWAVault (raises totalAssets → share price)
     - default vaults: sync NAV.assetInInventory from vault.balanceOf
     - reportedInventoryOnly: leave inventory as last updateNAV
     - zero r.netRevenue so it cannot be distributed twice
```

Using **averageBuyPrice** (recorded at epoch close) instead of a live spot oracle prevents a temporarily depressed feed from minting a huge RWA balance into the vault.

### 8.4 Fee routing (priority)

1. If `feeDistributor ≠ 0`: `forceApprove` + `IFeeDistributor.distribute(token, fee)`.
2. Else if `feeRecipients[]` non-empty: split by bps (sum ≤ 10_000). Remainder → vault treasury.
3. Else: full fee → vault treasury.

`setFeeDistribution` / `setFeeDistributor` / `setSystemFee` — owner.

### 8.5 NAV

`NAVComponents` (operator-reported except inventory on default vaults):

| Field | Unit |
|---|---|
| `assetInInventory` | RWA token units |
| `assetSpotPrice` | 8 dec |
| `assetInTransit` | RWA token units |
| `retainedEarnings` | USDC 6 dec |
| `stablecoinBalance` | USDC 6 dec |
| `liabilities` | USDC 6 dec |

```
assetValue   = (inventory + inTransit) * spotPrice / 10**oracleDec
totalAssets  = assetValue + retainedEarnings + stablecoinBalance
netAssets    = max(totalAssets - liabilities, 0)
pricePerShare = supply == 0 ? 1e6 : netAssets * 1e6 / supply
```

`updateNAV` overwrites every field **except** `assetInInventory` on vaults that are **not** `reportedInventoryOnly` — those always sync from `vault.balanceOf`. `getNAVSummary` is a **reporting** number. It is **not** the ERC-4626 on-chain share price (`convertToAssets`).

### 8.6 Rescue

`rescueTokens` — owner. Cannot rescue registered vault share tokens.

---

## 9. EpochManager

**File:** `contracts/EpochManager.sol` (shared; one **proxy per vault**)  
**Kind:** UUPS proxy · `Ownable` + `AccessControl` + `Pausable`  
**Initialize:** `initialize(epochDuration_)` with `0 < duration ≤ 365 days`.

Starts **epoch 0 immediately**:

- `_epochStart = block.timestamp`
- `_epochEnd = block.timestamp + duration`

From deployment, `timeLeftInEpoch()` equals the configured duration until `_epochEnd` is reached.

### 9.1 Roles

| Role | Can |
|---|---|
| `EPOCH_MANAGER_ROLE` | `nextEpoch`, `setEpochDuration` |
| `owner` | Pause, UUPS upgrade |

Factory grants the vault `operator` this role (if provided), then **revokes it from itself**.

### 9.2 Clock

| View | Meaning |
|---|---|
| `currentEpochId()` | Starts at 0, increments on `nextEpoch` |
| `epochStart()` / `epochEnd()` | Fixed timestamps for the **current** epoch |
| `epochDuration()` | Duration that will be used when the **next** epoch starts |
| `timeLeftInEpoch()` | `0` if `block.timestamp ≥ epochEnd` |

`nextEpoch()` reverts `EpochNotFinished` if `block.timestamp < _epochEnd`. Then:

```
id++
start = now
end   = now + _epochDuration   // uses possibly updated duration
```

`setEpochDuration` **does not move `_epochEnd`**. Shortening duration cannot kill the current epoch. The new duration applies from the next `nextEpoch` only.

### 9.3 Typical close sequence (ops)

1. Wait until `timeLeftInEpoch() == 0`.
2. `recordEpochRevenue` (can happen slightly before close; settle cannot).
3. `settleEpochRevenue`.
4. `distributeRevenueToVault` (USDC from revenue manager wallet).
5. `nextEpoch()` — opens the next window so the router accepts deposits again.

---

## 10. SwapLib

**File:** `contracts/libraries/SwapLib.sol`  
**Kind:** `library` (external `zapIn` — linked, not inlined). Used by `OpenLiquidityRouter.zapAndDeposit`.

### 10.1 `zapIn`

Pulls `tokenIn` from `msgSender` into `routerCaller` (the router), swaps on Uniswap V2, sends output to `recipient` (CapitalFacility). Returns the **balance delta** of `settlementToken` on `recipient` (not the router’s quoted amount).

| Input | Behaviour |
|---|---|
| `tokenIn == address(0)` | Native ETH. `msgValue` must equal `amount`. Path starts at `router.WETH()`. Calls `swapExactETHForTokens`. |
| ERC-20 (including WETH) | `msgValue` must be 0 (`UnexpectedETH` otherwise). `safeTransferFrom` + `forceApprove` + `swapExactTokensForTokens`. |

WETH is swapped via `swapExactTokensForTokens` (`msgValue` must be 0). Native ETH uses `tokenIn == address(0)` and `swapExactETHForTokens`.

### 10.2 Path selection

Same as `RWAVault` quotes:

1. Direct `tokenIn → tokenOut`.
2. If `getAmountsOut` reverts and `swapIntermediary` is a distinct non-zero token: `tokenIn → intermediary → tokenOut`.
3. Else `NoLiquidPath`.

`minOut = quoted * (10_000 - slippageBps) / 10_000`. Deadline is `block.timestamp`. Slippage is caller-configured; the router rejects `slippageBps > 1_000` (10%).

The extra `swapIntermediary` argument is passed from `RWAVault(v.vault).swapIntermediary()` so execution matches the vault’s view quotes.

---

## 11. Money flows (summary)

### 11.1 Zap deposit → claim

```
User token/ETH ──swap──► USDC ──► CapitalFacility
                                      │
curator approve (locks price)         │
                                      ▼ claim
                         USDC Facility ──► treasury (custodian payment)
                         mint RWA ──► router ──deposit──► RWAVault
                         shares ──► beneficiary (or vesting contract)
```

### 11.2 Queued redeem

```
User shares ──lock──► Router
curator approve (capped by oracle NAV)
claim: burn shares, RWA ──► treasury
       USDC Facility ──► user
```

### 11.3 Epoch distribution

```
Revenue manager USDC ──► SettlementEngine
                    ├─ fee ──► distributor / recipients / treasury
                    └─ net ──► CapitalFacility
mint RWA ──► RWAVault  (share price ↑)
```

### 11.4 Yield deploy / recall

```
Facility idle USDC ──deployCapital──► whitelisted protocol
protocol ──recallCapital / acknowledgeCapitalRecall──► Facility idle
```

---

## 12. State machines

### 12.1 Deposit

```
(none)
  recordDeposit / recordExternalDeposit
pending, approved=false
  approve*  → approved=true, removed from pending
  decline   → deleted; zap refunds USDC; external is a no-op transfer
approved
  claimDeposit / claimDepositWithVesting → claimedBy set
```

Cannot approve twice. Cannot claim unapproved. Cannot decline after approve.

### 12.2 Redeem

```
requestRedeem → locked shares, approved=false
  approveRedeem → approved=true, tokenAmount set (oracle-capped)
  declineRedeem → shares returned (only if not approved)
approved
  claimRedeem → claimed=true, USDC out, RWA to treasury
```

### 12.3 Epoch revenue

```
(empty)
  record  → draft (overwritable)
  settle  → isSettled (requires epoch ended + matching currentEpochId)
  distribute → netRevenue = 0 (terminal)
```

### 12.4 Vault `active` flag

| `active` | Router zap / requestRedeem / registerExternal | Registry itself |
|---|---|---|
| `true` | Allowed (plus epoch / pause gates) | — |
| `false` | `VaultNotActive` | Does not freeze already-approved claims |

Router `pause` is a global kill switch for **all** vaults.

---

## 13. Role matrix (quick)

| Action | Who |
|---|---|
| `createVault` | Anyone (issuer becomes stack admin) |
| `registerVault` | Factory only |
| Soft-pause a vault | Registry owner / governor |
| Zap / requestRedeem / claim | User |
| Approve / decline deposit or redeem | Global curator **or** `vaultOperator[vaultId]` |
| Register external deposit | Global host **or** `vaultOperator[vaultId]` |
| Deploy / recall facility capital | `FACILITY_OPERATOR_ROLE` (issuer + optional operator) |
| Record / settle / distribute / updateNAV | Global revenue manager **or** `vaultOperator[vaultId]` |
| `nextEpoch` / `setEpochDuration` | `EPOCH_MANAGER_ROLE` on that vault’s EpochManager |
| Pause router / settlement | Protocol owner |
| Pause / upgrade a vault or facility | **Issuer** owner of that proxy |
| Rescue stray ERC-20 on router / settlement | Protocol owner, except vault share tokens |

---

## 14. Formulas

**Asset units from USDC at approval / mint:**

```
assetAmount = usdcAmount * 10**oracleDecimals / assetPrice
```

**Queued redeem cap:**

```
maxPayout = convertToAssets(shares) * oracle.price() / 10**oracleDecimals
require(tokenAmount <= maxPayout)
```

**Protocol fee:**

```
fee         = netRevenue * systemFeeBps / 10_000
netAfterFee = netRevenue - fee
```

**Distribution mint (prefers epoch average buy):**

```
mintPrice   = averageBuyPrice != 0 ? averageBuyPrice : oracle.price()
assetToMint = netAfterFee * 10**oracleDecimals / mintPrice
```

**Swap min-out:**

```
minOut = getAmountsOut(amountIn)[last] * (10_000 - slippageBps) / 10_000
```

**NAV report (off-chain consumers):**

```
assetValue    = (inventory + inTransit) * spot / 10**oracleDecimals
totalAssets   = assetValue + retainedEarnings + stablecoinBalance
netAssets     = totalAssets > liabilities ? totalAssets - liabilities : 0
pricePerShare = supply == 0 ? 1e6 : netAssets * 1e6 / supply
```

---

## 15. Upgradeability and storage

All stateful contracts in this set are **UUPS**. Implementations disable initializers in the constructor.

| Contract | Authorizes upgrade | Storage gap |
|---|---|---|
| VaultRegistry | `onlyOwner` | `[47]` |
| VaultFactory | `onlyOwner` | `[45]` |
| RWAVault | `onlyOwner` (issuer) | `[44]` |
| CapitalFacility | `onlyOwner` (issuer) | `[45]` |
| OpenLiquidityRouter | `onlyOwner` (protocol) | `[43]` |
| SharedSettlementEngine | `onlyOwner` (protocol) | `[43]` |
| EpochManager | `onlyOwner` (issuer) | `[44]` |

`VaultLib` / `SwapLib` are libraries — no proxy.

Unused public `treasury` slots on Router and Settlement are **retained** for layout compatibility; per-vault treasury lives in `VaultRecord`.

---

## 16. Trust model

Standalone document (roles, on-chain guarantees, operator-controlled parameters, key custody matrix, pause map, pre-mainnet checklist):

- [v2_Trust_Model.md](./v2_Trust_Model.md)
- [RU](./ru/v2_Trust_Model.md)

---

## 17. Interfaces these contracts consume

| Interface | Used for |
|---|---|
| `IAssetOracle` | `price()`, `decimals()` — 8-dec USD |
| `IEpochManager` | `currentEpochId()`, `nextEpoch()`, `timeLeftInEpoch()` |
| `ICapitalFacility` | idle/deploy/recall (router pulls via ERC-20 allowance, not this interface) |
| `ITokenVesting` | `createVestingSchedule` on vest-claim |
| `IFeeDistributor` | Optional fee routing |
| `IERC20Mintable` | `mint` on the RWA token |
| `IERC4626` | `deposit` / `redeem` / `totalSupply` / `convertToAssets` |
| `IUniswapV2Router02` | quotes and swaps |

---

## 18. Events (indexers)

**Registry:** `VaultRegistered`, `VaultStatusChanged`, `VaultOracleUpdated`, `VaultEpochManagerUpdated`, `VaultTreasuryUpdated`, `GovernorGranted`

**Factory:** `VaultCreated`, `*ImplementationUpdated`, `OpenLiquidityRouterUpdated`, `RFQEngineUpdated`, `SharedSettlementEngineUpdated`

**RWAVault:** `AssetOracleUpdated`, `UniswapRouterUpdated`, `SettlementTokenUpdated`, `WethTokenUpdated`, `SwapIntermediaryUpdated` (+ ERC-20 / ERC-4626)

**Facility:** `CapitalDeployed`, `CapitalRecalled`, `ProtocolWhitelisted`, `AuthorizedSpenderUpdated`

**Router:** `DepositCreated`, `DepositApproved`, `DepositDeclined`, `DepositClaimed`, `ExternalDepositRegistered`, `RedeemRequested`, `RedeemApproved`, `RedeemClaimed`, `RedeemDeclined`, `VaultOperatorSet`, `VaultVestingConfigSet`, `RegistryUpdated`

**Settlement:** `EpochRevenueRecorded`, `EpochSettled`, `RevenueDistributed`, `NAVUpdated`, `FeeDistributed`, `SystemFeeUpdated`, `FeeDistributionUpdated`, `FeeDistributorUpdated`, `VaultOperatorSet`

**EpochManager:** `EpochStarted(epochId, start, end, duration)`, `EpochDurationUpdated`

---

## 19. Error catalogue (custom errors)

All user-facing reverts in this set are **custom errors** (no `require` strings), except what OpenZeppelin emits (`AccessControlUnauthorizedAccount`, `EnforcedPause`, etc.).

Notable router errors: `VaultNotActive`, `InvalidSlippage`, `InsufficientFacilityBalance`, `NotRedeemOwner`, `AlreadyClaimed`, `VestingRequired`, `VestingNotConfigured`, `EpochNotActive`, `RedeemPayoutTooHigh`, `CannotRescueVaultShares`, `InvalidAssetPrice`.

Notable settlement errors: `EpochAlreadySettled`, `EpochNotSettled`, `EpochNotFinished`, `EpochIdMismatch`, `NoEpochManager`, `InvalidEpochPrice`, `ZeroAssetTokensToMint`, `CannotRescueVaultShares`.

Notable facility errors: `ProtocolNotWhitelisted`, `InsufficientIdleBalance`, `DeploymentFailed`, `RecallFailed`, `CalldataTooLong`, `ZeroDeploymentInProtocol`.

---

## 20. Testing

Foundry suite under `test/v2/` plus `test/EpochManager.t.sol` and `test/SwapLib.t.sol` covers the flows and the security patches in this reference (factory role relinquish, external-deposit decline, redeem cap, vesting gate, epoch-end settle, recall failure, decimals offset, duration not moving current `_epochEnd`).

Compiler / deps to freeze in an audit package: **solc 0.8.24**, **OpenZeppelin 5.0.2**.
