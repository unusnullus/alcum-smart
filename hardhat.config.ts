import { HardhatUserConfig } from "hardhat/config";
import "@nomicfoundation/hardhat-toolbox";
import "@openzeppelin/hardhat-upgrades";
import "@nomicfoundation/hardhat-chai-matchers";
import "hardhat-contract-sizer";
import "@nomicfoundation/hardhat-foundry";

import * as dotenv from "dotenv";
require("solidity-coverage");

dotenv.config();

const RPC_URL = process.env.RPC_URL;
const PRIVATE_KEY = process.env.PRIVATE_KEY || "";
const COINMARKETCAP_API_KEY = process.env.COINMARKETCAP_API_KEY

const config: HardhatUserConfig = {
  solidity: {
    version: '0.8.24',
    settings: {
      optimizer: {
        enabled: true,
        runs: 100,
      },
    },
  },
  defaultNetwork: "hardhat",
  networks: {
    mainnet: {
      url: RPC_URL,
      accounts: [PRIVATE_KEY],
    },
    testnet: {
      url: RPC_URL,
      accounts: [PRIVATE_KEY],
      timeout: 200000000,
    },
    hardhat: {
      blockGasLimit: 9999999999999,
      gas: 30000000,
      forking: {
        url: process.env.RPC_URL || "",
      },
    },
  },
  gasReporter: {
    enabled: true,
    currency: "USD",
    coinmarketcap: COINMARKETCAP_API_KEY,
  },
  etherscan: {
    apiKey: process.env.ETHERSCAN_KEY,
  },
  mocha: {
    timeout: 100000000,
  },
};

export default config;
