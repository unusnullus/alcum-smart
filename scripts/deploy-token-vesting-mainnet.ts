/* eslint-disable no-console */
import { run } from "hardhat";
import { config } from "dotenv";
import { ethers } from "hardhat";
import * as fs from "fs";
import * as path from "path";

config();

// ============================================================================
// CONFIGURATION
// ============================================================================

const GOVERNANCE_TOKEN_ADDRESS = "0xdEc634dB1aa658323B3668887cD9651f0b86f29a";

// ============================================================================
// Main
// ============================================================================

async function main(): Promise<void> {
    try {
        const [deployer] = await ethers.getSigners();
        const network = await ethers.provider.getNetwork();
        const chainId = Number(network.chainId);

        console.log("=".repeat(60));
        console.log("  TokenVesting — Mainnet Deployment");
        console.log("=".repeat(60));
        console.log(`  Network:          ${network.name} (chainId ${chainId})`);
        console.log(`  Deployer:         ${deployer.address}`);

        const balance = await ethers.provider.getBalance(deployer.address);
        console.log(`  Balance:          ${ethers.formatEther(balance)} ETH`);
        console.log(`  GovernanceToken:  ${GOVERNANCE_TOKEN_ADDRESS}`);

        if (chainId === 1) {
            console.log("\n  ** MAINNET DEPLOYMENT **\n");
        }

        // ── Step 1: Deploy TokenVesting ───────────────────────────────────
        console.log("[Step 1] Deploying TokenVesting...");

        const balanceBefore = await ethers.provider.getBalance(deployer.address);

        const TokenVestingFactory = await ethers.getContractFactory("TokenVesting");
        const tokenVesting = await TokenVestingFactory.deploy(GOVERNANCE_TOKEN_ADDRESS);
        await tokenVesting.waitForDeployment();

        const tokenVestingAddress = await tokenVesting.getAddress();

        const receipt = await tokenVesting.deploymentTransaction()?.wait();
        if (receipt) {
            const balanceAfter = await ethers.provider.getBalance(deployer.address);
            const costInWei = balanceBefore - balanceAfter;
            console.log(`  Gas used: ${receipt.gasUsed.toLocaleString()}`);
            console.log(`  Cost:     ${ethers.formatEther(costInWei)} ETH`);
        }

        console.log(`  TokenVesting deployed at: ${tokenVestingAddress}`);

        // ── Step 2: Verify on Etherscan ───────────────────────────────────
        console.log("\n[Step 2] Verifying TokenVesting on Etherscan...");

        const deployTx = tokenVesting.deploymentTransaction();
        if (deployTx) {
            console.log("  Waiting for confirmations...");
            await deployTx.wait(5);
        }

        try {
            await run("verify:verify", {
                address: tokenVestingAddress,
                constructorArguments: [GOVERNANCE_TOKEN_ADDRESS],
            });
            console.log("  TokenVesting verified successfully.");
        } catch (error: any) {
            if (error.message?.toLowerCase().includes("already verified")) {
                console.log("  TokenVesting already verified.");
            } else {
                console.warn("  Verification failed (can retry manually):", error.message);
            }
        }

        // ── Summary ──────────────────────────────────────────────────────
        const explorerBase =
            chainId === 1 ? "https://etherscan.io" : chainId === 11155111 ? "https://sepolia.etherscan.io" : "";

        console.log("\n" + "=".repeat(60));
        console.log("  DEPLOYMENT COMPLETE");
        console.log("=".repeat(60));
        console.log(`  TokenVesting:      ${tokenVestingAddress}`);
        console.log(`  GovernanceToken:   ${GOVERNANCE_TOKEN_ADDRESS}`);
        console.log(`  Owner:             ${deployer.address}`);

        if (explorerBase) {
            console.log(`\n  ${explorerBase}/address/${tokenVestingAddress}`);
        }

        // Save output
        const timestamp = Date.now();
        const outputPath = path.join(__dirname, "..", `token-vesting-mainnet-${timestamp}.json`);
        fs.writeFileSync(
            outputPath,
            JSON.stringify(
                {
                    network: network.name,
                    chainId,
                    tokenVesting: tokenVestingAddress,
                    governanceToken: GOVERNANCE_TOKEN_ADDRESS,
                    deployer: deployer.address,
                    deployedAt: new Date().toISOString(),
                },
                null,
                2,
            ),
        );
        console.log(`  Output saved to: ${outputPath}`);
    } catch (error) {
        console.error("\nDeployment failed:", error);
        process.exitCode = 1;
    }
}

main().catch((error) => {
    console.error(error);
    process.exitCode = 1;
});
