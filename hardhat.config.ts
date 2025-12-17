import { HardhatUserConfig } from "hardhat/config";
import "@nomicfoundation/hardhat-toolbox";
import "@openzeppelin/hardhat-upgrades";
import "@nomicfoundation/hardhat-chai-matchers";
import "hardhat-contract-sizer";
import "@nomicfoundation/hardhat-foundry";
import "@nomicfoundation/hardhat-verify";

import * as dotenv from "dotenv";
require("solidity-coverage");

dotenv.config();

const RPC_URL = process.env.RPC_URL;
const PRIVATE_KEY = process.env.PRIVATE_KEY || "";
const COINMARKETCAP_API_KEY = process.env.COINMARKETCAP_API_KEY;

const config: HardhatUserConfig = {
    solidity: {
        version: "0.8.24",
        settings: {
            viaIR: true,
            optimizer: {
                enabled: true,
                runs: 100,
            },
            evmVersion: "paris",
            metadata: {
                bytecodeHash: "none",
            },
        },
    },
    defaultNetwork: "hardhat",
    networks: {
        mainnet: {
            url: RPC_URL,
            accounts: [PRIVATE_KEY],
            chainId: 1,
        },
        sepolia: {
            url: RPC_URL || process.env.SEPOLIA_RPC_URL || "",
            accounts: PRIVATE_KEY ? [PRIVATE_KEY] : [],
            timeout: 200000000,
            chainId: 11155111,
        },
        testnet: {
            url: RPC_URL,
            accounts: [PRIVATE_KEY],
            timeout: 200000000,
            chainId: 11155111,
        },
        hardhat: {
            blockGasLimit: 9999999999999,
            gas: 30000000,
            forking: {
                url: process.env.RPC_URL || "",
            },
            accounts: [
                {
                    privateKey: PRIVATE_KEY,
                    balance: "1000000000000000000000",
                },
            ],
        },
    },
    gasReporter: {
        enabled: true,
        currency: "USD",
        coinmarketcap: COINMARKETCAP_API_KEY,
    },
    etherscan: {
        apiKey: process.env.ETHERSCAN_API_KEY!,
        customChains: [
            {
                network: "sepolia",
                chainId: 11155111,
                urls: {
                    apiURL: "https://api-sepolia.etherscan.io/api",
                    browserURL: "https://sepolia.etherscan.io",
                },
            },
            {
                network: "testnet",
                chainId: 11155111,
                urls: {
                    apiURL: "https://api.etherscan.io/v2/api?chainid=11155111",
                    browserURL: "https://sepolia.etherscan.io",
                },
            },
            {
                network: "mainnet",
                chainId: 1,
                urls: {
                    apiURL: "https://api.etherscan.io/v2/api?chainid=1",
                    browserURL: "https://etherscan.io",
                },
            },
        ],
    },
    mocha: {
        timeout: 100000000,
    },
};

export default config;
