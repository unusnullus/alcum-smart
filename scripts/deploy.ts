/* eslint-disable no-console */
import { run } from "hardhat";
import { config } from "dotenv";
import { ethers, upgrades } from "hardhat";

import { OPERATOR_FACTORY_ADDRESS } from "../constants";

config();

async function main() {
  const [owner] = await ethers.getSigners();

  const operatorFactory = await ethers.getContractAt("OperatorFactory", OPERATOR_FACTORY_ADDRESS);

  console.log("Operator Factory ", await operatorFactory.deployNewOperator());

}

const delay = async (milliseconds: number) =>
  await new Promise((resolve) => setTimeout(resolve, milliseconds));

export const verify = async (address: string, args: any) => {
  console.log(`Waiting before verify contract ${address}`);
  await delay(10000);

  console.log(`Verifying contract ${address}`);
  try {
    await run("verify:verify", {
      address,
      constructorArguments: args,
    });
  } catch (error: any) {
    if (error.message.toLowerCase().includes("already verified")) {
      console.log("Already verified");
    } else {
      console.error(error);
    }
  }
};

main().catch((error) => {
  console.error(error);
  process.exitCode = 1;
});
