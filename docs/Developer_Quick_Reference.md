# Zapper Developer Quick Reference

## Contract Addresses (Testnet)

| Contract | Address | Purpose |
|----------|---------|---------|
| CUP Token | `0xa7bE870C21b79EcA2E16baaB1294436e37aD72D6` | Copper-backed token |
| xCUP Vault | `0x3d47C937F0706dB77339aa1c26aBCc12C644c882` | Investment vault |
| Zapper | `0xD10B1B9eC5E0bd43107CCb501AC3a5E8Cbc2b358` | Main contract |
| Copper Price Consumer | `0xdAfD3DB6a8EaD46d912935cE0eb1277539eecAeC` | Price oracle |

## Key Functions

### Zapper Contract

```solidity
// Main investment function
function zapAndDeposit(IERC20 tokenIn, uint256 amount) external payable returns (uint256 shares)

// Curator approval function
function approveDeposit(bytes32 depositId) external onlyRole(VAULT_CURATOR_ROLE)

// User claim function
function claimDeposit(bytes32 depositId) external returns (uint256 shares)

// Get current copper price
function getCopperPrice() public view returns (uint256 price)

// Emergency controls
function pause() external onlyOwner
function unpause() external onlyOwner
```

### CUP Token

```solidity
// Transfer tokens
function transfer(address to, uint256 amount) external returns (bool)

// Check balance
function balanceOf(address account) external view returns (uint256)

// Mint tokens (role-restricted)
function mint(address account, uint256 value) external onlyRole(MINTER_ROLE)

// Burn tokens (role-restricted)
function burn(address from, uint256 value) external onlyRole(BURNER_ROLE)
```

## Events

### Zapper Events
```solidity
event ZapIn(address indexed router, address indexed tokenIn, uint256 amount);
event ZapInAndDeposit(address indexed router, address indexed tokenIn, uint256 amount, uint256 shares);
event DepositClaimed(bytes32 depositId, address user, uint256 shares);
event DepositApproved(bytes32 depositId);
```

## Common Patterns

### 1. Investment Flow
```javascript
// 1. Approve tokens
await token.approve(zapperAddress, amount);

// 2. Zap and deposit
const tx = await zapper.zapAndDeposit(tokenAddress, amount);
const receipt = await tx.wait();

// 3. Get shares from event
const event = receipt.events.find(e => e.event === 'ZapInAndDeposit');
const shares = event.args.shares;
```

### 2. Approval Process
```javascript
// 1. User creates deposit
const depositId = await zapper.zapAndDeposit(tokenAddress, amount);

// 2. Curator approves
await zapper.approveDeposit(depositId);

// 3. User claims
const shares = await zapper.claimDeposit(depositId);
```

### 3. Price Checking
```javascript
const copperPrice = await zapper.getCopperPrice();
console.log('Current copper price:', copperPrice.toString());
```

## Error Handling

### Common Errors
```solidity
"Invalid input token address"     // tokenIn is zero address
"Invalid amount"                  // amount is zero
"Deposit value is too low"        // calculated value too small
"Insufficient CUP balance"        // not enough CUP in zapper
"Deposit not found"               // depositId doesn't exist
"Deposit already approved"        // deposit already processed
"Invalid user"                    // wrong user claiming deposit
```

### Error Handling in JavaScript
```javascript
try {
    const tx = await zapper.zapAndDeposit(tokenAddress, amount);
    await tx.wait();
} catch (error) {
    if (error.message.includes("Invalid amount")) {
        console.log("Amount must be greater than zero");
    } else if (error.message.includes("Insufficient CUP balance")) {
        console.log("Zapper needs more CUP tokens");
    }
}
```

## Gas Optimization

### Efficient Calls
```javascript
// Batch multiple operations
const batchTx = await zapper.batchZapAndDeposit([
    { token: token1, amount: amount1 },
    { token: token2, amount: amount2 }
]);

// Use estimateGas to check costs
const gasEstimate = await zapper.zapAndDeposit.estimateGas(tokenAddress, amount);
console.log('Estimated gas:', gasEstimate.toString());
```

## Testing

### Unit Test Example
```javascript
describe("Zapper", function() {
    it("Should zap and deposit successfully", async function() {
        const amount = ethers.parseUnits("100", 6); // 100 USDC
        
        await usdc.approve(zapper.address, amount);
        const tx = await zapper.zapAndDeposit(usdc.address, amount);
        const receipt = await tx.wait();
        
        const event = receipt.events.find(e => e.event === 'ZapInAndDeposit');
        expect(event.args.shares).to.be.gt(0);
    });
});
```

## Deployment

### Deployment Order
1. Deploy CUP Token
2. Deploy Copper Price Consumer
3. Deploy xCUP Vault
4. Deploy Zapper with all addresses
5. Deploy Settlement Engine

### Constructor Arguments
```javascript
const zapper = await Zapper.deploy(
    cupToken.address,      // CUP token
    usdcAddress,          // USDC address
    xcupVault.address,    // xCUP vault
    routerAddress,        // Uniswap router
    copperPriceConsumer.address // Price oracle
);
```

## Monitoring

### Key Metrics to Track
- Total value locked (TVL)
- Number of unique users
- Transaction volume
- Gas usage per transaction
- Error rates
- Copper price changes

### Event Monitoring
```javascript
// Listen for deposit events
zapper.on("ZapInAndDeposit", (router, tokenIn, amount, shares) => {
    console.log(`New deposit: ${amount} of ${tokenIn} for ${shares} shares`);
});

// Listen for approval events
zapper.on("DepositApproved", (depositId) => {
    console.log(`Deposit approved: ${depositId}`);
});
```

## Security Checklist

### Before Deployment
- [ ] All contracts audited
- [ ] Access controls properly set
- [ ] Emergency pause tested
- [ ] Slippage protection verified
- [ ] Input validation complete
- [ ] Reentrancy protection in place

### Runtime Monitoring
- [ ] Monitor for unusual transactions
- [ ] Track gas usage patterns
- [ ] Watch for failed transactions
- [ ] Monitor copper price changes
- [ ] Check vault balances regularly

## Troubleshooting

### Common Issues

**Transaction Reverts**
- Check token approvals
- Verify sufficient balances
- Ensure correct addresses
- Check if contract is paused

**High Gas Usage**
- Optimize batch operations
- Use appropriate gas limits
- Consider Layer 2 solutions

**Price Issues**
- Verify oracle connectivity
- Check price feed accuracy
- Monitor for manipulation

### Debug Commands
```javascript
// Check contract state
const isPaused = await zapper.paused();
const owner = await zapper.owner();
const copperPrice = await zapper.getCopperPrice();

// Check user balances
const userBalance = await cupToken.balanceOf(userAddress);
const userShares = await xcupVault.balanceOf(userAddress);

// Check approvals
const allowance = await token.allowance(userAddress, zapperAddress);
```

## Resources

### Documentation
- [User Guide](./Zapper_User_Guide.md)
- [Technical Architecture](./Technical_Architecture.md)
- [Contract Source Code](../contracts/)

### External Links
- [OpenZeppelin Documentation](https://docs.openzeppelin.com/)
- [ERC-4626 Standard](https://eips.ethereum.org/EIPS/eip-4626)
- [Uniswap V2 Documentation](https://docs.uniswap.org/protocol/V2/introduction)

### Support
- GitHub Issues: [Repository Issues](https://github.com/your-repo/issues)
- Discord: [Community Channel](https://discord.gg/your-channel)
- Documentation: [Project Docs](https://docs.your-project.com) 

## External Depositor (HostAdapter) Integration

This section explains the host-to-host integration that allows a backend service to register “external deposits” without on-chain USDC movement, have curators approve the deposit with a price snapshot, and enable a designated EOA beneficiary to claim xCUP at a later stage.

Key components:
- `contracts/Zapper.sol`: main protocol contract (extended to support external deposits)
- `contracts/HostAdapter.sol`: isolated adapter that forwards calls to `Zapper` using dedicated roles

Important properties:
- No USDC is transferred on `registerExternalDepositFor`. It records numbers only.
- Approval stores a price snapshot and a fixed CUP amount to mint on claim.
- Claim mints xCUP to the designated `beneficiary` EOA.
- Registrations are logically irreversible after approval: once approved, you cannot alter amount/tag/beneficiary (except where explicitly allowed prior to approval). After claim, the record is finalized.

### Roles and Access
- In `Zapper`:
  - `HOST_INTEGRATION_ROLE`: allowed to register external deposits and update beneficiary prior to approval
  - `VAULT_CURATOR_ROLE`: allowed to approve deposits (including external with a price snapshot)
- In `HostAdapter`:
  - `HOST_OPERATOR_ROLE`: allowed to call register/update functions on the adapter
  - `CURATOR_OPERATOR_ROLE`: allowed to approve external deposits via the adapter

Granting roles (example):
1) Grant the adapter the integration role on `Zapper` so it can forward calls:
   - Zapper: `grantRole(HOST_INTEGRATION_ROLE, hostAdapterAddress)`
2) Grant your operations EOAs roles on the adapter:
   - HostAdapter: `grantRole(HOST_OPERATOR_ROLE, backendEOA)`
   - HostAdapter: `grantRole(CURATOR_OPERATOR_ROLE, curatorEOA)`

### On-chain Interface

In `Zapper`:
```solidity
// Register external deposit (no token movement)
function registerExternalDepositFor(address beneficiary, uint256 usdcAmount, bytes32 tag)
  external returns (bytes32 depositId);

// Update beneficiary before approval
function setDepositBeneficiary(bytes32 depositId, address beneficiary) external;

// Approve with price snapshot; records fixed CUP amount for claim
function approveExternalDepositWithPrice(bytes32 depositId, uint256 approvedUsdc, uint256 price) external;

// Claim (by user or beneficiary); mints xCUP to beneficiary
function claimDeposit(bytes32 depositId) external returns (uint256 shares);
```

In `HostAdapter` (for isolation):
```solidity
function registerExternalDepositFor(address beneficiary, uint256 usdcAmount, bytes32 tag)
  external onlyRole(HOST_OPERATOR_ROLE) returns (bytes32 depositId);

function setDepositBeneficiary(bytes32 depositId, address beneficiary)
  external onlyRole(HOST_OPERATOR_ROLE);

function approveExternalDepositWithPrice(bytes32 depositId, uint256 approvedUsdc, uint256 price)
  external onlyRole(CURATOR_OPERATOR_ROLE);
```

### Events to Monitor
```solidity
// Emitted by Zapper when external deposit is registered
event ExternalDepositRegistered(address indexed createdBy, address indexed beneficiary, bytes32 indexed depositId, bytes32 tag, uint256 usdcAmount);

// Standard approval event (for both normal and external deposits)
event DepositApproved(bytes32 depositId, uint256 approvedAmount);

// Rich claim event with full context
event DepositClaimedFor(bytes32 indexed depositId, address indexed user, address indexed beneficiary, address claimedBy, bytes32 tag, uint256 shares);
```

### End-to-End Flow (External)
1. Backend (host) registers an external deposit with a beneficiary and tag using `HostAdapter.registerExternalDepositFor`.
2. Curator approves the external deposit using `HostAdapter.approveExternalDepositWithPrice`, providing:
   - `approvedUsdc`: amount of USDC-equivalent to approve
   - `price`: the copper price snapshot used to compute fixed CUP
3. Beneficiary (or originator) calls `Zapper.claimDeposit(depositId)` and receives xCUP minted to the `beneficiary` address.

Irreversibility notes:
- Before approval: beneficiary can be adjusted by host via `setDepositBeneficiary`.
- After approval: deposit amounts and beneficiary are locked for that `depositId`.
- After claim: the process is finalized; you cannot unclaim.

Operational requirements:
- Zapper must hold or be able to mint sufficient CUP to fund the vault deposit at claim time.
- Epoch must be active (claim guarded by epoch checks).

### Security Guidance
- Use separate EOAs for host operator and curator operator.
- Restrict `HOST_OPERATOR_ROLE` and `CURATOR_OPERATOR_ROLE` to the adapter; restrict `HOST_INTEGRATION_ROLE` to the adapter on Zapper.
- Log and reconcile `ExternalDepositRegistered` ↔ `DepositApproved` ↔ `DepositClaimedFor` with your backend tracking IDs (`tag`).
- Snapshot price carefully (data source governance, integrity, and precision).

---

## How-To: Build, Sign, and Send Transactions

Below are examples for calling `HostAdapter.registerExternalDepositFor` and `HostAdapter.approveExternalDepositWithPrice` via Node.js (Ethers v6), Java (web3j), and raw JSON-RPC using Infura.

Assumptions:
- Network: Sepolia (replace with your target)
- RPC: `https://sepolia.infura.io/v3/<INFURA_PROJECT_ID>`
- Addresses: `hostAdapterAddress`, `zapperAddress`, `xcupAddress` already deployed

### Node.js (Ethers v6)
```bash
npm install ethers
```

```javascript
import { ethers } from "ethers";

const INFURA_ID = process.env.INFURA_ID; // "<INFURA_PROJECT_ID>"
const RPC_URL = `https://sepolia.infura.io/v3/${INFURA_ID}`;

// Backend operator (has HOST_OPERATOR_ROLE on HostAdapter)
const PRIVATE_KEY_HOST = process.env.PRIVATE_KEY_HOST;
// Curator operator (has CURATOR_OPERATOR_ROLE on HostAdapter)
const PRIVATE_KEY_CURATOR = process.env.PRIVATE_KEY_CURATOR;

const hostAdapterAddress = "0xYourHostAdapter";

// Minimal ABI for HostAdapter
const hostAdapterAbi = [
  "function registerExternalDepositFor(address beneficiary, uint256 usdcAmount, bytes32 tag) external returns (bytes32)",
  "function approveExternalDepositWithPrice(bytes32 depositId, uint256 approvedUsdc, uint256 price) external"
];

async function main() {
  const provider = new ethers.JsonRpcProvider(RPC_URL);

  // 1) Register external deposit (host)
  const hostWallet = new ethers.Wallet(PRIVATE_KEY_HOST, provider);
  const hostAdapterHost = new ethers.Contract(hostAdapterAddress, hostAdapterAbi, hostWallet);

  const beneficiary = "0xBeneficiaryEOA";
  const usdcAmount = 1000n * 10n ** 6n; // 1000 USDC with 6 decimals
  const tag = ethers.encodeBytes32String("ORDER-12345");

  const tx1 = await hostAdapterHost.registerExternalDepositFor(beneficiary, usdcAmount, tag);
  const rc1 = await tx1.wait();
  const depositRegistered = rc1.logs
    .map(l => {
      try { return hostAdapterHost.interface.parseLog(l); } catch { return null; }
    })
    .filter(Boolean);
  console.log("register tx hash:", rc1.transactionHash);

  // Extract depositId from event logs (e.g., ExternalDepositRegistered)
  // You may need to use the Zapper ABI if the event is emitted by Zapper, not HostAdapter
  // Example assumes hostAdapterHost.interface has the event, otherwise use the correct ABI:
  let depositId;
  for (const log of rc1.logs) {
    let parsed;
    try {
      parsed = hostAdapterHost.interface.parseLog(log);
    } catch {
      continue;
    }
    if (parsed && parsed.name === "ExternalDepositRegistered") {
      depositId = parsed.args.depositId;
      break;
    }
  }
  if (!depositId) {
    throw new Error("depositId not found in logs");
  }
  console.log("depositId:", depositId);

  // 2) Approve with price snapshot (curator)
  const curatorWallet = new ethers.Wallet(PRIVATE_KEY_CURATOR, provider);
  const hostAdapterCurator = new ethers.Contract(hostAdapterAddress, hostAdapterAbi, curatorWallet);

  const approvedUsdc = usdcAmount; // approve full amount
  const price = 500n; // example price scaling (match protocol expectations)

  const tx2 = await hostAdapterCurator.approveExternalDepositWithPrice(depositId, approvedUsdc, price);
  await tx2.wait();
  console.log("approved tx hash:", tx2.hash);
}

main().catch(console.error);
```

### Java (web3j)
```xml
<!-- Maven -->
<dependency>
  <groupId>org.web3j</groupId>
  <artifactId>core</artifactId>
  <version>4.10.3</version>
<\/dependency>
```

```java
import org.web3j.protocol.Web3j;
import org.web3j.protocol.http.HttpService;
import org.web3j.crypto.Credentials;
import org.web3j.tx.gas.DefaultGasProvider;
import org.web3j.abi.FunctionEncoder;
import org.web3j.abi.datatypes.Function;
import org.web3j.abi.datatypes.Address;
import org.web3j.abi.datatypes.generated.Bytes32;
import org.web3j.abi.datatypes.generated.Uint256;
import org.web3j.protocol.core.methods.request.Transaction;
import org.web3j.protocol.core.methods.response.EthSendTransaction;
import java.math.BigInteger;
import java.util.Arrays;

public class HostAdapterClient {
  public static void main(String[] args) throws Exception {
    String infuraId = System.getenv("INFURA_ID");
    String rpcUrl = "https://sepolia.infura.io/v3/" + infuraId;
    Web3j web3 = Web3j.build(new HttpService(rpcUrl));

    String privateKeyHost = System.getenv("PRIVATE_KEY_HOST");
    Credentials hostCreds = Credentials.create(privateKeyHost);

    String hostAdapter = "0xYourHostAdapter";
    String beneficiary = "0xBeneficiaryEOA";
    BigInteger usdcAmount = new BigInteger("1000000000"); // 1000e6
    byte[] tagBytes = Arrays.copyOf("ORDER-12345".getBytes(), 32);

    // 1) encode registerExternalDepositFor
    Function registerFn = new Function(
      "registerExternalDepositFor",
      Arrays.asList(new Address(beneficiary), new Uint256(usdcAmount), new Bytes32(tagBytes)),
      Arrays.asList()
    );
    String data = FunctionEncoder.encode(registerFn);

    Transaction tx = Transaction.createFunctionCallTransaction(
      hostCreds.getAddress(), null, DefaultGasProvider.GAS_PRICE, DefaultGasProvider.GAS_LIMIT, hostAdapter, BigInteger.ZERO, data
    );

    EthSendTransaction sent = web3.ethSendTransaction(tx).send();
    System.out.println("register tx hash: " + sent.getTransactionHash());
  }
}
```

### Raw JSON-RPC

Build and send a raw signed transaction to Infura.

1) Build the transaction data for `registerExternalDepositFor(address,uint256,bytes32)` using an ABI encoder (e.g., `ethers`, `web3j`).
2) Sign offline with your private key, getting `0x<signed_raw_tx>`.
3) Submit via JSON-RPC:

```json
{
  "jsonrpc": "2.0",
  "method": "eth_sendRawTransaction",
  "params": ["0xSIGNED_RAW_TRANSACTION"],
  "id": 1
}
```

Infura endpoint:
```
POST https://sepolia.infura.io/v3/<INFURA_PROJECT_ID>
Content-Type: application/json
```

### Common Pitfalls
- Ensure the adapter has been granted `HOST_INTEGRATION_ROLE` on `Zapper`.
- Ensure the operator EOAs have roles on `HostAdapter`.
- Use consistent price scaling across approval/claim (match protocol’s `price` scaling).
- xCUP mint at claim requires sufficient CUP available to `Zapper`.
- The external registration call itself does not transfer USDC; it’s an accounting/authorization step.
