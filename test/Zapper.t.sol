// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {console} from "forge-std/console.sol";

import {Upgrades, Options} from "openzeppelin-foundry-upgrades/Upgrades.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";

import {ERC20Mock} from "@contracts/mock/ERC20Mock.sol";

import {Zapper} from "@contracts/Zapper.sol";
import {CUPToken} from "@contracts/CUPToken.sol";
import {xCUP} from "@contracts/xCUP.sol";
import {ICopperPriceConsumer} from "@contracts/interfaces/ICopperPriceConsumer.sol";
import {IEpochManager} from "@contracts/interfaces/IEpochManager.sol";
import {EpochManager} from "@contracts/EpochManager.sol";

import {IUniswapV2Router02} from "@uniswap/v2-periphery/contracts/interfaces/IUniswapV2Router02.sol";

contract ZapperTest is Test {
    address internal owner = 0xC8fb6C1b2377670f5FD1bD3f58926B2d7B7b0971;
    address internal admin = 0x1234567890123456789012345678901234567890;

    // Test accounts with different deposit amounts
    address internal user1 = 0x1111111111111111111111111111111111111111;
    address internal user2 = 0x2222222222222222222222222222222222222222;
    address internal user3 = 0x3333333333333333333333333333333333333333;
    address internal user4 = 0x4444444444444444444444444444444444444444;
    address internal user5 = 0x5555555555555555555555555555555555555555;

    // Track deposit IDs for each user
    bytes32[] user1DepositIds;
    bytes32[] user2DepositIds;
    bytes32[] user3DepositIds;
    bytes32[] user4DepositIds;
    bytes32[] user5DepositIds;

    CUPToken cupToken;
    xCUP xcup;

    Zapper zapper;

    IUniswapV2Router02 router = IUniswapV2Router02(0xeE567Fe1712Faf6149d80dA1E6934E354124CfE3);
    ICopperPriceConsumer copperPriceConsumer = ICopperPriceConsumer(0x5F17C631B7c2d87BDCE210F21b71167457EA44F6);

    IEpochManager epochManager;

    IERC20 usdc = IERC20(0x1c7D4B196Cb0C7B01d743Fbc6116a902379C7238);
    IERC20 weth = IERC20(0xfFf9976782d46CC05630D1f6eBAb18b2324d6B14);

    ERC20Mock erc20Mock;

    // Mock oracle and job details for CopperPriceConsumer
    // address mockOracle = 0x1234567890123456789012345678901234567890;
    // bytes32 mockJobId = 0x1234567890123456789012345678901234567890123456789012345678901234;
    // uint256 mockFee = 0.1e18;
    // address mockLink = 0x514910771AF9Ca656af840dff83E8264EcF986CA;

    function setUp() public {
        string memory rpcUrl = vm.envString("RPC_URL");
        uint256 forkId = vm.createFork(rpcUrl);
        vm.selectFork(forkId);

        // Deploy contracts
        vm.startPrank(owner);
        // Deploy CUP token using upgradeable pattern
        address cupTokenProxy = Upgrades.deployTransparentProxy(
            "CUPToken.sol:CUPToken",
            owner,
            abi.encodeCall(CUPToken.initialize, ())
        );
        cupToken = CUPToken(cupTokenProxy);

        erc20Mock = new ERC20Mock("TST", "TST", 18);

        // Deploy xCUP using upgradeable pattern
        address xcupProxy = Upgrades.deployTransparentProxy(
            "xCUP.sol:xCUP",
            owner,
            abi.encodeCall(xCUP.initialize, (cupToken, "xCUP", "xCUP"))
        );
        xcup = xCUP(xcupProxy);

        // Deploy EpochManager
        address epochManagerProxy = Upgrades.deployTransparentProxy(
            "EpochManager.sol:EpochManager",
            owner,
            abi.encodeCall(EpochManager.initialize, (2592000))
        );
        epochManager = IEpochManager(epochManagerProxy);

        // Deploy Zapper
        address zapperProxy = Upgrades.deployTransparentProxy(
            "Zapper.sol:Zapper",
            owner,
            abi.encodeCall(
                Zapper.initialize,
                (
                    address(cupToken),
                    address(usdc),
                    address(xcup),
                    address(router),
                    address(copperPriceConsumer),
                    address(epochManager)
                )
            )
        );
        zapper = Zapper(zapperProxy);

        // Setup roles
        zapper.grantRole(zapper.VAULT_CURATOR_ROLE(), admin);
        xcup.grantRole(xcup.REDEEMER_ROLE(), address(zapper));

        erc20Mock.mint(owner, 5000000e20);

        vm.stopPrank();

        // Make balances
        deal(address(usdc), owner, 5000000e20);
        deal(address(cupToken), owner, 5000000e20);
        deal(address(cupToken), address(zapper), 5000000e20);

        addLiquidity();
    }

    function testWithdrawDeposit() public {
        uint256 amountToDeposit = 10e6;

        vm.prank(owner);
        usdc.approve(address(zapper), amountToDeposit);

        vm.prank(owner);
        zapper.zapAndDeposit(usdc, amountToDeposit);

        bytes32[] memory pendingDepositIds = zapper.getPendingDepositIds();

        vm.prank(owner);
        zapper.withdrawDeposit(pendingDepositIds[0]);

        assertGe(usdc.balanceOf(owner), amountToDeposit, "Should receive usdc back");
    }

    function testRedeem() public {
        uint256 amountToDeposit = 10e6;

        vm.prank(owner);
        usdc.approve(address(zapper), amountToDeposit);

        vm.prank(owner);
        zapper.zapAndDeposit(usdc, amountToDeposit);

        vm.prank(owner);
        epochManager.nextEpoch();

        bytes32[] memory pendingDepositIds = zapper.getPendingDepositIds();

        vm.prank(admin);
        zapper.approveDeposit(pendingDepositIds[0], amountToDeposit);

        vm.prank(owner);
        zapper.claimDeposit(pendingDepositIds[0]);

        vm.startPrank(owner);
        IERC20(address(xcup)).approve(address(zapper), xcup.balanceOf(owner));
        console.log("xcup balance", xcup.balanceOf(owner));

        uint256 usdcToWithdraw = zapper.redeem(xcup.balanceOf(owner));
        vm.stopPrank();

        // assertGt(usdc, 0, "Should receive usdc");
    }

    function testZapAndDepositWithUSDC() public {
        uint256 amountToDeposit = 50e6;

        vm.prank(owner);
        usdc.approve(address(zapper), amountToDeposit);

        // Check event
        vm.expectEmit(address(zapper));
        emit Zapper.ZapAndDeposit(address(router), address(usdc), 50000000); // 50e6 * 579 = 289500000

        // Deposit
        vm.prank(owner);
        zapper.zapAndDeposit(usdc, amountToDeposit);

        // Check that the USDC is in the silo
        // assertEq(usdc.balanceOf(zapper.silo()), 50000000);
    }

    function testZapAndDepositWithERC20Mock() public {
        uint256 amountToDeposit = 10e18; // 10 tokens

        // Mock token transfer and approval
        vm.prank(owner);
        erc20Mock.approve(address(zapper), amountToDeposit);

        vm.prank(owner);
        zapper.zapAndDeposit(erc20Mock, amountToDeposit);
    }

    function testApproveDeposit() public {
        // First create a deposit with ERC20Mock token
        uint256 amountToDeposit = 50e18;

        uint256 depositValueInUSDC = 47482973758155927037;
        bytes32 depositId = keccak256(abi.encodePacked(owner, uint256(block.timestamp), depositValueInUSDC));

        // Mock token transfer and approval
        vm.prank(owner);
        erc20Mock.approve(address(zapper), amountToDeposit);

        vm.prank(owner);
        zapper.zapAndDeposit(erc20Mock, amountToDeposit);

        vm.prank(owner);
        epochManager.nextEpoch();

        // Approve the deposit
        vm.prank(admin);
        vm.expectEmit(address(zapper));
        emit Zapper.DepositApproved(depositId, 47482973758155927037);
        zapper.approveDeposit(depositId, 47482973758155927037);
    }

    function testApproveDepositRevertWhenEpochNotActive() public {
        bytes32 depositId = keccak256(abi.encodePacked(owner, uint256(block.timestamp), uint256(50e18)));

        vm.prank(owner);
        vm.expectRevert("Epoch not active");
        zapper.approveDeposit(depositId, uint256(50e18));
    }

    function testApproveDepositRevertWhenDepositNotFound() public {
        bytes32 depositId = keccak256(abi.encodePacked(owner, uint256(block.timestamp), uint256(50e18)));

        vm.prank(owner);
        epochManager.nextEpoch();

        vm.prank(admin);
        vm.expectRevert("Deposit not found");
        zapper.approveDeposit(depositId, uint256(50e18));
    }

    function testDeclineDeposit() public {
        // First create a deposit with ERC20Mock token
        uint256 amountToDeposit = 50e18;

        uint256 depositValueInUSDC = 47482973758155927037;
        bytes32 depositId = keccak256(abi.encodePacked(owner, block.timestamp, depositValueInUSDC));

        // Mock token transfer and approval
        vm.prank(owner);
        erc20Mock.approve(address(zapper), amountToDeposit);

        vm.prank(owner);
        zapper.zapAndDeposit(erc20Mock, amountToDeposit);

        assertEq(usdc.balanceOf(zapper.silo()), 47482973758155927037);

        vm.prank(owner);
        epochManager.nextEpoch();

        // Decline the deposit
        vm.prank(admin);
        vm.expectEmit(address(zapper));
        emit Zapper.DepositDeclined(depositId, owner, 47482973758155927037);
        zapper.declineDeposit(depositId);

        // Check that the USDC is in the silo
        assertEq(usdc.balanceOf(zapper.silo()), 0);
        assertGe(usdc.balanceOf(owner), 47482973758155927037);
    }

    function testClaimDeposit() public {
        // First create and approve a deposit with ERC20Mock token
        uint256 amountToDeposit = 50e18;

        uint256 depositValueInUSDC = 47482973758155927037;
        bytes32 depositId = keccak256(abi.encodePacked(owner, block.timestamp, depositValueInUSDC));

        // Mock token transfer and approval
        vm.prank(owner);
        erc20Mock.approve(address(zapper), amountToDeposit);

        vm.prank(owner);
        zapper.zapAndDeposit(erc20Mock, amountToDeposit);

        vm.prank(owner);
        epochManager.nextEpoch();

        // Approve the deposit
        vm.prank(admin);
        zapper.approveDeposit(depositId, 47482973758155927037);

        // Claim the deposit
        vm.prank(owner);
        vm.expectEmit(address(zapper));
        emit Zapper.DepositClaimed(depositId, owner, 460679811401628804112974); // Mock shares amount
        uint256 shares = zapper.claimDeposit(depositId);

        assertGt(shares, 0, "Should receive shares");
    }

    function testClaimDepositRevertWhenNotApproved() public {
        uint256 amountToDeposit = 50e18;

        uint256 depositValueInUSDC = 47482973758155927037;
        bytes32 depositId = keccak256(abi.encodePacked(owner, block.timestamp, depositValueInUSDC));

        // Mock token transfer and approval
        vm.prank(owner);
        erc20Mock.approve(address(zapper), amountToDeposit);

        vm.prank(owner);
        zapper.zapAndDeposit(erc20Mock, amountToDeposit);

        vm.prank(owner);
        epochManager.nextEpoch();

        vm.prank(owner);
        vm.expectRevert("Deposit not approved");
        zapper.claimDeposit(depositId);
    }

    function testClaimDepositRevertWhenWrongUser() public {
        address otherUser = 0x1111111111111111111111111111111111111111;
        bytes32 depositId = keccak256(abi.encodePacked(owner, block.timestamp, uint256(50e18)));

        vm.prank(owner);
        epochManager.nextEpoch();

        vm.prank(otherUser);
        vm.expectRevert("Invalid user");
        zapper.claimDeposit(depositId);
    }

    function testPauseAndUnpause() public {
        // Test pause
        vm.prank(owner);
        zapper.pause();
        assertTrue(zapper.paused(), "Contract should be paused");

        // Test unpause
        vm.prank(owner);
        zapper.unpause();
        assertFalse(zapper.paused(), "Contract should be unpaused");
    }

    function testPauseRevertWhenNotOwner() public {
        vm.prank(admin);
        vm.expectRevert();
        zapper.pause();
    }

    function testUnpauseRevertWhenNotOwner() public {
        vm.prank(admin);
        vm.expectRevert();
        zapper.unpause();
    }

    function testZapAndDepositRevertWhenPaused() public {
        vm.prank(owner);
        zapper.pause();

        uint256 amountToDeposit = 50e6;
        vm.prank(owner);
        usdc.approve(address(zapper), amountToDeposit);

        vm.prank(owner);
        vm.expectRevert();
        zapper.zapAndDeposit(usdc, amountToDeposit);
    }

    function testZapAndDepositRevertWithZeroAmount() public {
        vm.prank(owner);
        vm.expectRevert("Invalid amount");
        zapper.zapAndDeposit(usdc, 0);
    }

    function testZapAndDepositWithNativeETH() public {
        uint256 ethAmount = 1e9;

        assertEq(usdc.balanceOf(address(zapper.silo())), 0);

        // Perform zapAndDeposit with native ETH
        vm.prank(owner);
        vm.expectEmit(address(zapper));
        emit Zapper.ZapAndDeposit(address(router), 0xfFf9976782d46CC05630D1f6eBAb18b2324d6B14, 5); // 6 USDC
        zapper.zapAndDeposit{value: ethAmount}(IERC20(0xfFf9976782d46CC05630D1f6eBAb18b2324d6B14), ethAmount);

        // Check that ETH was sent to the contract
        assertGt(usdc.balanceOf(zapper.silo()), 0, "Silo should receive USDC");
    }

    function testZapWithNativeETHIncorrectValue() public {
        uint256 ethAmount = 1e9; // 1 ETH
        uint256 incorrectValue = 0.5e18; // 0.5 ETH

        // Try to zap with incorrect ETH value
        vm.prank(owner);
        vm.expectRevert("Invalid ETH amount");
        zapper.zapAndDeposit{value: incorrectValue}(IERC20(0xfFf9976782d46CC05630D1f6eBAb18b2324d6B14), ethAmount);
    }

    function testZapWithNativeETHZeroAmount() public {
        uint256 ethAmount = 0;

        // Try to zap with zero ETH amount
        vm.prank(owner);
        vm.expectRevert("Invalid amount");
        zapper.zapAndDeposit{value: ethAmount}(IERC20(0xfFf9976782d46CC05630D1f6eBAb18b2324d6B14), ethAmount);
    }

    function testZapWithNativeETHAndMultipleCalls() public {
        uint256 ethAmount = 0.1e18; // 0.1 ETH per call

        uint256 initialBalance = address(owner).balance;

        // Perform multiple zaps with native ETH
        for (uint256 i = 0; i < 3; i++) {
            vm.prank(owner);
            zapper.zapAndDeposit{value: ethAmount}(IERC20(0xfFf9976782d46CC05630D1f6eBAb18b2324d6B14), ethAmount);
        }

        // Check that total ETH was transferred
        assertEq(address(owner).balance, initialBalance - (ethAmount * 3), "Owner should have less ETH");
    }

    function testZapWithNativeETHAndDifferentAmounts() public {
        uint256[] memory amounts = new uint256[](3);
        amounts[0] = 0.1e18; // 0.1 ETH
        amounts[1] = 0.5e18; // 0.5 ETH
        amounts[2] = 1e18; // 1 ETH

        uint256 initialBalance = address(owner).balance;

        // Perform zaps with different amounts
        for (uint256 i = 0; i < amounts.length; i++) {
            vm.prank(owner);
            zapper.zapAndDeposit{value: amounts[i]}(IERC20(0xfFf9976782d46CC05630D1f6eBAb18b2324d6B14), amounts[i]);
        }

        // Check that total ETH was transferred
        uint256 totalTransferred = amounts[0] + amounts[1] + amounts[2];
        assertEq(address(owner).balance, initialBalance - totalTransferred, "Owner should have less ETH");
    }

    function testApproveDepositsProportionally_BasicScenario() public {
        setupAccountBalances();

        // Create deposits from multiple users with different amounts
        uint256[] memory depositAmounts = new uint256[](3);
        depositAmounts[0] = 20e18; // user1
        depositAmounts[1] = 50e6; // user2
        depositAmounts[2] = 1e9; // user3

        // Record the deposit amounts in USDC
        uint256[] memory depositAmountsUsdc = new uint256[](3);

        (bytes32 depositIdUser1, uint256 usdcAmountUser1) = _createDeposit(user1, erc20Mock, depositAmounts[0]);
        depositAmountsUsdc[0] = usdcAmountUser1;
        (bytes32 depositIdUser2, uint256 usdcAmountUser2) = _createDeposit(user2, usdc, depositAmounts[1]);
        depositAmountsUsdc[1] = usdcAmountUser2;
        (bytes32 depositIdUser3, uint256 usdcAmountUser3) = _createDeposit(user3, weth, depositAmounts[2]);
        depositAmountsUsdc[2] = usdcAmountUser3;

        // Record the deposit IDs
        user1DepositIds.push(depositIdUser1);
        user2DepositIds.push(depositIdUser2);
        user3DepositIds.push(depositIdUser3);

        // Calculate expected values
        uint256 totalPendingAmount = depositAmountsUsdc[0] + depositAmountsUsdc[1] + depositAmountsUsdc[2];

        uint256 targetTotalAmount = totalPendingAmount / 2; // Approve 50%
        uint256 expectedProportion = (targetTotalAmount * 1e18) / totalPendingAmount;

        // Set the epoch to active
        vm.prank(owner);
        epochManager.nextEpoch();

        // Approve deposits proportionally
        vm.prank(admin);
        vm.expectEmit(address(zapper));
        emit Zapper.ProportionalApproval(targetTotalAmount, totalPendingAmount, expectedProportion);
        zapper.approveDepositsProportionally(targetTotalAmount);

        // Verify that deposits are approved with correct proportional amounts
        uint256 expectedUser1Amount = (depositAmountsUsdc[0] * expectedProportion) / 1e18;
        uint256 expectedUser2Amount = (depositAmountsUsdc[1] * expectedProportion) / 1e18;
        uint256 expectedUser3Amount = (depositAmountsUsdc[2] * expectedProportion) / 1e18;

        // Check that each deposit was approved with proportional amount
        assertGt(expectedUser1Amount, 0, "User1 should receive proportional approval");
        assertGt(expectedUser2Amount, 0, "User2 should receive proportional approval");
        assertGt(expectedUser3Amount, 0, "User3 should receive proportional approval");
    }

    function _createDeposit(address user, IERC20 token, uint256 amount) internal returns (bytes32, uint256 usdcAmount) {
        vm.prank(user);
        token.approve(address(zapper), amount);

        if (address(token) != address(usdc)) {
            address[] memory path = new address[](2);
            path[0] = address(token);
            path[1] = address(usdc);

            // Get the amount of tokens out for the given amount in
            uint256[] memory amountsOut = router.getAmountsOut(amount, path);

            if (address(token) == address(weth)) {
                vm.prank(user);
                zapper.zapAndDeposit{value: amount}(token, amount);
            } else {
                vm.prank(user);
                zapper.zapAndDeposit(token, amount);
            }

            return (keccak256(abi.encodePacked(user, block.timestamp, amountsOut[1])), amountsOut[1]);
        } else {
            vm.prank(user);
            zapper.zapAndDeposit(token, amount);

            return (keccak256(abi.encodePacked(user, block.timestamp, amount)), amount);
        }
    }

    function addLiquidity() public {
        uint256 lAmount = 1000e18; // Much smaller amount

        vm.prank(owner);
        erc20Mock.approve(address(router), lAmount);
        vm.prank(owner);
        usdc.approve(address(router), lAmount);

        vm.prank(owner);
        router.addLiquidity(
            address(erc20Mock),
            address(usdc),
            lAmount,
            lAmount,
            lAmount,
            lAmount,
            owner,
            type(uint256).max
        );
    }

    function setupAccountBalances() internal {
        address[] memory users = new address[](5);
        users[0] = user1;
        users[1] = user2;
        users[2] = user3;
        users[3] = user4;
        users[4] = user5;

        for (uint256 i = 0; i < users.length; i++) {
            // Mint ERC20Mock tokens
            vm.prank(owner);
            erc20Mock.mint(users[i], 10000e18);

            // Deal USDC and CUP tokens
            deal(address(usdc), users[i], 10000e6);
            deal(address(cupToken), users[i], 10000e18);
        }

        // Give zapper some CUP tokens
        deal(address(cupToken), address(zapper), 5000000e18);
    }

    function testZapAndDepositWithPermit() public {
        uint256 amountToDeposit = 10e18;

        // Ensure user has sufficient allowance so permit is not executed
        vm.prank(owner);
        erc20Mock.approve(address(zapper), amountToDeposit);

        // Create permit parameters (these won't be used since user has sufficient allowance)
        Zapper.PermitParams memory permitParams = Zapper.PermitParams({
            value: amountToDeposit,
            deadline: block.timestamp + 3600, // 1 hour from now
            v: 27,
            r: 0x1234567890123456789012345678901234567890123456789012345678901234,
            s: 0x1234567890123456789012345678901234567890123456789012345678901234
        });

        // Test with ERC20Mock - since user has sufficient allowance, permit won't be executed
        vm.prank(owner);
        zapper.zapAndDepositWithPermit(erc20Mock, amountToDeposit, permitParams);

        // Verify deposit was created
        bytes32[] memory pendingDepositIds = zapper.getPendingDepositIds();
        assertGt(pendingDepositIds.length, 0, "Should have pending deposits");
    }

    function testZapAndDepositWithPermitRevertWhenZeroAmount() public {
        Zapper.PermitParams memory permitParams = Zapper.PermitParams({
            value: 0,
            deadline: block.timestamp + 3600,
            v: 27,
            r: 0x1234567890123456789012345678901234567890123456789012345678901234,
            s: 0x1234567890123456789012345678901234567890123456789012345678901234
        });

        vm.prank(owner);
        vm.expectRevert("Invalid amount");
        zapper.zapAndDepositWithPermit(usdc, 0, permitParams);
    }

    function testZapAndDepositWithPermitRevertWhenInvalidToken() public {
        uint256 amountToDeposit = 10e6;
        Zapper.PermitParams memory permitParams = Zapper.PermitParams({
            value: amountToDeposit,
            deadline: block.timestamp + 3600,
            v: 27,
            r: 0x1234567890123456789012345678901234567890123456789012345678901234,
            s: 0x1234567890123456789012345678901234567890123456789012345678901234
        });

        vm.prank(owner);
        vm.expectRevert("Invalid token");
        zapper.zapAndDepositWithPermit(IERC20(address(0)), amountToDeposit, permitParams);
    }

    function testZapAndDepositWithPermitRevertWhenPaused() public {
        vm.prank(owner);
        zapper.pause();

        uint256 amountToDeposit = 10e6;
        Zapper.PermitParams memory permitParams = Zapper.PermitParams({
            value: amountToDeposit,
            deadline: block.timestamp + 3600,
            v: 27,
            r: 0x1234567890123456789012345678901234567890123456789012345678901234,
            s: 0x1234567890123456789012345678901234567890123456789012345678901234
        });

        vm.prank(owner);
        vm.expectRevert();
        zapper.zapAndDepositWithPermit(usdc, amountToDeposit, permitParams);
    }
}
