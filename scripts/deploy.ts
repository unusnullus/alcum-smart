/* eslint-disable no-console */
import { run } from "hardhat";
import { config } from "dotenv";
import { ethers, upgrades } from "hardhat";
import { ContractFactory, BaseContract } from "ethers";
import * as fs from "fs";
import * as path from "path";
import { CUPToken, XCUP, CopperPriceConsumer, EpochManager, SettlementEngine, Zapper } from "../typechain-types";

import { OPERATOR_ADDRESS, ROUTER_ADDRESS, USDC_ADDRESS, LINK_ADDRESS } from "../constants";

config();

// Deployment configuration
interface DeploymentConfig {
    jobId: string;
    linkFee: string;
}

const DEPLOYMENT_CONFIG: DeploymentConfig = {
    jobId: "0xaa9d5d553df8478fac9d7eac75aa9c4b00000000000000000000000000000000",
    linkFee: "0.1", // 0.1 LINK
};

// Contract addresses storage
interface DeployedContracts {
    cupToken?: string;
    xcup?: string;
    copperPriceConsumer?: string;
    epochManager?: string;
    settlementEngine?: string;
    zapper?: string;
}

// Load existing deployed contracts from file
function loadDeployedContracts(): DeployedContracts {
    const addressesPath = path.join(__dirname, "..", "deployed-addresses.json");
    if (fs.existsSync(addressesPath)) {
        const addresses = JSON.parse(fs.readFileSync(addressesPath, "utf8"));
        console.log("📂 Loaded existing contract addresses:");
        Object.entries(addresses).forEach(([name, address]) => {
            console.log(`   ${name}: ${address}`);
        });
        return addresses;
    }
    return {};
}

const deployedContracts: DeployedContracts = loadDeployedContracts();

/**
 * Deploy CUP Token contract (upgradeable)
 */
async function deployCUPToken(): Promise<BaseContract> {
    console.log("\n🚀 Deploying CUPToken (upgradeable)...");

    const CUPTokenFactory = await ethers.getContractFactory("CUPToken");
    const cupToken = await upgrades.deployProxy(CUPTokenFactory, []);
    await cupToken.waitForDeployment();

    deployedContracts.cupToken = await cupToken.getAddress();
    console.log("✅ CUPToken deployed at:", deployedContracts.cupToken);

    return cupToken;
}

/**
 * Deploy xCUP Vault contract (upgradeable)
 */
async function deployXCUP(cupTokenAddress: string, copperPriceConsumerAddress: string): Promise<BaseContract> {
    console.log("\n🚀 Deploying xCUP (upgradeable)...");

    const XCUPFactory = await ethers.getContractFactory("xCUP");
    const xcup = await upgrades.deployProxy(XCUPFactory, [
        cupTokenAddress,
        "Alcum Copper Vault",
        "xCUP",
        copperPriceConsumerAddress,
        ROUTER_ADDRESS,
        USDC_ADDRESS,
        "0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2", // WETH on Sepolia
    ]);
    await xcup.waitForDeployment();

    deployedContracts.xcup = await xcup.getAddress();
    console.log("✅ xCUP deployed at:", deployedContracts.xcup);

    return xcup;
}

/**
 * Deploy Copper Price Consumer contract (NOT upgradeable)
 */
async function deployCopperPriceConsumer(): Promise<BaseContract> {
    console.log("\n🚀 Deploying CopperPriceConsumer...");

    const CopperPriceConsumerFactory = await ethers.getContractFactory("CopperPriceConsumer");
    const copperPriceConsumer = await CopperPriceConsumerFactory.deploy(
        OPERATOR_ADDRESS,
        DEPLOYMENT_CONFIG.jobId,
        ethers.parseUnits(DEPLOYMENT_CONFIG.linkFee, 18),
        LINK_ADDRESS,
    );
    await copperPriceConsumer.waitForDeployment();

    deployedContracts.copperPriceConsumer = await copperPriceConsumer.getAddress();
    console.log("✅ CopperPriceConsumer deployed at:", deployedContracts.copperPriceConsumer);

    return copperPriceConsumer;
}

/**
 * Deploy Epoch Manager contract (upgradeable)
 */
async function deployEpochManager(): Promise<BaseContract> {
    console.log("\n🚀 Deploying EpochManager (upgradeable)...");

    const EpochManagerFactory = await ethers.getContractFactory("EpochManager");
    const epochManager = await upgrades.deployProxy(EpochManagerFactory, [2592000]);
    await epochManager.waitForDeployment();

    deployedContracts.epochManager = await epochManager.getAddress();
    console.log("✅ EpochManager deployed at:", deployedContracts.epochManager);

    return epochManager;
}

/**
 * Deploy Settlement Engine contract (upgradeable)
 */
async function deploySettlementEngine(
    xcupAddress: string,
    treasuryAddress: string,
    zapperAddress: string,
    epochManagerAddress: string,
    copperPriceConsumerAddress: string,
    systemFeeBps: number,
): Promise<BaseContract> {
    console.log("\n🚀 Deploying SettlementEngine (upgradeable)...");

    const SettlementEngineFactory = await ethers.getContractFactory("SettlementEngine");
    const settlementEngine = await upgrades.deployProxy(SettlementEngineFactory, [
        xcupAddress,
        treasuryAddress,
        zapperAddress,
        epochManagerAddress,
        copperPriceConsumerAddress,
        USDC_ADDRESS,
        systemFeeBps,
    ]);
    await settlementEngine.waitForDeployment();

    deployedContracts.settlementEngine = await settlementEngine.getAddress();
    console.log("✅ SettlementEngine deployed at:", deployedContracts.settlementEngine);

    return settlementEngine;
}

/**
 * Deploy Zapper contract (upgradeable)
 */
async function deployZapper(
    cupTokenAddress: string,
    xcupAddress: string,
    copperPriceConsumerAddress: string,
    epochManagerAddress: string,
): Promise<Zapper> {
    console.log("\n🚀 Deploying Zapper (upgradeable)...");

    const ZapperFactory = await ethers.getContractFactory("Zapper");
    const zapper = (await upgrades.deployProxy(ZapperFactory, [
        cupTokenAddress,
        USDC_ADDRESS,
        xcupAddress,
        ROUTER_ADDRESS,
        copperPriceConsumerAddress,
        epochManagerAddress,
    ])) as unknown as Zapper;
    await zapper.waitForDeployment();

    deployedContracts.zapper = await zapper.getAddress();
    console.log("✅ Zapper deployed at:", deployedContracts.zapper);

    return zapper;
}

/**
 * Setup contract permissions and initial configuration
 */
async function setupContracts(contracts: {
    cupToken: CUPToken;
    settlementEngine: SettlementEngine;
    xcup: XCUP;
}): Promise<void> {
    console.log("\n⚙️ Setting up contract permissions...");

    // Grant MINTER_ROLE to SettlementEngine on CUPToken
    const MINTER_ROLE = await contracts.cupToken.MINTER_ROLE();
    await contracts.cupToken.grantRole(MINTER_ROLE, deployedContracts.settlementEngine!);
    console.log("✅ Granted MINTER_ROLE to SettlementEngine");

    // Grant REDEEMER_ROLE to Zapper on xCUP
    const REDEEMER_ROLE = await contracts.xcup.REDEEMER_ROLE();
    await contracts.xcup.grantRole(REDEEMER_ROLE, deployedContracts.zapper!);
    console.log("✅ Granted REDEEMER_ROLE to Zapper");

    // Setup any additional permissions as needed
    console.log("✅ Contract setup completed");
}

/**
 * Verify all deployed contracts
 */
async function verifyContracts(): Promise<void> {
    console.log("\n🔍 Verifying contracts...");
    console.log("ℹ️ Note: Upgradeable contracts will be verified automatically by OpenZeppelin plugin");
    console.log("ℹ️ Only verifying CopperPriceConsumer (regular contract)");

    // Only verify CopperPriceConsumer as it's a regular contract
    // Upgradeable contracts are automatically verified by OpenZeppelin plugin
    const verifications = [
        {
            address: deployedContracts.copperPriceConsumer!,
            args: [
                OPERATOR_ADDRESS,
                DEPLOYMENT_CONFIG.jobId,
                ethers.parseUnits(DEPLOYMENT_CONFIG.linkFee, 18),
                LINK_ADDRESS,
            ],
            name: "CopperPriceConsumer",
        },
    ];

    for (const verification of verifications) {
        await verify(verification.address, verification.args, verification.name);
    }

    // Print proxy addresses for manual verification if needed
    console.log("\n📋 Upgradeable Contract Addresses (auto-verified by OpenZeppelin):");
    console.log(`   CUPToken Proxy: ${deployedContracts.cupToken}`);
    console.log(`   xCUP Proxy: ${deployedContracts.xcup}`);
    console.log(`   EpochManager Proxy: ${deployedContracts.epochManager}`);
    console.log(`   SettlementEngine Proxy: ${deployedContracts.settlementEngine}`);
    console.log(`   Zapper Proxy: ${deployedContracts.zapper}`);
}

/**
 * Utility function to verify a contract
 */
const delay = async (milliseconds: number) => await new Promise((resolve) => setTimeout(resolve, milliseconds));

export const verify = async (address: string, args: any[], contractName?: string) => {
    const name = contractName ? ` (${contractName})` : "";
    console.log(`⏳ Waiting before verifying contract${name} at ${address}`);
    await delay(10000);

    console.log(`🔍 Verifying contract${name}...`);
    try {
        await run("verify:verify", {
            address,
            constructorArguments: args,
        });
        console.log(`✅ ${contractName || "Contract"} verified successfully`);
    } catch (error: any) {
        if (error.message.toLowerCase().includes("already verified")) {
            console.log(`✅ ${contractName || "Contract"} already verified`);
        } else {
            console.error(`❌ Error verifying ${contractName || "contract"}:`, error.message);
        }
    }
};

/**
 * Print deployment summary
 */
function printDeploymentSummary(): void {
    console.log("\n" + "=".repeat(60));
    console.log("🎉 DEPLOYMENT COMPLETED SUCCESSFULLY!");
    console.log("=".repeat(60));
    console.log("📋 Contract Addresses:");
    console.log(`   CUPToken:           ${deployedContracts.cupToken}`);
    console.log(`   xCUP:               ${deployedContracts.xcup}`);
    console.log(`   CopperPriceConsumer: ${deployedContracts.copperPriceConsumer}`);
    console.log(`   EpochManager:       ${deployedContracts.epochManager}`);
    console.log(`   SettlementEngine:   ${deployedContracts.settlementEngine}`);
    console.log(`   Zapper:             ${deployedContracts.zapper}`);
    console.log("=".repeat(60));

    // Save addresses to a JSON file for future reference
    const fs = require("fs");
    const path = require("path");

    const addressesPath = path.join(__dirname, "..", "deployed-addresses.json");
    fs.writeFileSync(addressesPath, JSON.stringify(deployedContracts, null, 2));
    console.log(`📁 Addresses saved to: ${addressesPath}`);
}

/**
 * Main deployment function - deploys all contracts fresh
 *
 * Usage:
 * - Deploy: npx hardhat run scripts/deploy.ts --network sepolia
 */
async function main(): Promise<void> {
    try {
      console.log("🚀 Starting deployment process...");
        const [owner] = await ethers.getSigners();
        console.log("🚀 Starting deployment process with account:", owner.address);
        console.log("💰 Account balance:", ethers.formatEther(await ethers.provider.getBalance(owner.address)), "ETH");

        console.log("\n🆕 Deploying all contracts...");

        // Deploy contracts in correct order
        console.log("\n🔄 Step 1: Deploy CUPToken (upgradeable proxy)");
        const cupToken = (await deployCUPToken()) as unknown as CUPToken;

        console.log("\n🔄 Step 2: Deploy EpochManager (upgradeable proxy)");
        const epochManager = (await deployEpochManager()) as EpochManager;

        console.log("\n🔄 Step 3: Deploy CopperPriceConsumer (regular contract)");
        const copperPriceConsumer = (await deployCopperPriceConsumer()) as CopperPriceConsumer;

        console.log("\n🔄 Step 4: Deploy xCUP (upgradeable proxy)");
        const xcup = (await deployXCUP(deployedContracts.cupToken!, deployedContracts.copperPriceConsumer!)) as XCUP;

        console.log("\n🔄 Step 5: Deploy Zapper (upgradeable proxy)");
        const zapper = await deployZapper(
            deployedContracts.cupToken!,
            deployedContracts.xcup!,
            deployedContracts.copperPriceConsumer!,
            deployedContracts.epochManager!,
        );

        console.log("\n🔄 Step 6: Deploy SettlementEngine (upgradeable proxy)");
        const settlementEngine = (await deploySettlementEngine(
            deployedContracts.xcup!,
            owner.address,
            deployedContracts.zapper!,
            deployedContracts.epochManager!,
            deployedContracts.copperPriceConsumer!,
            600, // 6% system fee
        )) as SettlementEngine;

        console.log("\n🔄 Step 7: Setup contract permissions");
        await setupContracts({
            cupToken,
            settlementEngine,
            xcup,
        });

        console.log("\n🔄 Step 8: Verify contracts on Etherscan");
        await verifyContracts();

        // Print summary
        printDeploymentSummary();
    } catch (error) {
        console.error("❌ Deployment failed:", error);
        process.exitCode = 1;
    }
}

// Execute deployment
main().catch((error) => {
    console.error(error);
    process.exitCode = 1;
});
