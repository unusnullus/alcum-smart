// SPDX-License-Identifier: MIT
import { ethers, upgrades, expect } from "./setup";

import { CUPToken__factory, xCUP__factory, EpochManager__factory, Zapper__factory, HostAdapter__factory, CopperPriceConsumerMock__factory } from "../typechain-types";

describe("HostAdapter external deposit flow (Hardhat)", function () {
  it("registers, approves with snapshot, and beneficiary claims xCUP", async function () {
    const [deployer, host, curator, beneficiary] = await ethers.getSigners();

    // Deploy core token
    const cup = await new CUPToken__factory(deployer).deploy();
    await cup.waitForDeployment();

    // Deploy upgradeable proxies
    const xcup = await upgrades.deployProxy(
      new xCUP__factory(deployer),
      [await cup.getAddress(), "xCUP", "xCUP"],
      { initializer: "initialize" }
    );

    const epochs = await upgrades.deployProxy(
      new EpochManager__factory(deployer),
      [7 * 24 * 60 * 60],
      { initializer: "initialize" }
    );

    const price = await new CopperPriceConsumerMock__factory(deployer).deploy();
    await price.waitForDeployment();

    // Dummy router: use any address for constructor validation; not used by external flow
    const dummyRouter = ethers.Wallet.createRandom().address;

    const zapper = await upgrades.deployProxy(
      new Zapper__factory(deployer),
      [await cup.getAddress(), ethers.Wallet.createRandom().address, await xcup.getAddress(), dummyRouter, await price.getAddress(), await epochs.getAddress()],
      { initializer: "initialize" }
    );

    const adapter = await upgrades.deployProxy(
      new HostAdapter__factory(deployer),
      [await zapper.getAddress()],
      { initializer: "initialize" }
    );

    // Roles
    await (await zapper.connect(deployer).grantRole(await zapper.HOST_INTEGRATION_ROLE(), await adapter.getAddress())).wait();
    await (await adapter.connect(deployer).grantRole(await adapter.HOST_OPERATOR_ROLE(), host.address)).wait();
    await (await adapter.connect(deployer).grantRole(await adapter.CURATOR_OPERATOR_ROLE(), curator.address)).wait();

    // Fund Zapper with CUP for claims
    await (await cup.connect(deployer).grantRole(await cup.MINTER_ROLE(), deployer.address)).wait();
    await (await cup.connect(deployer).mint(await zapper.getAddress(), ethers.parseUnits("1000000", 6))).wait();

    // Start epoch
    await (await epochs.connect(deployer).nextEpoch()).wait();

    // Host registers external deposit
    const usdcAmount = ethers.parseUnits("1000", 6);
    const tag = ethers.encodeBytes32String("ORDER-12345");

    const tx1 = await adapter.connect(host).registerExternalDepositFor(beneficiary.address, usdcAmount, tag);
    await tx1.wait();

    // Derive depositId via static call
    const depositId = await adapter.connect(host).registerExternalDepositFor.staticCall(beneficiary.address, usdcAmount, tag);

    // Curator approves with price snapshot (1 CUP per 1 USDC for simplicity)
    const priceSnapshot = 1n;
    await (await adapter.connect(curator).approveExternalDepositWithPrice(depositId, usdcAmount, priceSnapshot)).wait();

    // Beneficiary claims and receives xCUP
    const balanceBefore = await xcup.balanceOf(beneficiary.address);
    const claimTx = await zapper.connect(beneficiary).claimDeposit(depositId);
    const receipt = await claimTx.wait();

    const balanceAfter = await xcup.balanceOf(beneficiary.address);
    expect(balanceAfter - balanceBefore).to.be.gt(0n);

    // Check rich claim event presence
    const claimedFor = receipt!.logs.map(l => {
      try { return (zapper.interface as any).parseLog(l); } catch { return null; }
    }).filter(Boolean).find((e: any) => e?.name === "DepositClaimedFor");
    expect(claimedFor?.args?.beneficiary).to.equal(beneficiary.address);
  });

  it("reverts claim by unauthorized EOA", async function () {
    const [deployer, host, curator, beneficiary, other] = await ethers.getSigners();

    const cup = await new CUPToken__factory(deployer).deploy();
    await cup.waitForDeployment();

    const xcup = await upgrades.deployProxy(new xCUP__factory(deployer), [await cup.getAddress(), "xCUP", "xCUP"], { initializer: "initialize" });
    const epochs = await upgrades.deployProxy(new EpochManager__factory(deployer), [7 * 24 * 60 * 60], { initializer: "initialize" });
    const price = await new CopperPriceConsumerMock__factory(deployer).deploy();
    await price.waitForDeployment();

    const zapper = await upgrades.deployProxy(
      new Zapper__factory(deployer),
      [await cup.getAddress(), ethers.Wallet.createRandom().address, await xcup.getAddress(), ethers.Wallet.createRandom().address, await price.getAddress(), await epochs.getAddress()],
      { initializer: "initialize" }
    );
    const adapter = await upgrades.deployProxy(new HostAdapter__factory(deployer), [await zapper.getAddress()], { initializer: "initialize" });

    await (await zapper.connect(deployer).grantRole(await zapper.HOST_INTEGRATION_ROLE(), await adapter.getAddress())).wait();
    await (await adapter.connect(deployer).grantRole(await adapter.HOST_OPERATOR_ROLE(), host.address)).wait();
    await (await adapter.connect(deployer).grantRole(await adapter.CURATOR_OPERATOR_ROLE(), curator.address)).wait();

    await (await cup.connect(deployer).grantRole(await cup.MINTER_ROLE(), deployer.address)).wait();
    await (await cup.connect(deployer).mint(await zapper.getAddress(), ethers.parseUnits("1000000", 6))).wait();
    await (await epochs.connect(deployer).nextEpoch()).wait();

    const usdcAmount = ethers.parseUnits("10", 6);
    const tag = ethers.encodeBytes32String("ORDER-2");

    await (await adapter.connect(host).registerExternalDepositFor(beneficiary.address, usdcAmount, tag)).wait();
    const depositId = await adapter.connect(host).registerExternalDepositFor.staticCall(beneficiary.address, usdcAmount, tag);

    await (await adapter.connect(curator).approveExternalDepositWithPrice(depositId, usdcAmount, 1n)).wait();

    await expect(zapper.connect(other).claimDeposit(depositId)).to.be.revertedWith("Not authorized to claim");
  });
});
