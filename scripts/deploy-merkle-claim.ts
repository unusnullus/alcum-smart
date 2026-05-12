/* eslint-disable no-console */
import { config } from "dotenv";
import { ethers, run, upgrades } from "hardhat";
import * as fs from "fs";
import * as path from "path";

config();

type DeploymentResult = {
    network: string;
    chainId: string;
    deployer: string;
    deployedAt: string;
    merkleClaimProxy: string;
    merkleClaimImplementation: string;
};

function saveDeploymentResult(result: DeploymentResult, networkName: string): string {
    const fileName = `merkle-claim-${networkName}-${Date.now()}.json`;
    const outputPath = path.join(__dirname, "..", fileName);
    fs.writeFileSync(outputPath, JSON.stringify(result, null, 2));
    return outputPath;
}

const delay = async (ms: number) => await new Promise((resolve) => setTimeout(resolve, ms));

async function verifyContract(address: string, constructorArguments: any[], label: string): Promise<void> {
    console.log(`\nVerifying ${label} at ${address}...`);
    await delay(7000);
    try {
        await run("verify:verify", {
            address,
            constructorArguments,
        });
        console.log(`Verified: ${label}`);
    } catch (error: any) {
        const msg = (error?.message || "").toLowerCase();
        if (msg.includes("already verified")) {
            console.log(`Already verified: ${label}`);
            return;
        }
        console.log(`Verification failed for ${label}: ${error?.message || "unknown error"}`);
    }
}

async function main(): Promise<void> {
    const [deployer] = await ethers.getSigners();
    const network = await ethers.provider.getNetwork();
    const networkName = network.chainId === 1n ? "mainnet" : "sepolia";

    console.log("========================================");
    console.log("MultiTokenMerkleClaim Deployment (UUPS)");
    console.log("========================================");
    console.log("Network:", networkName);
    console.log("ChainId:", network.chainId.toString());
    console.log("Deployer:", deployer.address);

    console.log("\nDeploying AlcumMultiTokenMerkleClaim (UUPS proxy)...");
    const MerkleClaimFactory = await ethers.getContractFactory("AlcumMultiTokenMerkleClaim");
    const merkleClaim = await upgrades.deployProxy(MerkleClaimFactory, [], {
        kind: "uups",
        initializer: "initialize",
    });
    await merkleClaim.waitForDeployment();
    const proxyAddress = await merkleClaim.getAddress();
    console.log("MerkleClaim proxy:", proxyAddress);

    const implAddress = await upgrades.erc1967.getImplementationAddress(proxyAddress);
    console.log("MerkleClaim implementation:", implAddress);

    const owner = await merkleClaim.owner();
    console.log("Owner:", owner);

    const result: DeploymentResult = {
        network: networkName,
        chainId: network.chainId.toString(),
        deployer: deployer.address,
        deployedAt: new Date().toISOString(),
        merkleClaimProxy: proxyAddress,
        merkleClaimImplementation: implAddress,
    };

    const outputPath = saveDeploymentResult(result, networkName);

    const skipVerify = process.env.SKIP_VERIFY === "true";
    if (!skipVerify) {
        console.log("\n========================================");
        console.log("Verification");
        console.log("========================================");

        await verifyContract(implAddress, [], "AlcumMultiTokenMerkleClaim implementation");

        const initData = MerkleClaimFactory.interface.encodeFunctionData("initialize", []);
        await verifyContract(
            proxyAddress,
            [implAddress, initData],
            "MerkleClaim UUPS proxy (ERC1967Proxy)",
        );
    } else {
        console.log("\nVerification skipped (SKIP_VERIFY=true).");
    }

    console.log("\n========================================");
    console.log("Deployment finished");
    console.log("========================================");
    console.log("Saved addresses to:", outputPath);
    console.log("\nProxy address:", proxyAddress);
    console.log("Implementation:", implAddress);
    console.log("\nNext steps:");
    console.log(`1) Set MERKLE_CLAIM_CONTRACT_ADDRESS=${proxyAddress} in indexer .env`);
    console.log("2) Transfer GovernanceToken (ALCUM) to the proxy for claim payouts");
    console.log("3) Set REFERRAL_OPERATOR_PRIVATE_KEY in indexer .env (must be the deployer/owner)");
}

main().catch((error) => {
    console.error(error);
    process.exitCode = 1;
});
