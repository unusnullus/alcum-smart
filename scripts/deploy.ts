/* eslint-disable no-console */
import { run } from "hardhat";
import { config } from "dotenv";
import { ethers, upgrades } from "hardhat";
import { ContractFactory, BaseContract } from "ethers";
import {
  CUPToken,
  XCUP,
  CopperPriceConsumer,
  EpochManager,
  SettlementEngine,
  Zapper,
} from "../typechain-types";

import {
  OPERATOR_ADDRESS,
  ROUTER_ADDRESS,
  USDC_ADDRESS,
  LINK_ADDRESS,
} from "../constants";

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

const deployedContracts: DeployedContracts = {};

/**
 * Deploy CUP Token contract
 */
async function deployCUPToken(): Promise<CUPToken> {
  console.log("\n🚀 Deploying CUPToken...");

  const CUPTokenFactory = await ethers.getContractFactory("CUPToken");
  const cupToken = await CUPTokenFactory.deploy() as CUPToken;
  await cupToken.waitForDeployment();

  deployedContracts.cupToken = await cupToken.getAddress();
  console.log("✅ CUPToken deployed at:", deployedContracts.cupToken);

  return cupToken;
}

/**
 * Deploy xCUP Vault contract
 */
async function deployXCUP(cupTokenAddress: string): Promise<BaseContract> {
  console.log("\n🚀 Deploying xCUP (upgradeable)...");

  const XCUPFactory = await ethers.getContractFactory("xCUP");
  const xcup = await upgrades.deployProxy(XCUPFactory, [
    cupTokenAddress,
    "Alcum Copper Vault",
    "xCUP"
  ]);
  await xcup.waitForDeployment();

  deployedContracts.xcup = await xcup.getAddress();
  console.log("✅ xCUP deployed at:", deployedContracts.xcup);

  return xcup;
}

/**
 * Deploy Copper Price Consumer contract
 */
async function deployCopperPriceConsumer(): Promise<CopperPriceConsumer> {
  console.log("\n🚀 Deploying CopperPriceConsumer...");

  const CopperPriceConsumerFactory = await ethers.getContractFactory("CopperPriceConsumer");
  const copperPriceConsumer = await CopperPriceConsumerFactory.deploy(
    OPERATOR_ADDRESS,
    DEPLOYMENT_CONFIG.jobId,
    ethers.parseUnits(DEPLOYMENT_CONFIG.linkFee, 18),
    LINK_ADDRESS
  ) as CopperPriceConsumer;
  await copperPriceConsumer.waitForDeployment();

  deployedContracts.copperPriceConsumer = await copperPriceConsumer.getAddress();
  console.log("✅ CopperPriceConsumer deployed at:", deployedContracts.copperPriceConsumer);

  return copperPriceConsumer;
}

/**
 * Deploy Epoch Manager contract
 */
async function deployEpochManager(): Promise<BaseContract> {
  console.log("\n🚀 Deploying EpochManager...");

  const EpochManagerFactory = await ethers.getContractFactory("EpochManager");
  const epochManager = await upgrades.deployProxy(EpochManagerFactory, [
    2592000
  ]);
  await epochManager.waitForDeployment();

  deployedContracts.epochManager = await epochManager.getAddress();
  console.log("✅ EpochManager deployed at:", deployedContracts.epochManager);

  return epochManager;
}

/**
 * Deploy Settlement Engine contract
 */
async function deploySettlementEngine(
  xcupAddress: string,
  treasuryAddress: string,
  epochManagerAddress: string,
  copperPriceConsumerAddress: string,
  systemFeeBps: number
): Promise<BaseContract> {
  console.log("\n🚀 Deploying SettlementEngine...");

  const SettlementEngineFactory = await ethers.getContractFactory("SettlementEngine");
  const settlementEngine = await upgrades.deployProxy(SettlementEngineFactory, [
    xcupAddress,
    treasuryAddress,
    epochManagerAddress,
    copperPriceConsumerAddress,
    USDC_ADDRESS,
    systemFeeBps
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
  epochManagerAddress: string
): Promise<Zapper> {
  console.log("\n🚀 Deploying Zapper...");

  const ZapperFactory = await ethers.getContractFactory("Zapper");
  const zapper = await upgrades.deployProxy(ZapperFactory, [
    cupTokenAddress,
    USDC_ADDRESS,
    xcupAddress,
    ROUTER_ADDRESS,
    copperPriceConsumerAddress,
    epochManagerAddress
  ]
  ) as unknown as Zapper;
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

  const verifications = [
    {
      address: deployedContracts.cupToken!,
      args: [],
      name: "CUPToken"
    },
    {
      address: deployedContracts.xcup!,
      args: [deployedContracts.cupToken!, "Alcum Copper Vault", "xCUP"],
      name: "xCUP"
    },
    {
      address: deployedContracts.copperPriceConsumer!,
      args: [
        OPERATOR_ADDRESS,
        DEPLOYMENT_CONFIG.jobId,
        ethers.parseUnits(DEPLOYMENT_CONFIG.linkFee, 18),
        LINK_ADDRESS
      ],
      name: "CopperPriceConsumer"
    },
    {
      address: deployedContracts.epochManager!,
      args: [2592000],
      name: "EpochManager"
    },
    {
      address: deployedContracts.settlementEngine!,
      args: [
        deployedContracts.xcup!,
        "0x4a59F710a496fEc0e939350eba8EE514Fa493D81", // This would be the treasury/owner address
        deployedContracts.epochManager!,
        "0x5F17C631B7c2d87BDCE210F21b71167457EA44F6",
        USDC_ADDRESS,
        600
      ],
      name: "SettlementEngine"
    },
    {
      address: deployedContracts.zapper!,
      args: [
        deployedContracts.cupToken!,
        USDC_ADDRESS,
        deployedContracts.xcup!,
        ROUTER_ADDRESS,
        "0x5F17C631B7c2d87BDCE210F21b71167457EA44F6",
        deployedContracts.epochManager!
      ],
      name: "Zapper"
    }
  ];

  for (const verification of verifications) {
    await verify(verification.address, verification.args, verification.name);
  }
}

/**
 * Utility function to verify a contract
 */
const delay = async (milliseconds: number) =>
  await new Promise((resolve) => setTimeout(resolve, milliseconds));

export const verify = async (address: string, args: any[], contractName?: string) => {
  const name = contractName ? ` (${contractName})` : '';
  console.log(`⏳ Waiting before verifying contract${name} at ${address}`);
  await delay(10000);

  console.log(`🔍 Verifying contract${name}...`);
  try {
    await run("verify:verify", {
      address,
      constructorArguments: args,
    });
    console.log(`✅ ${contractName || 'Contract'} verified successfully`);
  } catch (error: any) {
    if (error.message.toLowerCase().includes("already verified")) {
      console.log(`✅ ${contractName || 'Contract'} already verified`);
    } else {
      console.error(`❌ Error verifying ${contractName || 'contract'}:`, error.message);
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
  const fs = require('fs');
  const path = require('path');

  const addressesPath = path.join(__dirname, '..', 'deployed-addresses.json');
  fs.writeFileSync(addressesPath, JSON.stringify(deployedContracts, null, 2));
  console.log(`📁 Addresses saved to: ${addressesPath}`);
}

/**
 * Main deployment function
 */
async function main(): Promise<void> {
  try {
    const [owner] = await ethers.getSigners();
    console.log("🚀 Starting deployment with account:", owner.address);
    console.log("💰 Account balance:", ethers.formatEther(await ethers.provider.getBalance(owner.address)), "ETH");

    // Deploy contracts in correct order
    const cupToken = await deployCUPToken();
    const xcup = await deployXCUP(deployedContracts.cupToken!) as XCUP;
    // const copperPriceConsumer = await deployCopperPriceConsumer();
    const epochManager = await deployEpochManager() as EpochManager;

    // const SettlementEngineFactory = await ethers.getContractFactory("SettlementEngine");
    // const settlementEngine = await upgrades.deployProxy(SettlementEngineFactory, [
    //   deployedContracts.xcup!, // vault address (xcup)
    //   owner.address, // treasury address
    //   deployedContracts.epochManager!, // epoch manager address
    //   "0x5F17C631B7c2d87BDCE210F21b71167457EA44F6", // copper price consumer address
    //   USDC_ADDRESS, // USDC address
    //   600 // system fee bps
    // ]);
    // await settlementEngine.waitForDeployment();

    // console.log("SettlementEngine ", settlementEngine.target);

    // deployedContracts.settlementEngine = settlementEngine.target as string;

    const settlementEngine = await deploySettlementEngine(
      deployedContracts.xcup!,
      owner.address,
      deployedContracts.epochManager!,
      "0x5F17C631B7c2d87BDCE210F21b71167457EA44F6",
      600
    ) as SettlementEngine;

    const zapper = await deployZapper(
      deployedContracts.cupToken!,
      deployedContracts.xcup!,
      "0x5F17C631B7c2d87BDCE210F21b71167457EA44F6",
      deployedContracts.epochManager!
    );

    // Setup contracts
    await setupContracts({
      cupToken,
      settlementEngine,
      xcup,
    });

    // Verify contracts
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