import { ethers, upgrades } from "hardhat";

async function main() {
    console.log("🚀 Deploying Alcum Smart Contracts with Upgradeable Pattern...\n");

    const [deployer] = await ethers.getSigners();
    console.log("Deploying contracts with account:", deployer.address);
    console.log("Account balance:", (await deployer.provider.getBalance(deployer.address)).toString());

    // Configuration
    const EPOCH_DURATION = 30 * 24 * 60 * 60; // 30 days
    const SYSTEM_FEE_BPS = 500; // 5%
    const TREASURY_ADDRESS = deployer.address; // Use deployer as treasury for now

    // Mock addresses for testnet (replace with real addresses for mainnet)
    const CHAINLINK_ORACLE = "0x1234567890123456789012345678901234567890";
    const CHAINLINK_JOB_ID = "0x1234567890123456789012345678901234567890123456789012345678901234";
    const CHAINLINK_FEE = ethers.parseEther("0.1");
    const LINK_TOKEN = "0x514910771AF9Ca656af840dff83E8264EcF986CA"; // Mainnet LINK
    const UNISWAP_ROUTER = "0x7a250d5630B4cF539739dF2C5dAcb4c659F2488D"; // Uniswap V2 Router
    const USDC_TOKEN = "0xA0b86a33E6441b8435b662303C0f7c5e8e4c8c4b"; // Mock USDC
    const WETH_TOKEN = "0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2"; // WETH

    console.log("\n📋 Deployment Configuration:");
    console.log("- Epoch Duration:", EPOCH_DURATION, "seconds");
    console.log("- System Fee:", SYSTEM_FEE_BPS / 100, "%");
    console.log("- Treasury:", TREASURY_ADDRESS);

    try {
        // 1. Deploy CUPToken (Upgradeable)
        console.log("\n1️⃣ Deploying CUPToken...");
        const CUPToken = await ethers.getContractFactory("CUPToken");
        const cupToken = await upgrades.deployProxy(
            CUPToken,
            [], // initialize() takes no parameters
            {
                initializer: "initialize",
                kind: "transparent",
            },
        );
        await cupToken.waitForDeployment();
        const cupTokenAddress = await cupToken.getAddress();
        console.log("✅ CUPToken deployed to:", cupTokenAddress);

        // 2. Deploy CopperPriceConsumer (Upgradeable)
        console.log("\n2️⃣ Deploying CopperPriceConsumer...");
        const CopperPriceConsumer = await ethers.getContractFactory("CopperPriceConsumer");
        const copperPriceConsumer = await upgrades.deployProxy(
            CopperPriceConsumer,
            [CHAINLINK_ORACLE, CHAINLINK_JOB_ID, CHAINLINK_FEE, LINK_TOKEN],
            {
                initializer: "initialize",
                kind: "transparent",
            },
        );
        await copperPriceConsumer.waitForDeployment();
        const copperPriceConsumerAddress = await copperPriceConsumer.getAddress();
        console.log("✅ CopperPriceConsumer deployed to:", copperPriceConsumerAddress);

        // 3. Deploy EpochManager (Upgradeable)
        console.log("\n3️⃣ Deploying EpochManager...");
        const EpochManager = await ethers.getContractFactory("EpochManager");
        const epochManager = await upgrades.deployProxy(EpochManager, [EPOCH_DURATION], {
            initializer: "initialize",
            kind: "transparent",
        });
        await epochManager.waitForDeployment();
        const epochManagerAddress = await epochManager.getAddress();
        console.log("✅ EpochManager deployed to:", epochManagerAddress);

        // 4. Deploy xCUP Vault (Upgradeable)
        console.log("\n4️⃣ Deploying xCUP Vault...");
        const XCUP = await ethers.getContractFactory("xCUP");
        const xcupVault = await upgrades.deployProxy(XCUP, [cupTokenAddress, "xCUP Vault", "xCUP"], {
            initializer: "initialize",
            kind: "transparent",
        });
        await xcupVault.waitForDeployment();
        const xcupVaultAddress = await xcupVault.getAddress();
        console.log("✅ xCUP Vault deployed to:", xcupVaultAddress);

        // 5. Deploy SettlementEngine (Upgradeable)
        console.log("\n5️⃣ Deploying SettlementEngine...");
        const SettlementEngine = await ethers.getContractFactory("SettlementEngine");
        const settlementEngine = await upgrades.deployProxy(
            SettlementEngine,
            [
                xcupVaultAddress,
                TREASURY_ADDRESS,
                epochManagerAddress,
                copperPriceConsumerAddress,
                USDC_TOKEN,
                SYSTEM_FEE_BPS,
            ],
            {
                initializer: "initialize",
                kind: "transparent",
            },
        );
        await settlementEngine.waitForDeployment();
        const settlementEngineAddress = await settlementEngine.getAddress();
        console.log("✅ SettlementEngine deployed to:", settlementEngineAddress);

        // 6. Deploy Zapper (Upgradeable)
        console.log("\n6️⃣ Deploying Zapper...");
        const Zapper = await ethers.getContractFactory("Zapper");
        const zapper = await upgrades.deployProxy(
            Zapper,
            [
                cupTokenAddress,
                USDC_TOKEN,
                xcupVaultAddress,
                UNISWAP_ROUTER,
                copperPriceConsumerAddress,
                epochManagerAddress,
            ],
            {
                initializer: "initialize",
                kind: "transparent",
            },
        );
        await zapper.waitForDeployment();
        const zapperAddress = await zapper.getAddress();
        console.log("✅ Zapper deployed to:", zapperAddress);

        // 7. Setup Roles and Permissions
        console.log("\n7️⃣ Setting up roles and permissions...");

        // Grant MINTER_ROLE to SettlementEngine
        await cupToken.grantRole(await cupToken.MINTER_ROLE(), settlementEngineAddress);
        console.log("✅ Granted MINTER_ROLE to SettlementEngine");

        // Grant BURNER_ROLE to SettlementEngine
        await cupToken.grantRole(await cupToken.BURNER_ROLE(), settlementEngineAddress);
        console.log("✅ Granted BURNER_ROLE to SettlementEngine");

        // Grant REDEEMER_ROLE to Zapper
        await xcupVault.grantRole(await xcupVault.REDEEMER_ROLE(), zapperAddress);
        console.log("✅ Granted REDEEMER_ROLE to Zapper");

        // Grant VAULT_CURATOR_ROLE to deployer (can be changed later)
        await zapper.grantRole(await zapper.VAULT_CURATOR_ROLE(), deployer.address);
        console.log("✅ Granted VAULT_CURATOR_ROLE to deployer");

        // 8. Initialize xCUP V2 features
        console.log("\n8️⃣ Initializing xCUP V2 features...");
        await xcupVault.initializeV2(copperPriceConsumerAddress, UNISWAP_ROUTER, USDC_TOKEN, WETH_TOKEN);
        console.log("✅ xCUP V2 features initialized");

        // 10. Save deployment info
        const deploymentInfo = {
            network: await ethers.provider.getNetwork(),
            deployer: deployer.address,
            timestamp: new Date().toISOString(),
            contracts: {
                CUPToken: cupTokenAddress,
                CopperPriceConsumer: copperPriceConsumerAddress,
                EpochManager: epochManagerAddress,
                xCUPVault: xcupVaultAddress,
                SettlementEngine: settlementEngineAddress,
                Zapper: zapperAddress,
            },
            configuration: {
                epochDuration: EPOCH_DURATION,
                systemFeeBps: SYSTEM_FEE_BPS,
                treasury: TREASURY_ADDRESS,
            },
        };

        console.log("\n💾 Deployment info saved to deployed-addresses.json");

        // Write to file (you might need to install fs)
        const fs = require("fs");
        fs.writeFileSync("deployed-addresses.json", JSON.stringify(deploymentInfo, null, 2));

        console.log("\n✨ All contracts are now upgradeable and ready for use!");
        console.log("\n⚠️  Important Notes:");
        console.log("- All contracts use OpenZeppelin's transparent proxy pattern");
        console.log("- ProxyAdmin contracts have been deployed for each proxy");
        console.log("- Only the deployer can upgrade contracts initially");
        console.log("- Consider transferring ownership to a multisig for production");
        console.log("- Update mock addresses with real ones for mainnet deployment");
    } catch (error) {
        console.error("\n❌ Deployment failed:", error);
        process.exit(1);
    }
}

main()
    .then(() => process.exit(0))
    .catch((error) => {
        console.error(error);
        process.exit(1);
    });
