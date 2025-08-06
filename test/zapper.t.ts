import { loadFixture, ethers, expect, upgrades, anyValue } from "./setup";
import { Zapper, CUPToken, XCUP, IERC20__factory } from "../typechain-types";

import { ROUTER_ADDRESS, USDC_ADDRESS } from "../constants";

import routerAbi from "@uniswap/v2-periphery/build/UniswapV2Router02.json";

// Tests
describe("Zapper", function () {
    async function deployFixture() {
        const [
            owner,
            ...otherAccounts
        ] = await ethers.getSigners();

        const usdc = new ethers.Contract(
            USDC_ADDRESS,
            IERC20__factory.abi,
            owner,
        );

        const router = new ethers.Contract(
            ROUTER_ADDRESS,
            routerAbi.abi,
            owner,
        );

        // CUP
        const CUPToken = await ethers.getContractFactory("CUPToken");
        const cupToken = await CUPToken.deploy(
        ) as CUPToken;
        await cupToken.waitForDeployment();

        // Vault
        const XCUP = await ethers.getContractFactory("xCUP");
        const xCUP = await XCUP.deploy(
            cupToken.target,
            "xCUP",
            "xCUP"
        ) as XCUP;
        await xCUP.waitForDeployment();

        // Zapper
        const Zapper = await ethers.getContractFactory("Zapper");
        const zapper = await Zapper.deploy(
            cupToken.target,
            xCUP.target,
            ROUTER_ADDRESS
        ) as Zapper;
        await zapper.waitForDeployment();

        // Create pair USDC/CUP
        await cupToken.approve(ROUTER_ADDRESS, ethers.parseUnits("50000000", 18));
        await router.addLiquidity(
            USDC_ADDRESS,
            cupToken.target,
            ethers.parseUnits("5000000", 18),
            ethers.parseUnits("5000000", 18),
            ethers.parseUnits("5000000", 18),
            ethers.parseUnits("5000000", 18),
            owner.address,
            ethers.MaxUint256
        );

        return {
            zapper,
            xCUP,
            usdc,
            owner,
        };
    }

    describe("deposit", function () {
        it("Should deposit to Vault", async function () {
            const { zapper, xCUP, usdc, owner } = await loadFixture(deployFixture);
            const amountToDeposit = 10e6;

            // Deposit USDC
            await usdc.approve(zapper.target, amountToDeposit);
            const depositTx = await zapper.zapAndDeposit(
                usdc,
                amountToDeposit
            );

            expect(
                depositTx
            ).to.emit(zapper, "ZapAndDeposit")
                .withArgs(ROUTER_ADDRESS, USDC_ADDRESS, amountToDeposit, anyValue);
        });
    });
});
