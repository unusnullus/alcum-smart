/* eslint-disable no-console */
import { run } from "hardhat";
import { config } from "dotenv";
import { ethers, upgrades } from "hardhat";

import { CUPToken, IERC20__factory } from "../typechain-types";

import {
  OPERATOR_FACTORY_ADDRESS,
  ROUTER_ADDRESS,
  USDC_ADDRESS,
  OPERATOR_ADDRESS,
  LINK_ADDRESS
} from "../constants";
import { hexlify, keccak256 } from "ethers";

config();

// aa9d5d553df8478fac9d7eac75aa9c4b

async function main() {
  const [owner] = await ethers.getSigners();

  // console.log(keccak256(ethers.toUtf8Bytes("aa9d5d55-3df8-478f-ac9d-7eac75aa9c4b")));

  // const CopperPriceConsumer = await ethers.getContractFactory("CopperPriceConsumer");
  // const copperPriceConsumer = await CopperPriceConsumer.deploy(
  //   OPERATOR_ADDRESS,
  //   "0xaa9d5d553df8478fac9d7eac75aa9c4b00000000000000000000000000000000",
  //   ethers.parseUnits("0.1", 18),
  //   LINK_ADDRESS
  // );
  // await copperPriceConsumer.waitForDeployment();

  // console.log("Copper Price Consumer", copperPriceConsumer.target);

  // await verify(await copperPriceConsumer.getAddress(), [OPERATOR_ADDRESS, "0xaa9d5d553df8478fac9d7eac75aa9c4b00000000000000000000000000000000", ethers.parseUnits("0.1", 18), LINK_ADDRESS]);

  // 0x9E1cC5d32cA6a9F3d2286B6b66193DaB14413a39
  // const CupToken = await ethers.getContractFactory("CUPToken");
  // const cupToken = await CupToken.deploy() as CUPToken;
  // await cupToken.waitForDeployment()

  // console.log("Cup Token ", cupToken.target);

  // await verify("0xb2a609361356599335ae83AfAaB4Ee661Bb39c41", []);


  // //0x56940642432323bD3050675CcE1ff7E45C498afc
  // const XCUP = await ethers.getContractFactory("xCUP");
  // const xcup = await XCUP.deploy(cupToken.target, "xCUP", "xCUP");
  // await xcup.waitForDeployment();

  // console.log("XCUP ", xcup.target);

  // await verify(await xcup.getAddress(), [cupToken.target, "xCUP", "xCUP"]);

  // // 0x7F1e09F92b20ee09F0A535Aa2a068d39af27e6f3
  const Zapper = await ethers.getContractFactory("Zapper");
  const zapper = await Zapper.deploy("0xb2a609361356599335ae83AfAaB4Ee661Bb39c41", USDC_ADDRESS, "0xB62AeEbac488783c0c46C8127B57d8F40ffD0397", ROUTER_ADDRESS, "0x5F17C631B7c2d87BDCE210F21b71167457EA44F6");
  await zapper.waitForDeployment();

  console.log("Zapper ", zapper.target);

  await verify(await zapper.getAddress(), ["0xb2a609361356599335ae83AfAaB4Ee661Bb39c41", USDC_ADDRESS, "0xB62AeEbac488783c0c46C8127B57d8F40ffD0397", ROUTER_ADDRESS, "0x5F17C631B7c2d87BDCE210F21b71167457EA44F6"]);

  // Aug-01-2025 11:56:48 AM UTC
  // const timestamp = Math.floor(new Date('2025-08-01T11:56:48Z').getTime() / 1000);
  // console.log('Timestamp:', timestamp); // Should be around 1733128608

  // const encodedData = ethers.solidityPacked(
  //   ['address', 'uint256', 'uint256'],
  //   ["0x4a59F710a496fEc0e939350eba8EE514Fa493D81", timestamp, 100000000000]
  // );
  // const depositId = ethers.keccak256(encodedData);

  // console.log(depositId);


  // const cupToken = await ethers.getContractAt("CUPToken", cupToken.target);
  // const zapper = await ethers.getContractAt("Zapper", "0x67C2337ba09Fb82859DE524eA2F8106afB826fB4");

  // const tx = await zapper.zapAndDeposit(ethers.ZeroAddress, 100000000000, { value: 100000000000 });
  // await tx.wait();
  // console.log(tx);

  // const linkToken = new ethers.Contract(
  //   LINK_ADDRESS,
  //   IERC20__factory.abi,
  //   owner,
  // );

  // const tx = await cupToken.transfer("0x6b7A0bd57c708DA1Ee56D105b3E98D91fDFEDA73", ethers.parseUnits("100000000000", 6));
  // await tx.wait();
  // console.log(tx);
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
