# Zapper Developer Quick Reference

## Contract Addresses (Testnet)

| Contract | Address | Purpose |
|----------|---------|---------|
| CUP Token | `0x9E1cC5d32cA6a9F3d2286B6b66193DaB14413a39` | Copper-backed token |
| xCUP Vault | `0x56940642432323bD3050675CcE1ff7E45C498afc` | Investment vault |
| Zapper | `0x7F1e09F92b20ee09F0A535Aa2a068d39af27e6f3` | Main contract |
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