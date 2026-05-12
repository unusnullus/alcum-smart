/* eslint-disable no-console */
import { run } from "hardhat";
import { config } from "dotenv";
import { ethers, upgrades } from "hardhat";
import { ContractFactory, BaseContract } from "ethers";
import * as fs from "fs";
import * as path from "path";
import {
    CUPToken,
    XCUP,
    CopperPriceConsumer,
    EpochManager,
    SettlementEngine,
    Zapper,
    RedeemEngine,
    HostAdapter,
    XCUPZapRouter,
    XCUPOraclePool,
    CommissionTransfer,
    GovernanceToken,
    TokenVesting,
    AlcumGovernor,
} from "../typechain-types";

import { OPERATOR_ADDRESS, ROUTER_ADDRESS, USDC_ADDRESS, LINK_ADDRESS, WETH_ADDRESS } from "../constants";

config();

// Deployment configuration
interface DeploymentConfig {
    jobId: string;
    linkFee: string;
    epochDuration: number; // in seconds
    systemFeeBps: number; // basis points (600 = 6%)
    redeemCommissionBps: number; // basis points (200 = 2%)
    treasuryAddress: string; // Treasury address for SettlementEngine
    commissionReceiver: string; // Commission receiver for CommissionTransfer
    // Governance
    governanceTokenName: string;
    governanceTokenSymbol: string;
    governorName: string;
    votingDelay: number; // blocks
    votingPeriod: number; // blocks
    proposalThreshold: string; // in token units (wei string)
    quorumNumerator: number; // basis points (400 = 4%)
    timelockDelay: number; // seconds
    // Vesting
    vestingCliff: number; // seconds
    vestingDuration: number; // seconds
    vestingSlicePeriod: number; // seconds
    vestingRevocable: boolean;
    vestingRatioBps: number; // basis points (10000 = 1:1)
}

const DEPLOYMENT_CONFIG: DeploymentConfig = {
    jobId: "0xaa9d5d553df8478fac9d7eac75aa9c4b00000000000000000000000000000000",
    linkFee: "0.1", // 0.1 LINK
    epochDuration: 600, // 10 minutes
    systemFeeBps: 600, // 6%
    redeemCommissionBps: 200, // 2%
    treasuryAddress: process.env.TREASURY_ADDRESS || "",
    commissionReceiver: process.env.COMMISSION_RECEIVER || "",
    // Governance
    governanceTokenName: "Alcum Governance Token",
    governanceTokenSymbol: "ALCGOV",
    governorName: "AlcumGovernor",
    votingDelay: 1, // 1 block
    votingPeriod: 50400, // ~1 week at 12s/block
    proposalThreshold: ethers.parseEther("1000").toString(), // 1000 tokens
    quorumNumerator: 4, // 4%
    timelockDelay: 86400, // 1 day
    // Vesting
    vestingCliff: 0, // 0 seconds (tokens available immediately)
    vestingDuration: 2592000, // 30 days
    vestingSlicePeriod: 1, // 1 second (linear)
    vestingRevocable: true,
    vestingRatioBps: 10000, // 1:1 ratio
};

// Contract addresses storage
interface DeployedContracts {
    // Libraries
    depositLib?: string;
    depositViewLib?: string;
    permitLib?: string;
    redeemLib?: string;
    redeemViewLib?: string;
    swapLib?: string;
    // Contracts
    cupToken?: string;
    xcup?: string;
    copperPriceConsumer?: string;
    epochManager?: string;
    settlementEngine?: string;
    zapper?: string;
    zapperSilo?: string; // Silo created inside Zapper
    redeemEngine?: string;
    redeemEngineSilo?: string; // Silo created inside RedeemEngine
    hostAdapter?: string;
    xcupZapRouter?: string;
    xcupOraclePool?: string;
    commissionTransfer?: string;
    // Governance & Vesting
    governanceToken?: string;
    timelockController?: string;
    alcumGovernor?: string;
    tokenVesting?: string;
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

function saveDeployedContracts(): void {
    const addressesPath = path.join(__dirname, "..", "deployed-addresses.json");
    fs.writeFileSync(addressesPath, JSON.stringify(deployedContracts, null, 2));
}

// Gas tracking
interface GasCost {
    name: string;
    gasUsed: bigint;
    gasPrice: bigint;
    costInEth: string;
}

const gasCosts: GasCost[] = [];
let totalGasCost = 0n;

/**
 * Track gas cost for a deployment transaction
 */
async function trackGasCost(name: string, deploymentTx: Promise<any>, signer: any): Promise<any> {
    const balanceBefore = await ethers.provider.getBalance(signer.address);

    const contract = await deploymentTx;
    const deploymentReceipt = await contract.deploymentTransaction()?.wait();

    if (deploymentReceipt) {
        const balanceAfter = await ethers.provider.getBalance(signer.address);
        const gasUsed = deploymentReceipt.gasUsed;
        const gasPrice = deploymentReceipt.gasPrice || 0n;
        const costInWei = balanceBefore - balanceAfter;
        const costInEth = ethers.formatEther(costInWei);

        gasCosts.push({
            name,
            gasUsed,
            gasPrice,
            costInEth,
        });

        totalGasCost += costInWei;

        console.log(`   ⛽ Gas used: ${gasUsed.toLocaleString()}`);
        console.log(`   💰 Cost: ${costInEth} ETH`);
    }

    return contract;
}

/**
 * Track gas cost for a transaction (for setup operations)
 */
async function trackTransactionGasCost(name: string, txPromise: Promise<any>, signer: any): Promise<any> {
    const balanceBefore = await ethers.provider.getBalance(signer.address);

    const tx = await txPromise;
    const receipt = await tx.wait();

    if (receipt) {
        const balanceAfter = await ethers.provider.getBalance(signer.address);
        const gasUsed = receipt.gasUsed;
        const gasPrice = receipt.gasPrice || 0n;
        const costInWei = balanceBefore - balanceAfter;
        const costInEth = ethers.formatEther(costInWei);

        gasCosts.push({
            name,
            gasUsed,
            gasPrice,
            costInEth,
        });

        totalGasCost += costInWei;

        console.log(`   ⛽ Gas used: ${gasUsed.toLocaleString()}`);
        console.log(`   💰 Cost: ${costInEth} ETH`);
    }

    return tx;
}

/**
 * Calculate total gas used across all transactions
 */
function calculateTotalGasUsed(): bigint {
    return gasCosts.reduce((total, cost) => total + cost.gasUsed, 0n);
}

/**
 * Estimate cost on mainnet with given gas price
 */
function estimateMainnetCost(
    gasPriceGwei: number,
    bufferPercent: number = 50,
): {
    totalGasUsed: bigint;
    estimatedCost: string;
    recommendedAmount: string;
} {
    const totalGasUsed = calculateTotalGasUsed();
    const gasPriceWei = ethers.parseUnits(gasPriceGwei.toString(), "gwei");
    const estimatedCostWei = totalGasUsed * gasPriceWei;
    const estimatedCostEth = ethers.formatEther(estimatedCostWei);

    // Add buffer for safety (e.g., 50% = 1.5x)
    const bufferMultiplier = 100n + BigInt(Math.floor(bufferPercent));
    const recommendedAmountWei = (estimatedCostWei * bufferMultiplier) / 100n;
    const recommendedAmountEth = ethers.formatEther(recommendedAmountWei);

    return {
        totalGasUsed,
        estimatedCost: estimatedCostEth,
        recommendedAmount: recommendedAmountEth,
    };
}

/**
 * Print gas cost summary with mainnet estimates
 */
async function printGasSummary(): Promise<void> {
    console.log("\n" + "=".repeat(60));
    console.log("⛽ GAS COST SUMMARY");
    console.log("=".repeat(60));

    if (gasCosts.length === 0) {
        console.log("No gas costs tracked.");
        return;
    }

    console.log("\n📊 Per Contract/Library:");
    gasCosts.forEach((cost, index) => {
        console.log(`\n${index + 1}. ${cost.name}`);
        console.log(`   Gas Used: ${cost.gasUsed.toLocaleString()}`);
        console.log(`   Gas Price: ${ethers.formatUnits(cost.gasPrice, "gwei")} gwei`);
        console.log(`   Cost: ${cost.costInEth} ETH`);
    });

    const totalGasUsed = calculateTotalGasUsed();
    console.log("\n" + "-".repeat(60));
    console.log(`💰 TOTAL COST (Fork): ${ethers.formatEther(totalGasCost)} ETH`);
    console.log(`⛽ TOTAL GAS USED: ${totalGasUsed.toLocaleString()}`);
    console.log("=".repeat(60));

    // Estimate for mainnet with different gas prices
    console.log("\n" + "=".repeat(60));
    console.log("🌐 MAINNET COST ESTIMATES");
    console.log("=".repeat(60));

    // Try to get current mainnet gas price
    let currentMainnetGasPrice = 30; // Default estimate in gwei
    try {
        // Create a provider for mainnet if RPC_URL is set
        if (process.env.RPC_URL) {
            const mainnetProvider = new ethers.JsonRpcProvider(process.env.RPC_URL);
            const feeData = await mainnetProvider.getFeeData();
            if (feeData.gasPrice) {
                currentMainnetGasPrice = parseFloat(ethers.formatUnits(feeData.gasPrice, "gwei"));
                console.log(`\n📡 Current Mainnet Gas Price: ${currentMainnetGasPrice.toFixed(2)} gwei`);
            }
        }
    } catch (error) {
        console.log(`\n⚠️  Could not fetch mainnet gas price, using estimates`);
    }

    // Calculate estimates for different gas price scenarios
    const scenarios = [
        { name: "Low (20 gwei)", price: 20 },
        { name: "Medium (30 gwei)", price: 30 },
        { name: "High (50 gwei)", price: 50 },
        { name: "Very High (100 gwei)", price: 100 },
        { name: `Current (${currentMainnetGasPrice.toFixed(2)} gwei)`, price: currentMainnetGasPrice },
    ];

    console.log("\n📊 Cost Estimates at Different Gas Prices:");
    scenarios.forEach((scenario) => {
        const estimate = estimateMainnetCost(scenario.price, 50);
        console.log(`\n   ${scenario.name}:`);
        console.log(`      Estimated Cost: ${estimate.estimatedCost} ETH`);
        console.log(`      Recommended (with 50% buffer): ${estimate.recommendedAmount} ETH`);
    });

    // Best recommendation
    const bestEstimate = estimateMainnetCost(currentMainnetGasPrice, 50);
    console.log("\n" + "=".repeat(60));
    console.log("💡 RECOMMENDATION FOR MAINNET DEPLOYMENT:");
    console.log("=".repeat(60));
    console.log(`   Total Gas Needed: ${totalGasUsed.toLocaleString()}`);
    console.log(`   Estimated Cost: ${bestEstimate.estimatedCost} ETH (at ${currentMainnetGasPrice.toFixed(2)} gwei)`);
    console.log(`   ⚠️  Recommended Amount: ${bestEstimate.recommendedAmount} ETH`);
    console.log(`      (Includes 50% safety buffer for gas price fluctuations)`);
    console.log("\n   💰 To be safe, prepare at least:");
    const highEstimate = estimateMainnetCost(100, 50);
    console.log(`      ${highEstimate.recommendedAmount} ETH (for high gas price scenario)`);
    console.log("=".repeat(60));
}

/**
 * Deploy all libraries
 */
async function deployLibraries(signer: any): Promise<void> {
    console.log("\n🚀 Deploying all libraries...");

    // DepositLib
    console.log("   Deploying DepositLib...");
    const DepositLibFactory = await ethers.getContractFactory("DepositLib");
    const depositLib = await trackGasCost("DepositLib", DepositLibFactory.deploy(), signer);
    await depositLib.waitForDeployment();
    deployedContracts.depositLib = await depositLib.getAddress();
    console.log("   ✅ DepositLib deployed at:", deployedContracts.depositLib);

    // DepositViewLib
    console.log("   Deploying DepositViewLib...");
    const DepositViewLibFactory = await ethers.getContractFactory("DepositViewLib");
    const depositViewLib = await trackGasCost("DepositViewLib", DepositViewLibFactory.deploy(), signer);
    await depositViewLib.waitForDeployment();
    deployedContracts.depositViewLib = await depositViewLib.getAddress();
    console.log("   ✅ DepositViewLib deployed at:", deployedContracts.depositViewLib);

    // PermitLib
    console.log("   Deploying PermitLib...");
    const PermitLibFactory = await ethers.getContractFactory("PermitLib");
    const permitLib = await trackGasCost("PermitLib", PermitLibFactory.deploy(), signer);
    await permitLib.waitForDeployment();
    deployedContracts.permitLib = await permitLib.getAddress();
    console.log("   ✅ PermitLib deployed at:", deployedContracts.permitLib);

    // RedeemLib
    console.log("   Deploying RedeemLib...");
    const RedeemLibFactory = await ethers.getContractFactory("RedeemLib");
    const redeemLib = await trackGasCost("RedeemLib", RedeemLibFactory.deploy(), signer);
    await redeemLib.waitForDeployment();
    deployedContracts.redeemLib = await redeemLib.getAddress();
    console.log("   ✅ RedeemLib deployed at:", deployedContracts.redeemLib);

    // RedeemViewLib
    console.log("   Deploying RedeemViewLib...");
    const RedeemViewLibFactory = await ethers.getContractFactory("RedeemViewLib");
    const redeemViewLib = await trackGasCost("RedeemViewLib", RedeemViewLibFactory.deploy(), signer);
    await redeemViewLib.waitForDeployment();
    deployedContracts.redeemViewLib = await redeemViewLib.getAddress();
    console.log("   ✅ RedeemViewLib deployed at:", deployedContracts.redeemViewLib);

    // SwapLib
    console.log("   Deploying SwapLib...");
    const SwapLibFactory = await ethers.getContractFactory("SwapLib");
    const swapLib = await trackGasCost("SwapLib", SwapLibFactory.deploy(), signer);
    await swapLib.waitForDeployment();
    deployedContracts.swapLib = await swapLib.getAddress();
    console.log("   ✅ SwapLib deployed at:", deployedContracts.swapLib);
}

/**
 * Deploy CUP Token contract (upgradeable)
 */
async function deployCUPToken(signer: any): Promise<CUPToken> {
    console.log("\n🚀 Deploying CUPToken (upgradeable)...");

    const balanceBefore = await ethers.provider.getBalance(signer.address);
    const CUPTokenFactory = await ethers.getContractFactory("CUPToken");
    const cupToken = await upgrades.deployProxy(CUPTokenFactory, []);
    await cupToken.waitForDeployment();

    const deploymentTx = await cupToken.deploymentTransaction();
    if (deploymentTx) {
        const receipt = await deploymentTx.wait();
        if (receipt) {
            const balanceAfter = await ethers.provider.getBalance(signer.address);
            const costInWei = balanceBefore - balanceAfter;
            const costInEth = ethers.formatEther(costInWei);
            totalGasCost += costInWei;
            gasCosts.push({
                name: "CUPToken",
                gasUsed: receipt.gasUsed,
                gasPrice: receipt.gasPrice || 0n,
                costInEth,
            });
            console.log(`   ⛽ Gas used: ${receipt.gasUsed.toLocaleString()}`);
            console.log(`   💰 Cost: ${costInEth} ETH`);
        }
    }

    deployedContracts.cupToken = await cupToken.getAddress();
    console.log("✅ CUPToken deployed at:", deployedContracts.cupToken);

    return cupToken as unknown as CUPToken;
}

/**
 * Deploy Epoch Manager contract (upgradeable)
 */
async function deployEpochManager(signer: any): Promise<EpochManager> {
    console.log("\n🚀 Deploying EpochManager (upgradeable)...");

    const balanceBefore = await ethers.provider.getBalance(signer.address);
    const EpochManagerFactory = await ethers.getContractFactory("EpochManager");
    const epochManager = await upgrades.deployProxy(EpochManagerFactory, [DEPLOYMENT_CONFIG.epochDuration]);
    await epochManager.waitForDeployment();

    const deploymentTx = await epochManager.deploymentTransaction();
    if (deploymentTx) {
        const receipt = await deploymentTx.wait();
        if (receipt) {
            const balanceAfter = await ethers.provider.getBalance(signer.address);
            const costInWei = balanceBefore - balanceAfter;
            const costInEth = ethers.formatEther(costInWei);
            totalGasCost += costInWei;
            gasCosts.push({
                name: "EpochManager",
                gasUsed: receipt.gasUsed,
                gasPrice: receipt.gasPrice || 0n,
                costInEth,
            });
            console.log(`   ⛽ Gas used: ${receipt.gasUsed.toLocaleString()}`);
            console.log(`   💰 Cost: ${costInEth} ETH`);
        }
    }

    deployedContracts.epochManager = await epochManager.getAddress();
    console.log("✅ EpochManager deployed at:", deployedContracts.epochManager);

    return epochManager as unknown as EpochManager;
}

/**
 * Deploy Copper Price Consumer contract (NOT upgradeable)
 */
async function deployCopperPriceConsumer(signer: any): Promise<CopperPriceConsumer> {
    console.log("\n🚀 Deploying CopperPriceConsumer...");

    const CopperPriceConsumerFactory = await ethers.getContractFactory("CopperPriceConsumer");
    const copperPriceConsumer = await trackGasCost(
        "CopperPriceConsumer",
        CopperPriceConsumerFactory.deploy(
            OPERATOR_ADDRESS,
            DEPLOYMENT_CONFIG.jobId,
            ethers.parseUnits(DEPLOYMENT_CONFIG.linkFee, 18),
            LINK_ADDRESS,
        ),
        signer,
    );
    await copperPriceConsumer.waitForDeployment();

    deployedContracts.copperPriceConsumer = await copperPriceConsumer.getAddress();
    console.log("✅ CopperPriceConsumer deployed at:", deployedContracts.copperPriceConsumer);

    return copperPriceConsumer as CopperPriceConsumer;
}

/**
 * Deploy xCUP Vault contract (upgradeable)
 */
async function deployXCUP(cupTokenAddress: string, copperPriceConsumerAddress: string, signer: any): Promise<XCUP> {
    console.log("\n🚀 Deploying xCUP (upgradeable)...");

    const balanceBefore = await ethers.provider.getBalance(signer.address);
    const XCUPFactory = await ethers.getContractFactory("xCUP");
    const xcup = await upgrades.deployProxy(XCUPFactory, [
        cupTokenAddress,
        "Alcum Copper Vault",
        "xCUP",
        copperPriceConsumerAddress,
        ROUTER_ADDRESS,
        USDC_ADDRESS,
        WETH_ADDRESS,
    ]);
    await xcup.waitForDeployment();

    const deploymentTx = await xcup.deploymentTransaction();
    if (deploymentTx) {
        const receipt = await deploymentTx.wait();
        if (receipt) {
            const balanceAfter = await ethers.provider.getBalance(signer.address);
            const costInWei = balanceBefore - balanceAfter;
            const costInEth = ethers.formatEther(costInWei);
            totalGasCost += costInWei;
            gasCosts.push({
                name: "xCUP",
                gasUsed: receipt.gasUsed,
                gasPrice: receipt.gasPrice || 0n,
                costInEth,
            });
            console.log(`   ⛽ Gas used: ${receipt.gasUsed.toLocaleString()}`);
            console.log(`   💰 Cost: ${costInEth} ETH`);
        }
    }

    deployedContracts.xcup = await xcup.getAddress();
    console.log("✅ xCUP deployed at:", deployedContracts.xcup);

    return xcup as unknown as XCUP;
}

/**
 * Deploy XCUPOraclePool contract (upgradeable)
 */
async function deployXCUPOraclePool(xcupAddress: string, signer: any): Promise<XCUPOraclePool> {
    console.log("\n🚀 Deploying XCUPOraclePool (upgradeable)...");

    const balanceBefore = await ethers.provider.getBalance(signer.address);
    const XCUPOraclePoolFactory = await ethers.getContractFactory("XCUPOraclePool");
    const xcupOraclePool = await upgrades.deployProxy(XCUPOraclePoolFactory, [xcupAddress, USDC_ADDRESS]);
    await xcupOraclePool.waitForDeployment();

    const deploymentTx = await xcupOraclePool.deploymentTransaction();
    if (deploymentTx) {
        const receipt = await deploymentTx.wait();
        if (receipt) {
            const balanceAfter = await ethers.provider.getBalance(signer.address);
            const costInWei = balanceBefore - balanceAfter;
            const costInEth = ethers.formatEther(costInWei);
            totalGasCost += costInWei;
            gasCosts.push({
                name: "XCUPOraclePool",
                gasUsed: receipt.gasUsed,
                gasPrice: receipt.gasPrice || 0n,
                costInEth,
            });
            console.log(`   ⛽ Gas used: ${receipt.gasUsed.toLocaleString()}`);
            console.log(`   💰 Cost: ${costInEth} ETH`);
        }
    }

    deployedContracts.xcupOraclePool = await xcupOraclePool.getAddress();
    console.log("✅ XCUPOraclePool deployed at:", deployedContracts.xcupOraclePool);

    return xcupOraclePool as unknown as XCUPOraclePool;
}

/**
 * Deploy Zapper contract (upgradeable)
 */
async function deployZapper(
    cupTokenAddress: string,
    xcupAddress: string,
    copperPriceConsumerAddress: string,
    epochManagerAddress: string,
    signer: any,
): Promise<Zapper> {
    console.log("\n🚀 Deploying Zapper (upgradeable)...");

    const balanceBefore = await ethers.provider.getBalance(signer.address);
    const ZapperFactory = await ethers.getContractFactory("Zapper", {
        libraries: {
            DepositLib: deployedContracts.depositLib!,
            DepositViewLib: deployedContracts.depositViewLib!,
            PermitLib: deployedContracts.permitLib!,
            SwapLib: deployedContracts.swapLib!,
        },
    });
    const zapper = (await upgrades.deployProxy(
        ZapperFactory,
        [cupTokenAddress, USDC_ADDRESS, xcupAddress, ROUTER_ADDRESS, copperPriceConsumerAddress, epochManagerAddress],
        {
            unsafeAllowLinkedLibraries: true,
        },
    )) as unknown as Zapper;
    await zapper.waitForDeployment();

    const deploymentTx = await zapper.deploymentTransaction();
    if (deploymentTx) {
        const receipt = await deploymentTx.wait();
        if (receipt) {
            const balanceAfter = await ethers.provider.getBalance(signer.address);
            const costInWei = balanceBefore - balanceAfter;
            const costInEth = ethers.formatEther(costInWei);
            totalGasCost += costInWei;
            gasCosts.push({
                name: "Zapper",
                gasUsed: receipt.gasUsed,
                gasPrice: receipt.gasPrice || 0n,
                costInEth,
            });
            console.log(`   ⛽ Gas used: ${receipt.gasUsed.toLocaleString()}`);
            console.log(`   💰 Cost: ${costInEth} ETH`);
        }
    }

    deployedContracts.zapper = await zapper.getAddress();
    console.log("✅ Zapper deployed at:", deployedContracts.zapper);

    // Get Silo address created inside Zapper
    deployedContracts.zapperSilo = await zapper.silo();
    console.log("✅ Zapper Silo created at:", deployedContracts.zapperSilo);

    return zapper;
}

/**
 * Deploy RedeemEngine contract (upgradeable)
 */
async function deployRedeemEngine(
    cupTokenAddress: string,
    xcupAddress: string,
    copperPriceConsumerAddress: string,
    zapperAddress: string,
    signer: any,
): Promise<RedeemEngine> {
    console.log("\n🚀 Deploying RedeemEngine (upgradeable)...");

    const balanceBefore = await ethers.provider.getBalance(signer.address);
    const RedeemEngineFactory = await ethers.getContractFactory("RedeemEngine", {
        libraries: {
            RedeemLib: deployedContracts.redeemLib!,
            RedeemViewLib: deployedContracts.redeemViewLib!,
        },
    });
    const redeemEngine = (await upgrades.deployProxy(
        RedeemEngineFactory,
        [
            cupTokenAddress,
            USDC_ADDRESS,
            xcupAddress,
            copperPriceConsumerAddress,
            zapperAddress,
            DEPLOYMENT_CONFIG.redeemCommissionBps,
        ],
        {
            unsafeAllowLinkedLibraries: true,
        },
    )) as unknown as RedeemEngine;
    await redeemEngine.waitForDeployment();

    const deploymentTx = await redeemEngine.deploymentTransaction();
    if (deploymentTx) {
        const receipt = await deploymentTx.wait();
        if (receipt) {
            const balanceAfter = await ethers.provider.getBalance(signer.address);
            const costInWei = balanceBefore - balanceAfter;
            const costInEth = ethers.formatEther(costInWei);
            totalGasCost += costInWei;
            gasCosts.push({
                name: "RedeemEngine",
                gasUsed: receipt.gasUsed,
                gasPrice: receipt.gasPrice || 0n,
                costInEth,
            });
            console.log(`   ⛽ Gas used: ${receipt.gasUsed.toLocaleString()}`);
            console.log(`   💰 Cost: ${costInEth} ETH`);
        }
    }

    deployedContracts.redeemEngine = await redeemEngine.getAddress();
    console.log("✅ RedeemEngine deployed at:", deployedContracts.redeemEngine);

    // Get Silo address created inside RedeemEngine
    deployedContracts.redeemEngineSilo = await redeemEngine.redeemSilo();
    console.log("✅ RedeemEngine Silo created at:", deployedContracts.redeemEngineSilo);

    return redeemEngine;
}

/**
 * Deploy HostAdapter contract (upgradeable)
 */
async function deployHostAdapter(zapperAddress: string, signer: any): Promise<HostAdapter> {
    console.log("\n🚀 Deploying HostAdapter (upgradeable)...");

    const balanceBefore = await ethers.provider.getBalance(signer.address);
    // HostAdapter only imports DepositLib for types, doesn't use it as a library
    const HostAdapterFactory = await ethers.getContractFactory("HostAdapter");
    const hostAdapter = (await upgrades.deployProxy(HostAdapterFactory, [zapperAddress])) as unknown as HostAdapter;
    await hostAdapter.waitForDeployment();

    const deploymentTx = await hostAdapter.deploymentTransaction();
    if (deploymentTx) {
        const receipt = await deploymentTx.wait();
        if (receipt) {
            const balanceAfter = await ethers.provider.getBalance(signer.address);
            const costInWei = balanceBefore - balanceAfter;
            const costInEth = ethers.formatEther(costInWei);
            totalGasCost += costInWei;
            gasCosts.push({
                name: "HostAdapter",
                gasUsed: receipt.gasUsed,
                gasPrice: receipt.gasPrice || 0n,
                costInEth,
            });
            console.log(`   ⛽ Gas used: ${receipt.gasUsed.toLocaleString()}`);
            console.log(`   💰 Cost: ${costInEth} ETH`);
        }
    }

    deployedContracts.hostAdapter = await hostAdapter.getAddress();
    console.log("✅ HostAdapter deployed at:", deployedContracts.hostAdapter);

    return hostAdapter;
}

/**
 * Deploy Settlement Engine contract (upgradeable)
 */
async function deploySettlementEngine(
    xcupAddress: string,
    treasuryAddress: string,
    zapperAddress: string,
    redeemSiloAddress: string,
    epochManagerAddress: string,
    copperPriceConsumerAddress: string,
    systemFeeBps: number,
    signer: any,
): Promise<SettlementEngine> {
    console.log("\n🚀 Deploying SettlementEngine (upgradeable)...");

    const balanceBefore = await ethers.provider.getBalance(signer.address);
    const SettlementEngineFactory = await ethers.getContractFactory("SettlementEngine");
    const settlementEngine = await upgrades.deployProxy(SettlementEngineFactory, [
        xcupAddress,
        treasuryAddress,
        zapperAddress,
        redeemSiloAddress,
        epochManagerAddress,
        copperPriceConsumerAddress,
        USDC_ADDRESS,
        systemFeeBps,
    ]);
    await settlementEngine.waitForDeployment();

    const deploymentTx = await settlementEngine.deploymentTransaction();
    if (deploymentTx) {
        const receipt = await deploymentTx.wait();
        if (receipt) {
            const balanceAfter = await ethers.provider.getBalance(signer.address);
            const costInWei = balanceBefore - balanceAfter;
            const costInEth = ethers.formatEther(costInWei);
            totalGasCost += costInWei;
            gasCosts.push({
                name: "SettlementEngine",
                gasUsed: receipt.gasUsed,
                gasPrice: receipt.gasPrice || 0n,
                costInEth,
            });
            console.log(`   ⛽ Gas used: ${receipt.gasUsed.toLocaleString()}`);
            console.log(`   💰 Cost: ${costInEth} ETH`);
        }
    }

    deployedContracts.settlementEngine = await settlementEngine.getAddress();
    console.log("✅ SettlementEngine deployed at:", deployedContracts.settlementEngine);

    return settlementEngine as unknown as SettlementEngine;
}

/**
 * Deploy XCUPZapRouter contract (upgradeable)
 */
async function deployXCUPZapRouter(
    xcupOraclePoolAddress: string,
    xcupAddress: string,
    signer: any,
): Promise<XCUPZapRouter> {
    console.log("\n🚀 Deploying XCUPZapRouter (upgradeable)...");

    const balanceBefore = await ethers.provider.getBalance(signer.address);
    const XCUPZapRouterFactory = await ethers.getContractFactory("XCUPZapRouter");
    const xcupZapRouter = (await upgrades.deployProxy(XCUPZapRouterFactory, [
        ROUTER_ADDRESS,
        xcupOraclePoolAddress,
        xcupAddress,
        USDC_ADDRESS,
    ])) as unknown as XCUPZapRouter;
    await xcupZapRouter.waitForDeployment();

    const deploymentTx = await xcupZapRouter.deploymentTransaction();
    if (deploymentTx) {
        const receipt = await deploymentTx.wait();
        if (receipt) {
            const balanceAfter = await ethers.provider.getBalance(signer.address);
            const costInWei = balanceBefore - balanceAfter;
            const costInEth = ethers.formatEther(costInWei);
            totalGasCost += costInWei;
            gasCosts.push({
                name: "XCUPZapRouter",
                gasUsed: receipt.gasUsed,
                gasPrice: receipt.gasPrice || 0n,
                costInEth,
            });
            console.log(`   ⛽ Gas used: ${receipt.gasUsed.toLocaleString()}`);
            console.log(`   💰 Cost: ${costInEth} ETH`);
        }
    }

    deployedContracts.xcupZapRouter = await xcupZapRouter.getAddress();
    console.log("✅ XCUPZapRouter deployed at:", deployedContracts.xcupZapRouter);

    return xcupZapRouter;
}

/**
 * Deploy CommissionTransfer contract (upgradeable)
 */
async function deployCommissionTransfer(
    commissionReceiver: string,
    xcupOraclePoolAddress: string,
    signer: any,
): Promise<CommissionTransfer> {
    console.log("\n🚀 Deploying CommissionTransfer (upgradeable)...");

    const balanceBefore = await ethers.provider.getBalance(signer.address);
    const CommissionTransferFactory = await ethers.getContractFactory("CommissionTransfer");
    const commissionTransfer = (await upgrades.deployProxy(CommissionTransferFactory, [
        commissionReceiver,
    ])) as unknown as CommissionTransfer;
    await commissionTransfer.waitForDeployment();

    const deploymentTx = await commissionTransfer.deploymentTransaction();
    if (deploymentTx) {
        const receipt = await deploymentTx.wait();
        if (receipt) {
            const balanceAfter = await ethers.provider.getBalance(signer.address);
            const costInWei = balanceBefore - balanceAfter;
            const costInEth = ethers.formatEther(costInWei);
            totalGasCost += costInWei;
            gasCosts.push({
                name: "CommissionTransfer",
                gasUsed: receipt.gasUsed,
                gasPrice: receipt.gasPrice || 0n,
                costInEth,
            });
            console.log(`   ⛽ Gas used: ${receipt.gasUsed.toLocaleString()}`);
            console.log(`   💰 Cost: ${costInEth} ETH`);
        }
    }

    deployedContracts.commissionTransfer = await commissionTransfer.getAddress();
    console.log("✅ CommissionTransfer deployed at:", deployedContracts.commissionTransfer);

    return commissionTransfer;
}

/**
 * Deploy GovernanceToken (regular contract, not upgradeable)
 */
async function deployGovernanceToken(initialAdmin: string, signer: any): Promise<GovernanceToken> {
    console.log("\n🚀 Deploying GovernanceToken...");

    const GovernanceTokenFactory = await ethers.getContractFactory("GovernanceToken");
    const governanceToken = await trackGasCost(
        "GovernanceToken",
        GovernanceTokenFactory.deploy(
            DEPLOYMENT_CONFIG.governanceTokenName,
            DEPLOYMENT_CONFIG.governanceTokenSymbol,
            initialAdmin,
        ),
        signer,
    );
    await governanceToken.waitForDeployment();

    deployedContracts.governanceToken = await governanceToken.getAddress();
    console.log("✅ GovernanceToken deployed at:", deployedContracts.governanceToken);

    return governanceToken as GovernanceToken;
}

/**
 * Deploy TimelockController (regular OZ contract)
 */
async function deployTimelockController(admin: string, signer: any): Promise<any> {
    console.log("\n🚀 Deploying TimelockController...");

    const TimelockControllerFactory = await ethers.getContractFactory("TimelockController", {
        libraries: {},
    });
    const timelockController = await trackGasCost(
        "TimelockController",
        TimelockControllerFactory.deploy(
            DEPLOYMENT_CONFIG.timelockDelay,
            [], // proposers (will be set after governor deploy)
            [ethers.ZeroAddress], // executors (anyone can execute)
            admin,
        ),
        signer,
    );
    await timelockController.waitForDeployment();

    deployedContracts.timelockController = await timelockController.getAddress();
    console.log("✅ TimelockController deployed at:", deployedContracts.timelockController);

    return timelockController;
}

/**
 * Deploy AlcumGovernor (UUPS upgradeable proxy)
 */
async function deployAlcumGovernor(
    governanceTokenAddress: string,
    timelockControllerAddress: string,
    initialOwner: string,
    signer: any,
): Promise<AlcumGovernor> {
    console.log("\n🚀 Deploying AlcumGovernor (UUPS upgradeable)...");

    const balanceBefore = await ethers.provider.getBalance(signer.address);
    const AlcumGovernorFactory = await ethers.getContractFactory("AlcumGovernor");
    const alcumGovernor = await upgrades.deployProxy(
        AlcumGovernorFactory,
        [
            governanceTokenAddress,
            timelockControllerAddress,
            DEPLOYMENT_CONFIG.governorName,
            DEPLOYMENT_CONFIG.votingDelay,
            DEPLOYMENT_CONFIG.votingPeriod,
            BigInt(DEPLOYMENT_CONFIG.proposalThreshold),
            DEPLOYMENT_CONFIG.quorumNumerator,
            initialOwner,
        ],
        { kind: "uups" },
    );
    await alcumGovernor.waitForDeployment();

    const deploymentTx = await alcumGovernor.deploymentTransaction();
    if (deploymentTx) {
        const receipt = await deploymentTx.wait();
        if (receipt) {
            const balanceAfter = await ethers.provider.getBalance(signer.address);
            const costInWei = balanceBefore - balanceAfter;
            const costInEth = ethers.formatEther(costInWei);
            totalGasCost += costInWei;
            gasCosts.push({
                name: "AlcumGovernor",
                gasUsed: receipt.gasUsed,
                gasPrice: receipt.gasPrice || 0n,
                costInEth,
            });
            console.log(`   ⛽ Gas used: ${receipt.gasUsed.toLocaleString()}`);
            console.log(`   💰 Cost: ${costInEth} ETH`);
        }
    }

    deployedContracts.alcumGovernor = await alcumGovernor.getAddress();
    console.log("✅ AlcumGovernor deployed at:", deployedContracts.alcumGovernor);

    return alcumGovernor as unknown as AlcumGovernor;
}

/**
 * Deploy TokenVesting (regular contract, not upgradeable)
 */
async function deployTokenVesting(governanceTokenAddress: string, signer: any): Promise<TokenVesting> {
    console.log("\n🚀 Deploying TokenVesting...");

    const TokenVestingFactory = await ethers.getContractFactory("TokenVesting");
    const tokenVesting = await trackGasCost("TokenVesting", TokenVestingFactory.deploy(governanceTokenAddress), signer);
    await tokenVesting.waitForDeployment();

    deployedContracts.tokenVesting = await tokenVesting.getAddress();
    console.log("✅ TokenVesting deployed at:", deployedContracts.tokenVesting);

    return tokenVesting as TokenVesting;
}

/**
 * Setup contract permissions and initial configuration
 */
async function setupContracts(
    contracts: {
        cupToken: CUPToken;
        settlementEngine: SettlementEngine;
        xcup: XCUP;
        zapper: Zapper;
        governanceToken: GovernanceToken;
        tokenVesting: TokenVesting;
        timelockController: any;
    },
    signer: any,
): Promise<void> {
    console.log("\n⚙️ Setting up contract permissions...");

    // Grant MINTER_ROLE to SettlementEngine on CUPToken
    const CUP_MINTER_ROLE = await contracts.cupToken.MINTER_ROLE();
    const tx1 = await trackTransactionGasCost(
        "Setup: Grant CUP MINTER_ROLE to SettlementEngine",
        contracts.cupToken.grantRole(CUP_MINTER_ROLE, deployedContracts.settlementEngine!),
        signer,
    );
    await tx1.wait();
    console.log("✅ Granted MINTER_ROLE on CUPToken to SettlementEngine");

    // Grant MINTER_ROLE to Zapper on CUPToken (needed for claimDeposit CUP minting)
    const tx1b = await trackTransactionGasCost(
        "Setup: Grant CUP MINTER_ROLE to Zapper",
        contracts.cupToken.grantRole(CUP_MINTER_ROLE, deployedContracts.zapper!),
        signer,
    );
    await tx1b.wait();
    console.log("✅ Granted MINTER_ROLE on CUPToken to Zapper");

    // Grant REDEEMER_ROLE to Zapper on xCUP
    const REDEEMER_ROLE = await contracts.xcup.REDEEMER_ROLE();
    const tx2 = await trackTransactionGasCost(
        "Setup: Grant REDEEMER_ROLE to Zapper",
        contracts.xcup.grantRole(REDEEMER_ROLE, deployedContracts.zapper!),
        signer,
    );
    await tx2.wait();
    console.log("✅ Granted REDEEMER_ROLE on xCUP to Zapper");

    // Grant MINTER_ROLE to Zapper on GovernanceToken (for auto-vesting minting)
    const GOV_MINTER_ROLE = await contracts.governanceToken.MINTER_ROLE();
    const tx3 = await trackTransactionGasCost(
        "Setup: Grant GOV MINTER_ROLE to Zapper",
        contracts.governanceToken.grantRole(GOV_MINTER_ROLE, deployedContracts.zapper!),
        signer,
    );
    await tx3.wait();
    console.log("✅ Granted MINTER_ROLE on GovernanceToken to Zapper");

    // Grant vestingCreator role to Zapper on TokenVesting
    const tx4 = await trackTransactionGasCost(
        "Setup: Grant vestingCreator to Zapper",
        contracts.tokenVesting.grantVestingCreatorRole(deployedContracts.zapper!),
        signer,
    );
    await tx4.wait();
    console.log("✅ Granted vestingCreator role on TokenVesting to Zapper");

    // Grant VAULT_CURATOR_ROLE to deployer on Zapper (needed for setVestingConfig and operations)
    const VAULT_CURATOR_ROLE = await contracts.zapper.VAULT_CURATOR_ROLE();
    const tx4b = await trackTransactionGasCost(
        "Setup: Grant VAULT_CURATOR_ROLE to deployer",
        contracts.zapper.grantRole(VAULT_CURATOR_ROLE, signer.address),
        signer,
    );
    await tx4b.wait();
    console.log("✅ Granted VAULT_CURATOR_ROLE on Zapper to deployer");

    // Configure Zapper vesting integration
    const tx5 = await trackTransactionGasCost(
        "Setup: Configure Zapper vesting",
        contracts.zapper.setVestingConfig(
            deployedContracts.tokenVesting!,
            deployedContracts.governanceToken!,
            DEPLOYMENT_CONFIG.vestingCliff,
            DEPLOYMENT_CONFIG.vestingDuration,
            DEPLOYMENT_CONFIG.vestingSlicePeriod,
            DEPLOYMENT_CONFIG.vestingRevocable,
            DEPLOYMENT_CONFIG.vestingRatioBps,
        ),
        signer,
    );
    await tx5.wait();
    console.log("✅ Configured Zapper vesting integration");

    // Grant PROPOSER_ROLE to AlcumGovernor on TimelockController
    const PROPOSER_ROLE = await contracts.timelockController.PROPOSER_ROLE();
    const tx6 = await trackTransactionGasCost(
        "Setup: Grant PROPOSER_ROLE to AlcumGovernor",
        contracts.timelockController.grantRole(PROPOSER_ROLE, deployedContracts.alcumGovernor!),
        signer,
    );
    await tx6.wait();
    console.log("✅ Granted PROPOSER_ROLE on TimelockController to AlcumGovernor");

    console.log("✅ Contract setup completed");
}

/**
 * Configure CommissionTransfer
 */
async function configureCommissionTransfer(
    commissionTransfer: CommissionTransfer,
    xcupOraclePoolAddress: string,
    signer: any,
): Promise<void> {
    console.log("\n⚙️ Configuring CommissionTransfer...");

    // Set swap config
    const usdtAddress = process.env.USDT_ADDRESS || ""; // Should be set in .env if needed
    if (usdtAddress) {
        const tx1 = await trackTransactionGasCost(
            "Setup: CommissionTransfer.setSwapConfig",
            commissionTransfer.setSwapConfig(ROUTER_ADDRESS, usdtAddress, deployedContracts.xcup!, USDC_ADDRESS),
            signer,
        );
        await tx1.wait();
        console.log("✅ Set swap config for CommissionTransfer");
    }

    // Set XCUP pool
    const tx2 = await trackTransactionGasCost(
        "Setup: CommissionTransfer.setXCUPPool",
        commissionTransfer.setXCUPPool(xcupOraclePoolAddress),
        signer,
    );
    await tx2.wait();
    console.log("✅ Set XCUP pool for CommissionTransfer");
}

/**
 * Print deployment summary
 */
function printDeploymentSummary(): void {
    console.log("\n" + "=".repeat(60));
    console.log("🎉 DEPLOYMENT COMPLETED SUCCESSFULLY!");
    console.log("=".repeat(60));
    console.log("📋 Contract Addresses:");
    console.log("\n📚 Libraries:");
    console.log(`   DepositLib:         https://sepolia.etherscan.io/address/${deployedContracts.depositLib}`);
    console.log(`   DepositViewLib:     https://sepolia.etherscan.io/address/${deployedContracts.depositViewLib}`);
    console.log(`   PermitLib:          https://sepolia.etherscan.io/address/${deployedContracts.permitLib}`);
    console.log(`   RedeemLib:          https://sepolia.etherscan.io/address/${deployedContracts.redeemLib}`);
    console.log(`   RedeemViewLib:      https://sepolia.etherscan.io/address/${deployedContracts.redeemViewLib}`);
    console.log(`   SwapLib:            https://sepolia.etherscan.io/address/${deployedContracts.swapLib}`);
    console.log("\n📦 Contracts:");
    console.log(`   CUPToken:           https://sepolia.etherscan.io/address/${deployedContracts.cupToken}`);
    console.log(`   xCUP:               https://sepolia.etherscan.io/address/${deployedContracts.xcup}`);
    console.log(
        `   CopperPriceConsumer: https://sepolia.etherscan.io/address/${deployedContracts.copperPriceConsumer}`,
    );
    console.log(`   EpochManager:       https://sepolia.etherscan.io/address/${deployedContracts.epochManager}`);
    console.log(`   SettlementEngine:   https://sepolia.etherscan.io/address/${deployedContracts.settlementEngine}`);
    console.log(`   Zapper:             https://sepolia.etherscan.io/address/${deployedContracts.zapper}`);
    console.log(`   Zapper Silo:        https://sepolia.etherscan.io/address/${deployedContracts.zapperSilo}`);
    console.log(`   RedeemEngine:       https://sepolia.etherscan.io/address/${deployedContracts.redeemEngine}`);
    console.log(`   RedeemEngine Silo:  https://sepolia.etherscan.io/address/${deployedContracts.redeemEngineSilo}`);
    console.log(`   HostAdapter:        https://sepolia.etherscan.io/address/${deployedContracts.hostAdapter}`);
    console.log(`   XCUPZapRouter:      https://sepolia.etherscan.io/address/${deployedContracts.xcupZapRouter}`);
    console.log(`   XCUPOraclePool:     https://sepolia.etherscan.io/address/${deployedContracts.xcupOraclePool}`);
    console.log(`   CommissionTransfer: https://sepolia.etherscan.io/address/${deployedContracts.commissionTransfer}`);
    console.log("\n🏛️ Governance & Vesting:");
    console.log(`   GovernanceToken:    https://sepolia.etherscan.io/address/${deployedContracts.governanceToken}`);
    console.log(`   TimelockController: https://sepolia.etherscan.io/address/${deployedContracts.timelockController}`);
    console.log(`   AlcumGovernor:      https://sepolia.etherscan.io/address/${deployedContracts.alcumGovernor}`);
    console.log(`   TokenVesting:       https://sepolia.etherscan.io/address/${deployedContracts.tokenVesting}`);
    console.log("=".repeat(60));

    // Save addresses to a JSON file for future reference
    const addressesPath = path.join(__dirname, "..", "deployed-addresses.json");
    fs.writeFileSync(addressesPath, JSON.stringify(deployedContracts, null, 2));
    console.log(`📁 Addresses saved to: ${addressesPath}`);
}

/**
 * Main deployment function - deploys all contracts fresh
 *
 * Usage:
 * - Deploy: npx hardhat run scripts/deploy-sepolia.ts --network sepolia
 */
async function main(): Promise<void> {
    try {
        console.log("🚀 Starting deployment process...");
        const [owner] = await ethers.getSigners();
        console.log("🚀 Deploying with account:", owner.address);
        console.log("💰 Account balance:", ethers.formatEther(await ethers.provider.getBalance(owner.address)), "ETH");

        // Validate required addresses
        if (!DEPLOYMENT_CONFIG.treasuryAddress) {
            throw new Error("TREASURY_ADDRESS must be set in .env file");
        }
        if (!DEPLOYMENT_CONFIG.commissionReceiver) {
            throw new Error("COMMISSION_RECEIVER must be set in .env file");
        }

        console.log("\n🆕 Deploying ALL contracts from scratch...");

        // Step 1: Deploy all libraries
        console.log("\n🔄 Step 1: Deploy all libraries");
        await deployLibraries(owner);
        saveDeployedContracts();

        // Step 2: Deploy CUPToken
        console.log("\n🔄 Step 2: Deploy CUPToken (upgradeable proxy)");
        const cupToken = await deployCUPToken(owner);
        saveDeployedContracts();

        // Step 3: Deploy EpochManager
        console.log("\n🔄 Step 3: Deploy EpochManager (upgradeable proxy)");
        const epochManager = await deployEpochManager(owner);
        saveDeployedContracts();

        // Step 4: Deploy CopperPriceConsumer
        console.log("\n🔄 Step 4: Deploy CopperPriceConsumer (regular contract)");
        const copperPriceConsumer = await deployCopperPriceConsumer(owner);
        saveDeployedContracts();

        // Step 5: Deploy xCUP
        console.log("\n🔄 Step 5: Deploy xCUP (upgradeable proxy)");
        const xcup = await deployXCUP(deployedContracts.cupToken!, deployedContracts.copperPriceConsumer!, owner);
        saveDeployedContracts();

        // Step 6: Deploy XCUPOraclePool
        console.log("\n🔄 Step 6: Deploy XCUPOraclePool (upgradeable proxy)");
        const xcupOraclePool = await deployXCUPOraclePool(deployedContracts.xcup!, owner);
        saveDeployedContracts();

        // Step 7: Deploy Zapper
        console.log("\n🔄 Step 7: Deploy Zapper (upgradeable proxy)");
        const zapper = await deployZapper(
            deployedContracts.cupToken!,
            deployedContracts.xcup!,
            deployedContracts.copperPriceConsumer!,
            deployedContracts.epochManager!,
            owner,
        );
        saveDeployedContracts();

        // Step 8: Deploy RedeemEngine
        console.log("\n🔄 Step 8: Deploy RedeemEngine (upgradeable proxy)");
        const redeemEngine = await deployRedeemEngine(
            deployedContracts.cupToken!,
            deployedContracts.xcup!,
            deployedContracts.copperPriceConsumer!,
            deployedContracts.zapper!,
            owner,
        );
        saveDeployedContracts();

        // Step 9: Deploy HostAdapter
        console.log("\n🔄 Step 9: Deploy HostAdapter (upgradeable proxy)");
        const hostAdapter = await deployHostAdapter(deployedContracts.zapper!, owner);
        saveDeployedContracts();

        // Step 10: Deploy SettlementEngine
        console.log("\n🔄 Step 10: Deploy SettlementEngine (upgradeable proxy)");
        const settlementEngine = await deploySettlementEngine(
            deployedContracts.xcup!,
            DEPLOYMENT_CONFIG.treasuryAddress,
            deployedContracts.zapper!,
            deployedContracts.redeemEngineSilo!,
            deployedContracts.epochManager!,
            deployedContracts.copperPriceConsumer!,
            DEPLOYMENT_CONFIG.systemFeeBps,
            owner,
        );
        saveDeployedContracts();

        // Step 11: Deploy XCUPZapRouter
        console.log("\n🔄 Step 11: Deploy XCUPZapRouter (upgradeable proxy)");
        const xcupZapRouter = await deployXCUPZapRouter(
            deployedContracts.xcupOraclePool!,
            deployedContracts.xcup!,
            owner,
        );
        saveDeployedContracts();

        // Step 12: Deploy CommissionTransfer
        console.log("\n🔄 Step 12: Deploy CommissionTransfer (upgradeable proxy)");
        const commissionTransfer = await deployCommissionTransfer(
            DEPLOYMENT_CONFIG.commissionReceiver,
            deployedContracts.xcupOraclePool!,
            owner,
        );
        saveDeployedContracts();

        // Step 13: Deploy GovernanceToken
        console.log("\n🔄 Step 13: Deploy GovernanceToken (regular contract)");
        const governanceToken = await deployGovernanceToken(owner.address, owner);
        saveDeployedContracts();

        // Step 14: Deploy TimelockController
        console.log("\n🔄 Step 14: Deploy TimelockController (regular contract)");
        const timelockController = await deployTimelockController(owner.address, owner);
        saveDeployedContracts();

        // Step 15: Deploy AlcumGovernor
        console.log("\n🔄 Step 15: Deploy AlcumGovernor (UUPS upgradeable proxy)");
        const alcumGovernor = await deployAlcumGovernor(
            deployedContracts.governanceToken!,
            deployedContracts.timelockController!,
            owner.address,
            owner,
        );
        saveDeployedContracts();

        // Step 16: Deploy TokenVesting
        console.log("\n🔄 Step 16: Deploy TokenVesting (regular contract)");
        const tokenVesting = await deployTokenVesting(deployedContracts.governanceToken!, owner);
        saveDeployedContracts();

        // Step 17: Configure CommissionTransfer
        console.log("\n🔄 Step 17: Configure CommissionTransfer");
        await configureCommissionTransfer(commissionTransfer, deployedContracts.xcupOraclePool!, owner);

        // Step 18: Setup contract permissions (including governance & vesting)
        console.log("\n🔄 Step 18: Setup contract permissions");
        await setupContracts(
            {
                cupToken,
                settlementEngine,
                xcup,
                zapper,
                governanceToken,
                tokenVesting,
                timelockController,
            },
            owner,
        );

        // Print summary
        printDeploymentSummary();
        await printGasSummary();
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

/*
USAGE:

1. Deploy all contracts to Sepolia:
   npx hardhat run scripts/deploy-sepolia.ts --network sepolia

2. Verify all contracts:
   npx hardhat run scripts/verify-sepolia.ts --network sepolia

CONTRACT TYPES:
- Libraries: NOT upgradeable (DepositLib, DepositViewLib, PermitLib, RedeemLib, RedeemViewLib, SwapLib)
- Upgradeable proxies: CUPToken, xCUP, EpochManager, SettlementEngine, Zapper, RedeemEngine, HostAdapter, XCUPZapRouter, XCUPOraclePool, CommissionTransfer
- Regular contracts: CopperPriceConsumer
- Internal contracts (created via new): Silo (created inside Zapper and RedeemEngine)

NOTES:
- Contract addresses are automatically saved to deployed-addresses.json
- Make sure to have proper .env configuration for Sepolia deployment:
  - PRIVATE_KEY
  - RPC_URL
  - ETHERSCAN_KEY
  - TREASURY_ADDRESS
  - COMMISSION_RECEIVER
  - USDT_ADDRESS (optional, for CommissionTransfer)
- Ensure you have enough Sepolia ETH for deployment (recommended: 0.5+ ETH)
*/
