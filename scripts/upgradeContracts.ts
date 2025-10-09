import { ethers, upgrades } from "hardhat";
import fs from "fs";

async function main() {
    console.log("🔄 Upgrading Alcum Smart Contracts...\n");

    const [deployer] = await ethers.getSigners();
    console.log("Upgrading contracts with account:", deployer.address);

    // Load deployment info
    let deploymentInfo;
    try {
        const deploymentData = fs.readFileSync("deployed-addresses.json", "utf8");
        deploymentInfo = JSON.parse(deploymentData);
    } catch (error) {
        console.error("❌ Could not load deployed-addresses.json");
        console.error("Please run deployUpgradeable.ts first");
        process.exit(1);
    }

    const contracts = deploymentInfo.contracts;

    try {
        console.log("📋 Current Contract Addresses:");
        Object.entries(contracts).forEach(([name, address]) => {
            console.log(`- ${name}: ${address}`);
        });

        // Example: Upgrade CUPToken
        console.log("\n1️⃣ Upgrading CUPToken...");
        const CUPTokenV2 = await ethers.getContractFactory("CUPToken");
        const cupTokenUpgraded = await upgrades.upgradeProxy(contracts.CUPToken, CUPTokenV2);
        await cupTokenUpgraded.waitForDeployment();
        console.log("✅ CUPToken upgraded successfully");

        // Example: Upgrade CopperPriceConsumer
        console.log("\n2️⃣ Upgrading CopperPriceConsumer...");
        const CopperPriceConsumerV2 = await ethers.getContractFactory("CopperPriceConsumer");
        const copperPriceConsumerUpgraded = await upgrades.upgradeProxy(
            contracts.CopperPriceConsumer,
            CopperPriceConsumerV2,
        );
        await copperPriceConsumerUpgraded.waitForDeployment();
        console.log("✅ CopperPriceConsumer upgraded successfully");

        // Example: Upgrade EpochManager
        console.log("\n3️⃣ Upgrading EpochManager...");
        const EpochManagerV2 = await ethers.getContractFactory("EpochManager");
        const epochManagerUpgraded = await upgrades.upgradeProxy(contracts.EpochManager, EpochManagerV2);
        await epochManagerUpgraded.waitForDeployment();
        console.log("✅ EpochManager upgraded successfully");

        // Example: Upgrade xCUP
        console.log("\n4️⃣ Upgrading xCUP Vault...");
        const XCUPV2 = await ethers.getContractFactory("xCUP");
        const xcupUpgraded = await upgrades.upgradeProxy(contracts.xCUPVault, XCUPV2);
        await xcupUpgraded.waitForDeployment();
        console.log("✅ xCUP Vault upgraded successfully");

        // Example: Upgrade SettlementEngine
        console.log("\n5️⃣ Upgrading SettlementEngine...");
        const SettlementEngineV2 = await ethers.getContractFactory("SettlementEngine");
        const settlementEngineUpgraded = await upgrades.upgradeProxy(contracts.SettlementEngine, SettlementEngineV2);
        await settlementEngineUpgraded.waitForDeployment();
        console.log("✅ SettlementEngine upgraded successfully");

        // Example: Upgrade Zapper
        console.log("\n6️⃣ Upgrading Zapper...");
        const ZapperV2 = await ethers.getContractFactory("Zapper");
        const zapperUpgraded = await upgrades.upgradeProxy(contracts.Zapper, ZapperV2);
        await zapperUpgraded.waitForDeployment();
        console.log("✅ Zapper upgraded successfully");

        console.log("\n🎉 All contracts upgraded successfully!");
        console.log("\n✨ Contract addresses remain the same (proxy pattern)");
        console.log("📝 Implementation contracts have been updated");

        // Update deployment info with upgrade timestamp
        deploymentInfo.lastUpgrade = new Date().toISOString();
        deploymentInfo.upgrader = deployer.address;

        fs.writeFileSync("deployed-addresses.json", JSON.stringify(deploymentInfo, null, 2));

        console.log("\n💾 Deployment info updated");
    } catch (error) {
        console.error("\n❌ Upgrade failed:", error);
        process.exit(1);
    }
}

// Function to upgrade a specific contract
async function upgradeSpecificContract(contractName: string, proxyAddress: string) {
    console.log(`🔄 Upgrading ${contractName}...`);

    const ContractFactory = await ethers.getContractFactory(contractName);
    const upgraded = await upgrades.upgradeProxy(proxyAddress, ContractFactory);
    await upgraded.waitForDeployment();

    console.log(`✅ ${contractName} upgraded successfully`);
    return upgraded;
}

// Function to validate upgrade safety
async function validateUpgrade(contractName: string, proxyAddress: string) {
    console.log(`🔍 Validating upgrade for ${contractName}...`);

    const ContractFactory = await ethers.getContractFactory(contractName);

    try {
        await upgrades.validateUpgrade(proxyAddress, ContractFactory);
        console.log(`✅ ${contractName} upgrade validation passed`);
        return true;
    } catch (error) {
        console.error(`❌ ${contractName} upgrade validation failed:`, error);
        return false;
    }
}

// Export functions for individual use
export { upgradeSpecificContract, validateUpgrade };

main()
    .then(() => process.exit(0))
    .catch((error) => {
        console.error(error);
        process.exit(1);
    });
