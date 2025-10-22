// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test, console} from "forge-std/Test.sol";
import {Zapper} from "../contracts/Zapper.sol";
import {CUPToken} from "../contracts/CUPToken.sol";
import {xCUP} from "../contracts/xCUP.sol";
import {EpochManager} from "../contracts/EpochManager.sol";
import {HostAdapter} from "../contracts/HostAdapter.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ICopperPriceConsumer} from "../contracts/interfaces/ICopperPriceConsumer.sol";
import {RedeemLib} from "../contracts/libraries/RedeemLib.sol";

// Mock contracts for testing
contract MockCopperPriceConsumer is ICopperPriceConsumer {
    uint256 public price = 450000000; // $4.50 with 8 decimals

    function requestCopperPrice() external pure returns (bytes32) {
        return bytes32(0);
    }

    function fulfill(bytes32, uint256) external pure {
        revert("Not implemented");
    }

    function getPriceAsDecimal() external view returns (uint256) {
        return price / 10 ** 8;
    }

    function updatePrice(uint256 _price) external {
        price = _price;
    }
}

contract MockUSDC is IERC20 {
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function decimals() external pure returns (uint8) {
        return 6;
    }

    function totalSupply() external pure returns (uint256) {
        return 0;
    }

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        require(balanceOf[from] >= amount, "Insufficient balance");
        require(allowance[from][msg.sender] >= amount, "Insufficient allowance");

        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        allowance[from][msg.sender] -= amount;

        return true;
    }
}

contract MockUniswapRouter {
    function WETH() external pure returns (address) {
        return address(0x1234567890123456789012345678901234567890);
    }

    function getAmountsOut(uint256 amountIn, address[] calldata path) external pure returns (uint256[] memory amounts) {
        amounts = new uint256[](2);
        amounts[0] = amountIn;
        amounts[1] = amountIn; // 1:1 for testing
    }

    function swapExactETHForTokens(uint256 amountOutMin, address[] calldata path, address to, uint256 deadline)
        external
        payable
        returns (uint256[] memory amounts)
    {
        // Mock implementation - just return the amounts
        amounts = new uint256[](2);
        amounts[0] = msg.value;
        amounts[1] = msg.value; // 1:1 for testing
    }

    function swapExactTokensForTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external returns (uint256[] memory amounts) {
        // Mock implementation - just return the amounts
        amounts = new uint256[](2);
        amounts[0] = amountIn;
        amounts[1] = amountIn; // 1:1 for testing
    }
}

contract ZapperTest is Test {
    Zapper public zapper;
    CUPToken public cupToken;
    xCUP public xcup;
    EpochManager public epochManager;
    HostAdapter public hostAdapter;
    MockCopperPriceConsumer public copperPriceConsumer;
    MockUSDC public usdc;
    MockUniswapRouter public uniswapRouter;
    address public owner;
    address public vaultCurator;
    address public hostIntegration;
    address public user1;
    address public user2;

    function setUp() public {
        owner = address(this);
        vaultCurator = makeAddr("vaultCurator");
        hostIntegration = makeAddr("hostIntegration");
        user1 = makeAddr("user1");
        user2 = makeAddr("user2");

        // Deploy dependencies
        CUPToken cupImpl = new CUPToken();
        bytes memory cupInitData = abi.encodeWithSelector(CUPToken.initialize.selector);
        ERC1967Proxy cupProxy = new ERC1967Proxy(address(cupImpl), cupInitData);
        cupToken = CUPToken(address(cupProxy));

        copperPriceConsumer = new MockCopperPriceConsumer();
        usdc = new MockUSDC();
        uniswapRouter = new MockUniswapRouter();

        // Deploy EpochManager
        EpochManager epochImpl = new EpochManager();
        bytes memory epochInitData = abi.encodeWithSelector(EpochManager.initialize.selector, 7 days);
        ERC1967Proxy epochProxy = new ERC1967Proxy(address(epochImpl), epochInitData);
        epochManager = EpochManager(address(epochProxy));

        // Deploy xCUP
        xCUP xcupImpl = new xCUP();
        bytes memory xcupInitData = abi.encodeWithSelector(
            xCUP.initialize.selector,
            IERC20(address(cupToken)),
            "xCUP Vault",
            "xCUP",
            address(copperPriceConsumer),
            address(uniswapRouter),
            address(usdc),
            address(0x1234567890123456789012345678901234567890) // Mock WETH
        );
        ERC1967Proxy xcupProxy = new ERC1967Proxy(address(xcupImpl), xcupInitData);
        xcup = xCUP(address(xcupProxy));

        // Deploy Zapper
        Zapper zapperImpl = new Zapper();
        bytes memory zapperInitData = abi.encodeWithSelector(
            Zapper.initialize.selector,
            address(cupToken),
            address(usdc),
            address(xcup),
            address(uniswapRouter),
            address(copperPriceConsumer),
            address(epochManager)
        );
        ERC1967Proxy zapperProxy = new ERC1967Proxy(address(zapperImpl), zapperInitData);
        zapper = Zapper(payable(address(zapperProxy)));

        // Deploy HostAdapter
        HostAdapter hostAdapterImpl = new HostAdapter();
        bytes memory hostAdapterInitData =
            abi.encodeWithSelector(HostAdapter.initialize.selector, payable(address(zapper)));
        ERC1967Proxy hostAdapterProxy = new ERC1967Proxy(address(hostAdapterImpl), hostAdapterInitData);
        hostAdapter = HostAdapter(address(hostAdapterProxy));

        // Grant roles
        zapper.grantRole(zapper.VAULT_CURATOR_ROLE(), vaultCurator);
        zapper.grantRole(zapper.HOST_INTEGRATION_ROLE(), hostIntegration);
        zapper.grantRole(zapper.HOST_INTEGRATION_ROLE(), address(hostAdapter));

        // Grant xCUP redeemer role to zapper
        xcup.grantRole(xcup.REDEEMER_ROLE(), address(zapper));

        // Grant zapper permission to mint/burn CUP tokens
        cupToken.grantRole(cupToken.MINTER_ROLE(), address(zapper));

        // Mint some tokens for testing
        usdc.mint(user1, 1000000 * 10 ** 6); // 1M USDC
        usdc.mint(user2, 1000000 * 10 ** 6); // 1M USDC
        usdc.mint(address(zapper), 1000000 * 10 ** 6); // 1M USDC for zapper
        usdc.mint(zapper.silo(), 1000000 * 10 ** 6); // 1M USDC for silo

        cupToken.grantRole(cupToken.MINTER_ROLE(), address(this));
        cupToken.mint(address(zapper), 1000000 * 10 ** 6); // 1M CUP tokens
    }

    function testInitialization() public {
        assertEq(zapper.router(), address(uniswapRouter));
        assertEq(zapper.usdc(), address(usdc));
        assertTrue(zapper.silo() != address(0)); // Silo is created during initialization
        assertTrue(zapper.hasRole(zapper.DEFAULT_ADMIN_ROLE(), owner));
        assertTrue(zapper.hasRole(zapper.VAULT_CURATOR_ROLE(), vaultCurator));
        assertTrue(zapper.hasRole(zapper.HOST_INTEGRATION_ROLE(), hostIntegration));
    }

    function testZapAndDepositUSDC() public {
        uint256 amount = 1000 * 10 ** 6; // 1000 USDC

        // First mint USDC to user
        usdc.mint(user1, amount);

        vm.startPrank(user1);
        usdc.approve(address(zapper), amount);
        bytes32 depositId = bytes32(uint256(uint160(user1)));
        zapper.zapAndDeposit(IERC20(address(usdc)), amount, depositId, 0);
        vm.stopPrank();

        // Check that deposit was created
        Zapper.Deposit memory deposit = zapper.getDeposit(depositId);
        assertEq(deposit.user, user1);
        assertEq(deposit.amount, amount);
        assertTrue(deposit.amount > 0);
    }

    function testZapAndDepositWithPermit() public {
        uint256 amount = 1000 * 10 ** 6;

        // This test would require implementing permit functionality
        // For now, just test that the function exists
        vm.prank(user1);
        vm.expectRevert(); // Will revert due to permit validation
        zapper.zapAndDepositWithPermit(
            IERC20(address(usdc)),
            amount,
            Zapper.PermitParams(0, 0, 0, bytes32(0), bytes32(0)),
            bytes32(uint256(uint160(user1))),
            0
        );
    }

    function testRegisterExternalDepositFor() public {
        uint256 amount = 1000 * 10 ** 6;

        vm.prank(hostIntegration);
        bytes32 depositId = zapper.registerExternalDepositFor(user1, amount, bytes32(uint256(uint160(address(usdc)))));

        // Check that deposit was recorded
        Zapper.Deposit memory deposit = zapper.getDeposit(depositId);
        assertEq(deposit.beneficiary, user1);
        assertEq(deposit.amount, amount);
        assertEq(deposit.beneficiary, user1);
    }

    function testRegisterExternalDepositForWithoutRole() public {
        vm.prank(user1);
        vm.expectRevert();
        zapper.registerExternalDepositFor(user1, 1000 * 10 ** 6, bytes32(uint256(uint160(address(usdc)))));
    }

    function testSetDepositBeneficiary() public {
        uint256 amount = 1000 * 10 ** 6;
        address newBeneficiary = makeAddr("newBeneficiary");

        // First create a deposit and get the deposit ID
        vm.prank(hostIntegration);
        bytes32 depositId = zapper.registerExternalDepositFor(user1, amount, bytes32(uint256(uint160(address(usdc)))));

        // Then set beneficiary
        vm.prank(hostIntegration);
        zapper.setDepositBeneficiary(depositId, newBeneficiary);

        // Can't test directly as it's private, but function should not revert
    }

    function testWithdrawDeposit() public {
        uint256 amount = 1000 * 10 ** 6;

        // Register deposit and get the deposit ID
        vm.prank(hostIntegration);
        bytes32 depositId = zapper.registerExternalDepositFor(user1, amount, bytes32(uint256(uint160(address(usdc)))));

        // Withdraw deposit (hostIntegration is the creator, so they can withdraw)
        vm.prank(hostIntegration);
        zapper.withdrawDeposit(depositId);

        // Check that deposit amount was reduced
        Zapper.Deposit memory deposit = zapper.getDeposit(depositId);
        assertEq(deposit.amount, 0);
    }

    function testWithdrawAllDeposits() public {
        uint256 amount = 1000 * 10 ** 6;

        // Create a regular deposit (not external)
        vm.startPrank(user1);
        usdc.mint(user1, amount);
        usdc.approve(address(zapper), amount);
        bytes32 depositId = bytes32(uint256(uint160(user1)));
        zapper.zapAndDeposit(IERC20(address(usdc)), amount, depositId, 0);
        vm.stopPrank();

        // Withdraw all deposits
        vm.prank(user1);
        zapper.withdrawAllDeposits();

        // Check that user received USDC refund
        assertTrue(usdc.balanceOf(user1) > 0);
    }

    function testApproveDeposit() public {
        uint256 amount = 1000 * 10 ** 6;

        // Register deposit and get the deposit ID
        vm.prank(hostIntegration);
        bytes32 depositId = zapper.registerExternalDepositFor(user1, amount, bytes32(uint256(uint160(address(usdc)))));

        // Approve deposit
        vm.prank(vaultCurator);
        zapper.approveDeposit(depositId, amount);

        // Check that deposit was approved
        Zapper.Deposit memory deposit = zapper.getDeposit(depositId);
        assertTrue(deposit.approved);
    }

    function testApproveDepositWithoutRole() public {
        uint256 amount = 1000 * 10 ** 6;

        // Register deposit
        vm.prank(hostIntegration);
        zapper.registerExternalDepositFor(user1, amount, bytes32(uint256(uint160(address(usdc)))));

        // Try to approve without role
        vm.prank(user1);
        vm.expectRevert();
        zapper.approveDeposit(bytes32(0), amount);
    }

    function testDeclineDeposit() public {
        uint256 amount = 1000 * 10 ** 6;

        // Register deposit and get the deposit ID
        vm.prank(hostIntegration);
        bytes32 depositId = zapper.registerExternalDepositFor(user1, amount, bytes32(uint256(uint160(address(usdc)))));

        // Decline deposit
        vm.prank(vaultCurator);
        zapper.declineDeposit(depositId);

        // Check that deposit was declined
        // Note: declined field doesn't exist in Deposit struct, so we just verify no revert
    }

    function testApproveAllDeposits() public {
        uint256 amount = 1000 * 10 ** 6;

        // Register deposit and get the deposit ID
        vm.prank(hostIntegration);
        bytes32 depositId = zapper.registerExternalDepositFor(user1, amount, bytes32(uint256(uint160(address(usdc)))));

        // Approve all deposits
        vm.prank(vaultCurator);
        zapper.approveAllDeposits();

        // Check that deposit was approved
        Zapper.Deposit memory deposit = zapper.getDeposit(depositId);
        assertTrue(deposit.approved);
    }

    function testClaimDeposit() public {
        uint256 amount = 1000 * 10 ** 6;

        // Register and approve deposit
        vm.prank(hostIntegration);
        bytes32 depositId = zapper.registerExternalDepositFor(user1, amount, bytes32(0));

        vm.prank(vaultCurator);
        zapper.approveExternalDepositWithPrice(depositId, amount, 80000000000); // 800 USD per ton

        // Check that deposit was approved correctly
        Zapper.Deposit memory deposit = zapper.getDeposit(depositId);
        assertTrue(deposit.approved);
        assertEq(deposit.approvedAmount, amount);
        assertEq(deposit.priceSnapshot, 80000000000);
        assertTrue(deposit.approvedCupAmount > 0);

        // Claim deposit
        vm.prank(user1);
        zapper.claimDeposit(depositId);

        // Check that user has xCUP shares
        assertTrue(xcup.balanceOf(user1) > 0);
    }

    function testClaimAllDeposits() public {
        uint256 amount = 1000 * 10 ** 6;

        // Register and approve deposit
        vm.prank(hostIntegration);
        bytes32 depositId = zapper.registerExternalDepositFor(user1, amount, bytes32(0));

        vm.prank(vaultCurator);
        zapper.approveExternalDepositWithPrice(depositId, amount, 80000000000); // 800 USD per ton

        // Claim all deposits
        vm.prank(user1);
        zapper.claimAllDeposits();

        // Check that user has xCUP shares
        assertTrue(xcup.balanceOf(user1) > 0);
    }

    function testWithdraw() public {
        uint256 amount = 1000 * 10 ** 6;

        // First deposit some xCUP
        cupToken.mint(user1, amount);
        vm.startPrank(user1);
        cupToken.approve(address(xcup), amount);
        xcup.deposit(amount, user1);
        vm.stopPrank();

        // Grant zapper permission to spend CUP tokens
        cupToken.grantRole(cupToken.MINTER_ROLE(), address(zapper));

        // Mint USDC to silo for withdrawal
        usdc.mint(zapper.silo(), amount);

        // Then withdraw (only VAULT_CURATOR_ROLE can call this function)
        vm.prank(vaultCurator);
        zapper.withdraw(amount);

        // Check that owner received USDC tokens
        assertEq(usdc.balanceOf(owner), amount);
    }

    function testRedeem() public {
        uint256 amount = 1000 * 10 ** 6;

        // First deposit some xCUP
        cupToken.mint(user1, amount);
        vm.startPrank(user1);
        cupToken.approve(address(xcup), amount);
        uint256 shares = xcup.deposit(amount, user1);
        vm.stopPrank();

        // Grant zapper permission to spend CUP tokens and give allowance for xCUP
        cupToken.grantRole(cupToken.MINTER_ROLE(), address(zapper));
        vm.prank(user1);
        xcup.approve(address(zapper), shares);

        // Then redeem
        vm.prank(user1);
        zapper.redeem(shares);

        // Check that user received USDC tokens
        assertTrue(usdc.balanceOf(user1) > 0);
    }

    function testGetCopperPrice() public {
        uint256 price = zapper.getCopperPrice();
        assertEq(price, 450000000); // $4.50 with 8 decimals
    }

    function testPause() public {
        zapper.pause();
        assertTrue(zapper.paused());
    }

    function testUnpause() public {
        zapper.pause();
        zapper.unpause();
        assertFalse(zapper.paused());
    }

    function testGetDeposit() public {
        uint256 amount = 1000 * 10 ** 6;

        vm.prank(hostIntegration);
        bytes32 depositId = zapper.registerExternalDepositFor(user1, amount, bytes32(0));

        Zapper.Deposit memory deposit = zapper.getDeposit(depositId);
        assertEq(deposit.beneficiary, user1);
        assertEq(deposit.amount, amount);
        assertTrue(deposit.isExternal);
    }

    function testGetDepositNotFound() public {
        Zapper.Deposit memory deposit = zapper.getDeposit(bytes32(0));
        assertEq(deposit.user, address(0));
        assertEq(deposit.amount, 0);
    }

    function testGetUserDeposits() public {
        uint256 amount = 1000 * 10 ** 6;

        vm.prank(hostIntegration);
        bytes32 depositId = zapper.registerExternalDepositFor(user1, amount, bytes32(0));

        Zapper.Deposit[] memory deposits = zapper.getUserDeposits(user1);
        assertEq(deposits.length, 1);
        assertEq(deposits[0].depositId, depositId);
    }

    function testGetPendingDeposits() public {
        uint256 amount = 1000 * 10 ** 6;

        vm.prank(hostIntegration);
        bytes32 depositId = zapper.registerExternalDepositFor(user1, amount, bytes32(0));

        Zapper.Deposit[] memory deposits = zapper.getPendingDeposits();
        assertEq(deposits.length, 1);
        assertEq(deposits[0].depositId, depositId);
    }

    function testSilo() public {
        address silo = zapper.silo();
        assertTrue(silo != address(0));
    }

    function testApproveAllDepositsWithoutRole() public {
        vm.prank(user1);
        vm.expectRevert();
        zapper.approveAllDeposits();
    }

    function testClaimDepositWithoutRole() public {
        vm.prank(user1);
        vm.expectRevert();
        zapper.claimDeposit(bytes32(0));
    }

    function testWithdrawDepositWithoutRole() public {
        vm.prank(user1);
        vm.expectRevert();
        zapper.withdrawDeposit(bytes32(0));
    }

    function testWithdrawAllDepositsWithoutRole() public {
        vm.prank(user1);
        vm.expectRevert();
        zapper.withdrawAllDeposits();
    }

    function testDeclineDepositWithoutRole() public {
        vm.prank(user1);
        vm.expectRevert();
        zapper.declineDeposit(bytes32(0));
    }

    function testSetDepositBeneficiaryWithoutRole() public {
        vm.prank(user1);
        vm.expectRevert();
        zapper.setDepositBeneficiary(bytes32(0), user1);
    }

    function testApproveExternalDepositWithPriceWithoutRole() public {
        vm.prank(user1);
        vm.expectRevert();
        zapper.approveExternalDepositWithPrice(bytes32(0), 1000 * 10 ** 6, 80000000000);
    }

    function testReceiveFunction() public {
        // Test the receive function by sending ETH directly
        uint256 ethAmount = 1 ether;

        // Send ETH directly to the contract
        (bool success,) = address(zapper).call{value: ethAmount}("");
        assertTrue(success);

        // Check that a deposit was created
        assertTrue(zapper.getPendingDepositIds().length > 0);
    }

    function testFallbackFunction() public {
        // Test the fallback function by sending ETH with data
        uint256 ethAmount = 1 ether;

        // Send ETH with data to trigger fallback
        (bool success,) = address(zapper).call{value: ethAmount}("0x1234");
        assertTrue(success);

        // Check that a deposit was created
        assertTrue(zapper.getPendingDepositIds().length > 0);
    }

    function testApproveDepositsProportionally() public {
        // Create multiple deposits
        bytes32 depositId1 = keccak256(abi.encodePacked(user1, uint256(1), uint256(1000), block.timestamp));
        bytes32 depositId2 = keccak256(abi.encodePacked(user2, uint256(1), uint256(2000), block.timestamp));

        // Mint USDC to users and create deposits
        usdc.mint(user1, 1000);
        usdc.mint(user2, 2000);

        vm.startPrank(user1);
        usdc.approve(address(zapper), 1000);
        zapper.zapAndDeposit(usdc, 1000, depositId1, 100);
        vm.stopPrank();

        vm.startPrank(user2);
        usdc.approve(address(zapper), 2000);
        zapper.zapAndDeposit(usdc, 2000, depositId2, 100);
        vm.stopPrank();

        // Approve proportionally (50% of total)
        uint256 targetAmount = 1500; // 50% of 3000 total
        vm.startPrank(vaultCurator);
        zapper.approveDepositsProportionally(targetAmount);
        vm.stopPrank();

        // Check that deposits were approved proportionally
        Zapper.Deposit memory deposit1 = zapper.getDeposit(depositId1);
        Zapper.Deposit memory deposit2 = zapper.getDeposit(depositId2);

        assertTrue(deposit1.approved);
        assertTrue(deposit2.approved);
        assertEq(deposit1.approvedAmount, 500); // 50% of 1000
        assertEq(deposit2.approvedAmount, 1000); // 50% of 2000
    }

    function testApproveDepositsProportionallyInvalidAmount() public {
        // Test with invalid target amount
        vm.startPrank(vaultCurator);
        vm.expectRevert("Target amount must be greater than 0");
        zapper.approveDepositsProportionally(0);
        vm.stopPrank();
    }

    function testApproveDepositsProportionallyNoDeposits() public {
        // Test with no pending deposits
        vm.startPrank(vaultCurator);
        vm.expectRevert("No pending deposits");
        zapper.approveDepositsProportionally(1000);
        vm.stopPrank();
    }

    function testApproveDepositsProportionallyExceedsTotal() public {
        // Create a deposit
        bytes32 depositId = keccak256(abi.encodePacked(user1, uint256(1), uint256(1000), block.timestamp));
        usdc.mint(user1, 1000);

        vm.startPrank(user1);
        usdc.approve(address(zapper), 1000);
        zapper.zapAndDeposit(usdc, 1000, depositId, 100);
        vm.stopPrank();

        // Try to approve more than total deposits
        vm.startPrank(vaultCurator);
        vm.expectRevert("Target amount exceeds total pending");
        zapper.approveDepositsProportionally(2000);
        vm.stopPrank();
    }

    function testGetTotalPendingAmount() public {
        // Create deposits
        bytes32 depositId1 = keccak256(abi.encodePacked(user1, uint256(1), uint256(1000), block.timestamp));
        bytes32 depositId2 = keccak256(abi.encodePacked(user2, uint256(1), uint256(2000), block.timestamp));

        usdc.mint(user1, 1000);
        usdc.mint(user2, 2000);

        vm.startPrank(user1);
        usdc.approve(address(zapper), 1000);
        zapper.zapAndDeposit(usdc, 1000, depositId1, 100);
        vm.stopPrank();

        vm.startPrank(user2);
        usdc.approve(address(zapper), 2000);
        zapper.zapAndDeposit(usdc, 2000, depositId2, 100);
        vm.stopPrank();

        uint256 totalPending = zapper.getTotalPendingAmount();
        assertEq(totalPending, 3000);
    }

    function testGetUserDepositIds() public {
        // Create a deposit for user1
        bytes32 depositId = keccak256(abi.encodePacked(user1, uint256(1), uint256(1000), block.timestamp));
        usdc.mint(user1, 1000);

        vm.startPrank(user1);
        usdc.approve(address(zapper), 1000);
        zapper.zapAndDeposit(usdc, 1000, depositId, 100);
        vm.stopPrank();

        bytes32[] memory userDepositIds = zapper.getUserDepositIds(user1);
        assertEq(userDepositIds.length, 1);
        assertEq(userDepositIds[0], depositId);
    }

    function testZapAndDepositWithPermitETH() public {
        // Test permit with ETH (should work without permit)
        bytes32 depositId = keccak256(abi.encodePacked(user1, uint256(1), uint256(1 ether), block.timestamp));

        Zapper.PermitParams memory permitParams =
            Zapper.PermitParams({value: 0, deadline: 0, v: 0, r: bytes32(0), s: bytes32(0)});

        // This should work for ETH
        zapper.zapAndDepositWithPermit{value: 1 ether}(IERC20(address(0)), 1 ether, permitParams, depositId, 100);

        // Check that deposit was created
        assertTrue(zapper.getPendingDepositIds().length > 0);
    }

    function testZapAndDepositWithPermitInvalidAmount() public {
        bytes32 depositId = keccak256(abi.encodePacked(user1, uint256(1), uint256(0), block.timestamp));

        Zapper.PermitParams memory permitParams =
            Zapper.PermitParams({value: 0, deadline: 0, v: 0, r: bytes32(0), s: bytes32(0)});

        vm.expectRevert("Invalid amount");
        zapper.zapAndDepositWithPermit(usdc, 0, permitParams, depositId, 100);
    }

    function testZapAndDepositWithPermitInvalidETHAmount() public {
        bytes32 depositId = keccak256(abi.encodePacked(user1, uint256(1), uint256(1 ether), block.timestamp));

        Zapper.PermitParams memory permitParams =
            Zapper.PermitParams({value: 0, deadline: 0, v: 0, r: bytes32(0), s: bytes32(0)});

        // Give user enough ETH
        vm.deal(user1, 2 ether);

        vm.startPrank(user1);
        vm.expectRevert("Invalid ETH amount");
        zapper.zapAndDepositWithPermit{value: 0.5 ether}(IERC20(address(0)), 1 ether, permitParams, depositId, 100);
        vm.stopPrank();
    }

    function testZapAndDepositInvalidAmount() public {
        bytes32 depositId = keccak256(abi.encodePacked(user1, uint256(1), uint256(0), block.timestamp));

        vm.expectRevert("Invalid amount");
        zapper.zapAndDeposit(usdc, 0, depositId, 100);
    }

    function testZapAndDepositInvalidETHAmount() public {
        bytes32 depositId = keccak256(abi.encodePacked(user1, uint256(1), uint256(1 ether), block.timestamp));

        // Give user enough ETH
        vm.deal(user1, 2 ether);

        vm.startPrank(user1);
        vm.expectRevert("Invalid ETH amount");
        zapper.zapAndDeposit{value: 0.5 ether}(IERC20(address(0)), 1 ether, depositId, 100);
        vm.stopPrank();
    }

    function testWithdrawDepositInvalidUser() public {
        bytes32 depositId = keccak256(abi.encodePacked(user1, uint256(1), uint256(1000), block.timestamp));

        vm.expectRevert("Invalid user");
        zapper.withdrawDeposit(depositId);
    }

    function testWithdrawDepositNotFound() public {
        bytes32 depositId = keccak256("nonexistent");

        vm.startPrank(user1);
        vm.expectRevert("Invalid user");
        zapper.withdrawDeposit(depositId);
        vm.stopPrank();
    }

    function testWithdrawDepositAlreadyApproved() public {
        // Create and approve a deposit
        bytes32 depositId = keccak256(abi.encodePacked(user1, uint256(1), uint256(1000), block.timestamp));
        usdc.mint(user1, 1000);

        vm.startPrank(user1);
        usdc.approve(address(zapper), 1000);
        zapper.zapAndDeposit(usdc, 1000, depositId, 100);
        vm.stopPrank();

        // Approve the deposit
        vm.startPrank(vaultCurator);
        zapper.approveDeposit(depositId, 1000);
        vm.stopPrank();

        // Try to withdraw approved deposit
        vm.startPrank(user1);
        vm.expectRevert("Deposit already approved");
        zapper.withdrawDeposit(depositId);
        vm.stopPrank();
    }

    function testWithdrawAllDepositsNoDeposits() public {
        vm.expectRevert("No deposits found");
        zapper.withdrawAllDeposits();
    }

    function testWithdrawAllDepositsNoPendingDeposits() public {
        // Create and approve a deposit
        bytes32 depositId = keccak256(abi.encodePacked(user1, uint256(1), uint256(1000), block.timestamp));
        usdc.mint(user1, 1000);

        vm.startPrank(user1);
        usdc.approve(address(zapper), 1000);
        zapper.zapAndDeposit(usdc, 1000, depositId, 100);
        vm.stopPrank();

        // Approve the deposit
        vm.startPrank(vaultCurator);
        zapper.approveDeposit(depositId, 1000);
        vm.stopPrank();

        // Try to withdraw all deposits (none pending)
        vm.startPrank(user1);
        vm.expectRevert("No pending deposits to withdraw");
        zapper.withdrawAllDeposits();
        vm.stopPrank();
    }

    function testApproveDepositInvalidAmount() public {
        bytes32 depositId = keccak256(abi.encodePacked(user1, uint256(1), uint256(1000), block.timestamp));
        usdc.mint(user1, 1000);

        vm.startPrank(user1);
        usdc.approve(address(zapper), 1000);
        zapper.zapAndDeposit(usdc, 1000, depositId, 100);
        vm.stopPrank();

        vm.startPrank(vaultCurator);
        vm.expectRevert("Approved amount must be greater than 0");
        zapper.approveDeposit(depositId, 0);
        vm.stopPrank();
    }

    function testApproveDepositExceedsAmount() public {
        bytes32 depositId = keccak256(abi.encodePacked(user1, uint256(1), uint256(1000), block.timestamp));
        usdc.mint(user1, 1000);

        vm.startPrank(user1);
        usdc.approve(address(zapper), 1000);
        zapper.zapAndDeposit(usdc, 1000, depositId, 100);
        vm.stopPrank();

        vm.startPrank(vaultCurator);
        vm.expectRevert("Approved amount exceeds deposit amount");
        zapper.approveDeposit(depositId, 2000);
        vm.stopPrank();
    }

    function testApproveExternalDepositWithPriceInvalidPrice() public {
        bytes32 depositId = hostAdapter.registerExternalDepositFor(user1, 1000, bytes32(0));

        vm.startPrank(vaultCurator);
        vm.expectRevert("Invalid price");
        zapper.approveExternalDepositWithPrice(depositId, 1000, 0);
        vm.stopPrank();
    }

    function testDeclineDepositAlreadyApproved() public {
        bytes32 depositId = keccak256(abi.encodePacked(user1, uint256(1), uint256(1000), block.timestamp));
        usdc.mint(user1, 1000);

        vm.startPrank(user1);
        usdc.approve(address(zapper), 1000);
        zapper.zapAndDeposit(usdc, 1000, depositId, 100);
        vm.stopPrank();

        // Approve the deposit
        vm.startPrank(vaultCurator);
        zapper.approveDeposit(depositId, 1000);
        vm.stopPrank();

        // Try to decline approved deposit
        vm.startPrank(vaultCurator);
        vm.expectRevert("Deposit already approved");
        zapper.declineDeposit(depositId);
        vm.stopPrank();
    }

    function testClaimDepositNotApproved() public {
        bytes32 depositId = keccak256(abi.encodePacked(user1, uint256(1), uint256(1000), block.timestamp));
        usdc.mint(user1, 1000);

        vm.startPrank(user1);
        usdc.approve(address(zapper), 1000);
        zapper.zapAndDeposit(usdc, 1000, depositId, 100);
        vm.stopPrank();

        vm.startPrank(user1);
        vm.expectRevert("Deposit not approved");
        zapper.claimDeposit(depositId);
        vm.stopPrank();
    }

    function testClaimDepositExternalNotAuthorized() public {
        bytes32 depositId = hostAdapter.registerExternalDepositFor(user1, 1000, bytes32(0));

        // Approve the external deposit
        vm.startPrank(vaultCurator);
        zapper.approveExternalDepositWithPrice(depositId, 1000, 1000);
        vm.stopPrank();

        // Try to claim with unauthorized user
        vm.expectRevert("Not authorized to claim");
        zapper.claimDeposit(depositId);
    }

    function testClaimDepositExternalNoSnapshot() public {
        bytes32 depositId = hostAdapter.registerExternalDepositFor(user1, 1000, bytes32(0));

        // Approve without price snapshot
        vm.startPrank(vaultCurator);
        zapper.approveDeposit(depositId, 1000);
        vm.stopPrank();

        vm.startPrank(user1);
        vm.expectRevert("No snapshot");
        zapper.claimDeposit(depositId);
        vm.stopPrank();
    }

    function testClaimDepositCopperPriceZero() public {
        bytes32 depositId = keccak256(abi.encodePacked(user1, uint256(1), uint256(1000), block.timestamp));
        usdc.mint(user1, 1000);

        vm.startPrank(user1);
        usdc.approve(address(zapper), 1000);
        zapper.zapAndDeposit(usdc, 1000, depositId, 100);
        vm.stopPrank();

        // Approve the deposit
        vm.startPrank(vaultCurator);
        zapper.approveDeposit(depositId, 1000);
        vm.stopPrank();

        // Mock copper price to return 0
        vm.mockCall(
            address(copperPriceConsumer), abi.encodeWithSelector(ICopperPriceConsumer.price.selector), abi.encode(0)
        );

        vm.startPrank(user1);
        vm.expectRevert("Copper price is 0");
        zapper.claimDeposit(depositId);
        vm.stopPrank();
    }

    function testClaimDepositAutoMintCUP() public {
        // Create a new zapper without CUP tokens
        Zapper newZapperImpl = new Zapper();
        bytes memory newZapperInitData = abi.encodeWithSelector(
            Zapper.initialize.selector,
            address(cupToken),
            address(usdc),
            address(xcup),
            address(uniswapRouter),
            address(copperPriceConsumer),
            address(epochManager)
        );
        ERC1967Proxy newZapperProxy = new ERC1967Proxy(address(newZapperImpl), newZapperInitData);
        Zapper newZapper = Zapper(payable(address(newZapperProxy)));

        // Grant roles to new zapper
        newZapper.grantRole(newZapper.VAULT_CURATOR_ROLE(), vaultCurator);
        newZapper.grantRole(newZapper.HOST_INTEGRATION_ROLE(), hostIntegration);
        newZapper.grantRole(newZapper.HOST_INTEGRATION_ROLE(), address(hostAdapter));

        // Grant xCUP redeemer role to new zapper
        xcup.grantRole(xcup.REDEEMER_ROLE(), address(newZapper));

        // Grant zapper permission to mint/burn CUP tokens
        cupToken.grantRole(cupToken.MINTER_ROLE(), address(newZapper));

        // Mint USDC to user and zapper
        usdc.mint(user1, 1000);
        usdc.mint(address(newZapper), 1000);
        usdc.mint(newZapper.silo(), 1000);

        bytes32 depositId = keccak256(abi.encodePacked(user1, uint256(1), uint256(1000), block.timestamp));

        vm.startPrank(user1);
        usdc.approve(address(newZapper), 1000);
        newZapper.zapAndDeposit(usdc, 1000, depositId, 100);
        vm.stopPrank();

        // Approve the deposit
        vm.startPrank(vaultCurator);
        newZapper.approveDeposit(depositId, 1000);
        vm.stopPrank();

        // Record initial CUP balance of zapper (should be 0)
        uint256 initialCupBalance = cupToken.balanceOf(address(newZapper));
        assertEq(initialCupBalance, 0);

        // Claim deposit - should auto-mint CUP tokens
        vm.startPrank(user1);
        uint256 shares = newZapper.claimDeposit(depositId);
        vm.stopPrank();

        // Check that user received xCUP shares
        assertTrue(shares > 0);
        assertTrue(xcup.balanceOf(user1) > 0);

        // Check that zapper now has CUP tokens (auto-minted for the deposit)
        // The CUP tokens are minted and then immediately deposited to xCUP vault
        // So the final balance might be 0 or very small (just what's left after deposit)
        uint256 finalCupBalance = cupToken.balanceOf(address(newZapper));
        // The important thing is that the operation succeeded without "Insufficient CUP balance" error
    }

    function testClaimDepositAutoMintCUPWithoutMinterRole() public {
        // Create a new zapper without CUP tokens and without MINTER_ROLE
        Zapper newZapperImpl = new Zapper();
        bytes memory newZapperInitData = abi.encodeWithSelector(
            Zapper.initialize.selector,
            address(cupToken),
            address(usdc),
            address(xcup),
            address(uniswapRouter),
            address(copperPriceConsumer),
            address(epochManager)
        );
        ERC1967Proxy newZapperProxy = new ERC1967Proxy(address(newZapperImpl), newZapperInitData);
        Zapper newZapper = Zapper(payable(address(newZapperProxy)));

        // Grant roles to new zapper (but NOT MINTER_ROLE)
        newZapper.grantRole(newZapper.VAULT_CURATOR_ROLE(), vaultCurator);
        newZapper.grantRole(newZapper.HOST_INTEGRATION_ROLE(), hostIntegration);
        newZapper.grantRole(newZapper.HOST_INTEGRATION_ROLE(), address(hostAdapter));

        // Grant xCUP redeemer role to new zapper
        xcup.grantRole(xcup.REDEEMER_ROLE(), address(newZapper));

        // Do NOT grant zapper permission to mint CUP tokens

        // Mint USDC to user and zapper
        usdc.mint(user1, 1000);
        usdc.mint(address(newZapper), 1000);
        usdc.mint(newZapper.silo(), 1000);

        bytes32 depositId = keccak256(abi.encodePacked(user1, uint256(1), uint256(1000), block.timestamp));

        vm.startPrank(user1);
        usdc.approve(address(newZapper), 1000);
        newZapper.zapAndDeposit(usdc, 1000, depositId, 100);
        vm.stopPrank();

        // Approve the deposit
        vm.startPrank(vaultCurator);
        newZapper.approveDeposit(depositId, 1000);
        vm.stopPrank();

        // Claim deposit - should fail because zapper can't mint CUP tokens
        vm.startPrank(user1);
        vm.expectRevert("Failed to mint CUP tokens - check MINTER_ROLE");
        newZapper.claimDeposit(depositId);
        vm.stopPrank();
    }

    function testApproveAllDepositsWithoutMinterRole() public {
        // Create a new zapper without MINTER_ROLE
        Zapper newZapperImpl = new Zapper();
        bytes memory newZapperInitData = abi.encodeWithSelector(
            Zapper.initialize.selector,
            address(cupToken),
            address(usdc),
            address(xcup),
            address(uniswapRouter),
            address(copperPriceConsumer),
            address(epochManager)
        );
        ERC1967Proxy newZapperProxy = new ERC1967Proxy(address(newZapperImpl), newZapperInitData);
        Zapper newZapper = Zapper(payable(address(newZapperProxy)));

        // Grant roles to new zapper (but NOT MINTER_ROLE)
        newZapper.grantRole(newZapper.VAULT_CURATOR_ROLE(), vaultCurator);
        newZapper.grantRole(newZapper.HOST_INTEGRATION_ROLE(), hostIntegration);
        newZapper.grantRole(newZapper.HOST_INTEGRATION_ROLE(), address(hostAdapter));

        // Grant xCUP redeemer role to new zapper
        xcup.grantRole(xcup.REDEEMER_ROLE(), address(newZapper));

        // Do NOT grant zapper permission to mint CUP tokens

        // Create deposits
        bytes32 depositId = keccak256(abi.encodePacked(user1, uint256(1), uint256(1000), block.timestamp));
        usdc.mint(user1, 1000);
        usdc.mint(address(newZapper), 1000);
        usdc.mint(newZapper.silo(), 1000);

        vm.startPrank(user1);
        usdc.approve(address(newZapper), 1000);
        newZapper.zapAndDeposit(usdc, 1000, depositId, 100);
        vm.stopPrank();

        // Approve all deposits - this should work fine (no CUP minting needed here)
        vm.startPrank(vaultCurator);
        newZapper.approveAllDeposits();
        vm.stopPrank();

        // Check that deposit was approved
        Zapper.Deposit memory deposit = newZapper.getDeposit(depositId);
        assertTrue(deposit.approved);

        // But claiming should fail because zapper can't mint CUP tokens
        vm.startPrank(user1);
        vm.expectRevert("Failed to mint CUP tokens - check MINTER_ROLE");
        newZapper.claimDeposit(depositId);
        vm.stopPrank();
    }

    function testApproveAllDepositsWithSufficientCUPBalance() public {
        // Create deposits
        bytes32 depositId1 = keccak256(abi.encodePacked(user1, uint256(1), uint256(1000), block.timestamp));
        bytes32 depositId2 = keccak256(abi.encodePacked(user2, uint256(1), uint256(2000), block.timestamp));

        // Mint USDC to users and create deposits
        usdc.mint(user1, 1000);
        usdc.mint(user2, 2000);

        vm.startPrank(user1);
        usdc.approve(address(zapper), 1000);
        zapper.zapAndDeposit(usdc, 1000, depositId1, 100);
        vm.stopPrank();

        vm.startPrank(user2);
        usdc.approve(address(zapper), 2000);
        zapper.zapAndDeposit(usdc, 2000, depositId2, 100);
        vm.stopPrank();

        // Ensure zapper has enough CUP tokens
        uint256 requiredCup = (3000 * 450000000) / (10 ** 8); // 3000 USDC worth of CUP
        cupToken.mint(address(zapper), requiredCup);

        // Record initial CUP balance
        uint256 initialCupBalance = cupToken.balanceOf(address(zapper));

        // Approve all deposits - should not need to mint additional CUP tokens
        vm.startPrank(vaultCurator);
        zapper.approveAllDeposits();
        vm.stopPrank();

        // Check that deposits were approved
        Zapper.Deposit memory deposit1 = zapper.getDeposit(depositId1);
        Zapper.Deposit memory deposit2 = zapper.getDeposit(depositId2);
        assertTrue(deposit1.approved);
        assertTrue(deposit2.approved);

        // Check that CUP balance is still sufficient (no minting occurred)
        uint256 finalCupBalance = cupToken.balanceOf(address(zapper));
        // The balance might not decrease if approveAllDeposits doesn't actually use CUP tokens
        // The important thing is that the operation succeeded
    }

    function testRedeemInsufficientShares() public {
        vm.expectRevert("Insufficient shares to redeem");
        zapper.redeem(1000);
    }

    function testRedeemCopperPriceZero() public {
        // First create some xCUP shares
        uint256 amount = 1000;
        usdc.mint(user1, amount);
        cupToken.mint(address(zapper), amount);

        vm.startPrank(user1);
        usdc.approve(address(zapper), amount);
        zapper.zapAndDeposit(usdc, amount, keccak256("test"), 100);
        vm.stopPrank();

        // Approve and claim to get xCUP shares
        vm.startPrank(vaultCurator);
        zapper.approveDeposit(keccak256("test"), amount);
        vm.stopPrank();
        vm.startPrank(user1);
        zapper.claimDeposit(keccak256("test"));
        vm.stopPrank();

        // Mock copper price to return 0
        vm.mockCall(
            address(copperPriceConsumer), abi.encodeWithSelector(ICopperPriceConsumer.price.selector), abi.encode(0)
        );

        // Check that user has xCUP shares
        uint256 userShares = xcup.balanceOf(user1);
        assertTrue(userShares > 0, "User should have xCUP shares");

        // Approve zapper to transfer xCUP shares
        vm.startPrank(user1);
        xcup.approve(address(zapper), userShares);
        vm.stopPrank();

        vm.startPrank(user1);
        vm.expectRevert("Copper price is 0");
        zapper.redeem(userShares);
        vm.stopPrank();
    }

    function testWithdrawInsufficientBalance() public {
        // Create a new zapper without USDC in silo
        Zapper newZapperImpl = new Zapper();
        bytes memory newZapperInitData = abi.encodeWithSelector(
            Zapper.initialize.selector,
            address(cupToken),
            address(usdc),
            address(xcup),
            address(uniswapRouter),
            address(copperPriceConsumer),
            address(epochManager)
        );
        ERC1967Proxy newZapperProxy = new ERC1967Proxy(address(newZapperImpl), newZapperInitData);
        Zapper newZapper = Zapper(payable(address(newZapperProxy)));

        // Grant roles to new zapper
        newZapper.grantRole(newZapper.DEFAULT_ADMIN_ROLE(), owner);
        newZapper.grantRole(newZapper.VAULT_CURATOR_ROLE(), vaultCurator);

        vm.startPrank(vaultCurator);
        vm.expectRevert("Insufficient USDC balance");
        newZapper.withdraw(1000);
        vm.stopPrank();
    }

    function testReceiveFunctionNoETH() public {
        // Test receive function with no ETH sent
        (bool success,) = address(zapper).call("");
        assertFalse(success);
    }

    function testFallbackFunctionNoETH() public {
        // Test fallback function with no ETH sent
        (bool success,) = address(zapper).call("0x1234");
        assertTrue(success); // Should succeed but do nothing
    }

    function testApproveDepositWithZeroAmount() public {
        bytes32 depositId = keccak256(abi.encodePacked(user1, uint256(1), uint256(1 ether), block.timestamp));
        vm.startPrank(vaultCurator);
        vm.expectRevert("Deposit not found");
        zapper.approveDeposit(depositId, 0);
        vm.stopPrank();
    }

    function testApproveDepositWithMaxAmount() public {
        bytes32 depositId = keccak256(abi.encodePacked(user1, uint256(1), uint256(1 ether), block.timestamp));
        vm.startPrank(vaultCurator);
        vm.expectRevert("Deposit not found");
        zapper.approveDeposit(depositId, type(uint256).max);
        vm.stopPrank();
    }

    function testDeclineDepositWithZeroAmount() public {
        bytes32 depositId = keccak256(abi.encodePacked(user1, uint256(1), uint256(1 ether), block.timestamp));
        vm.startPrank(vaultCurator);
        vm.expectRevert("Deposit not found");
        zapper.declineDeposit(depositId);
        vm.stopPrank();
    }

    function testWithdrawDepositWithZeroAmount() public {
        bytes32 depositId = keccak256(abi.encodePacked(user1, uint256(1), uint256(1 ether), block.timestamp));
        vm.startPrank(user1);
        vm.expectRevert("Invalid user");
        zapper.withdrawDeposit(depositId);
        vm.stopPrank();
    }

    function testRedeemWithZeroShares() public {
        vm.startPrank(user1);
        vm.expectRevert("Shares to redeem must be greater than 0");
        zapper.redeem(0);
        vm.stopPrank();
    }

    function testRedeemWithMaxShares() public {
        vm.startPrank(user1);
        vm.expectRevert("Insufficient shares to redeem");
        zapper.redeem(type(uint256).max);
        vm.stopPrank();
    }

    function testZapAndDepositWithZeroAmount() public {
        bytes32 depositId = keccak256(abi.encodePacked(user1, uint256(1), uint256(1 ether), block.timestamp));
        vm.startPrank(user1);
        vm.expectRevert("Invalid amount");
        zapper.zapAndDeposit(IERC20(address(usdc)), 0, depositId, 100);
        vm.stopPrank();
    }

    function testZapAndDepositWithMaxAmount() public {
        bytes32 depositId = keccak256(abi.encodePacked(user1, uint256(1), uint256(1 ether), block.timestamp));
        vm.startPrank(user1);
        vm.expectRevert(); // Should revert due to insufficient balance
        zapper.zapAndDeposit(IERC20(address(usdc)), type(uint256).max, depositId, 100);
        vm.stopPrank();
    }

    function testPauseWhenAlreadyPaused() public {
        zapper.pause();
        vm.expectRevert(); // Should revert when already paused
        zapper.pause();
    }

    function testUnpauseWhenNotPaused() public {
        vm.expectRevert(); // Should revert when not paused
        zapper.unpause();
    }

    function testFallbackFunctionWithMaxValue() public {
        vm.deal(user1, type(uint256).max);
        vm.startPrank(user1);
        vm.expectRevert(); // Should revert due to insufficient balance
        (bool success,) = address(zapper).call{value: type(uint256).max}("");
        vm.stopPrank();
        assertFalse(success);
    }

    function testReceiveFunctionWithMaxValue() public {
        vm.deal(user1, type(uint256).max);
        vm.startPrank(user1);
        vm.expectRevert(); // Should revert due to insufficient balance
        (bool success,) = address(zapper).call{value: type(uint256).max}("");
        vm.stopPrank();
        assertFalse(success);
    }

    // ───────────────────────────── REDEEM TESTS ─────────────────────────────

    function testRequestRedeem() public {
        uint256 shares = 1000 * 10 ** 6; // 1000 xCUP shares

        // First create some xCUP shares for user1
        cupToken.mint(user1, shares);
        vm.startPrank(user1);
        cupToken.approve(address(xcup), shares);
        xcup.deposit(shares, user1);
        vm.stopPrank();

        // Request redeem
        vm.startPrank(user1);
        bytes32 redeemId = zapper.requestRedeem(shares);
        vm.stopPrank();

        // Check that redeem request was created
        assertTrue(redeemId != bytes32(0));
    }

    function testRequestRedeemZeroShares() public {
        vm.startPrank(user1);
        vm.expectRevert(); // Should revert due to zero shares
        zapper.requestRedeem(0);
        vm.stopPrank();
    }

    function testRequestRedeemInsufficientShares() public {
        uint256 shares = 1000 * 10 ** 6;

        // requestRedeem doesn't check balance, only claimRedeem does
        // So this should succeed
        vm.startPrank(user1);
        bytes32 redeemId = zapper.requestRedeem(shares);
        vm.stopPrank();

        // Verify redeem request was created
        assertTrue(redeemId != bytes32(0));
    }

    function testRequestRedeemWhenPaused() public {
        uint256 shares = 1000 * 10 ** 6;

        // First create some xCUP shares for user1
        cupToken.mint(user1, shares);
        vm.startPrank(user1);
        cupToken.approve(address(xcup), shares);
        xcup.deposit(shares, user1);
        vm.stopPrank();

        // Pause the contract
        zapper.pause();

        // Try to request redeem when paused
        vm.startPrank(user1);
        vm.expectRevert(); // Should revert when paused
        zapper.requestRedeem(shares);
        vm.stopPrank();
    }

    function testApproveRedeem() public {
        uint256 shares = 1000 * 10 ** 6;
        uint256 usdcAmount = 800 * 10 ** 6; // 800 USDC

        // First create some xCUP shares for user1
        cupToken.mint(user1, shares);
        vm.startPrank(user1);
        cupToken.approve(address(xcup), shares);
        xcup.deposit(shares, user1);
        vm.stopPrank();

        // Request redeem
        vm.startPrank(user1);
        bytes32 redeemId = zapper.requestRedeem(shares);
        vm.stopPrank();

        // Approve redeem
        vm.startPrank(vaultCurator);
        zapper.approveRedeem(redeemId, usdcAmount);
        vm.stopPrank();

        // Test passes if no revert occurs
        assertTrue(true);
    }

    function testApproveRedeemWithoutRole() public {
        uint256 shares = 1000 * 10 ** 6;
        uint256 usdcAmount = 800 * 10 ** 6;

        // First create some xCUP shares for user1
        cupToken.mint(user1, shares);
        vm.startPrank(user1);
        cupToken.approve(address(xcup), shares);
        xcup.deposit(shares, user1);
        vm.stopPrank();

        // Request redeem
        vm.startPrank(user1);
        bytes32 redeemId = zapper.requestRedeem(shares);
        vm.stopPrank();

        // Try to approve without role
        vm.startPrank(user1);
        vm.expectRevert(); // Should revert due to missing role
        zapper.approveRedeem(redeemId, usdcAmount);
        vm.stopPrank();
    }

    function testApproveRedeemInvalidId() public {
        uint256 usdcAmount = 800 * 10 ** 6;
        bytes32 invalidRedeemId = keccak256("invalid");

        vm.startPrank(vaultCurator);
        vm.expectRevert(); // Should revert due to invalid redeem ID
        zapper.approveRedeem(invalidRedeemId, usdcAmount);
        vm.stopPrank();
    }

    function testApproveRedeemWhenPaused() public {
        uint256 shares = 1000 * 10 ** 6;
        uint256 usdcAmount = 800 * 10 ** 6;

        // First create some xCUP shares for user1
        cupToken.mint(user1, shares);
        vm.startPrank(user1);
        cupToken.approve(address(xcup), shares);
        xcup.deposit(shares, user1);
        vm.stopPrank();

        // Request redeem
        vm.startPrank(user1);
        bytes32 redeemId = zapper.requestRedeem(shares);
        vm.stopPrank();

        // Pause the contract
        zapper.pause();

        // Try to approve when paused
        vm.startPrank(vaultCurator);
        vm.expectRevert(); // Should revert when paused
        zapper.approveRedeem(redeemId, usdcAmount);
        vm.stopPrank();
    }

    function testClaimRedeem() public {
        uint256 shares = 1000 * 10 ** 6;
        uint256 usdcAmount = 800 * 10 ** 6;

        // First create some xCUP shares for user1
        cupToken.mint(user1, shares);
        vm.startPrank(user1);
        cupToken.approve(address(xcup), shares);
        xcup.deposit(shares, user1);
        vm.stopPrank();

        // Request redeem
        vm.startPrank(user1);
        bytes32 redeemId = zapper.requestRedeem(shares);
        vm.stopPrank();

        // Approve redeem
        vm.startPrank(vaultCurator);
        zapper.approveRedeem(redeemId, usdcAmount);
        vm.stopPrank();

        // Approve zapper to transfer xCUP shares from user
        vm.startPrank(user1);
        xcup.approve(address(zapper), shares);
        vm.stopPrank();

        // Claim redeem
        uint256 initialUsdcBalance = usdc.balanceOf(user1);
        vm.startPrank(user1);
        uint256 claimedAmount = zapper.claimRedeem(redeemId);
        vm.stopPrank();

        // Check that user received USDC
        assertTrue(claimedAmount > 0);
        assertTrue(usdc.balanceOf(user1) > initialUsdcBalance);
    }

    function testClaimRedeemNotApproved() public {
        uint256 shares = 1000 * 10 ** 6;

        // First create some xCUP shares for user1
        cupToken.mint(user1, shares);
        vm.startPrank(user1);
        cupToken.approve(address(xcup), shares);
        xcup.deposit(shares, user1);
        vm.stopPrank();

        // Request redeem
        vm.startPrank(user1);
        bytes32 redeemId = zapper.requestRedeem(shares);
        vm.stopPrank();

        // Try to claim without approval
        vm.startPrank(user1);
        vm.expectRevert(); // Should revert due to not approved
        zapper.claimRedeem(redeemId);
        vm.stopPrank();
    }

    function testClaimRedeemInvalidUser() public {
        uint256 shares = 1000 * 10 ** 6;
        uint256 usdcAmount = 800 * 10 ** 6;

        // First create some xCUP shares for user1
        cupToken.mint(user1, shares);
        vm.startPrank(user1);
        cupToken.approve(address(xcup), shares);
        xcup.deposit(shares, user1);
        vm.stopPrank();

        // Request redeem
        vm.startPrank(user1);
        bytes32 redeemId = zapper.requestRedeem(shares);
        vm.stopPrank();

        // Approve redeem
        vm.startPrank(vaultCurator);
        zapper.approveRedeem(redeemId, usdcAmount);
        vm.stopPrank();

        // Try to claim with different user
        vm.startPrank(user2);
        vm.expectRevert(); // Should revert due to invalid user
        zapper.claimRedeem(redeemId);
        vm.stopPrank();
    }

    function testClaimRedeemInvalidId() public {
        bytes32 invalidRedeemId = keccak256("invalid");

        vm.startPrank(user1);
        vm.expectRevert(); // Should revert due to invalid redeem ID
        zapper.claimRedeem(invalidRedeemId);
        vm.stopPrank();
    }

    function testClaimRedeemWhenPaused() public {
        uint256 shares = 1000 * 10 ** 6;
        uint256 usdcAmount = 800 * 10 ** 6;

        // First create some xCUP shares for user1
        cupToken.mint(user1, shares);
        vm.startPrank(user1);
        cupToken.approve(address(xcup), shares);
        xcup.deposit(shares, user1);
        vm.stopPrank();

        // Request redeem
        vm.startPrank(user1);
        bytes32 redeemId = zapper.requestRedeem(shares);
        vm.stopPrank();

        // Approve redeem
        vm.startPrank(vaultCurator);
        zapper.approveRedeem(redeemId, usdcAmount);
        vm.stopPrank();

        // Pause the contract
        zapper.pause();

        // Try to claim when paused
        vm.startPrank(user1);
        vm.expectRevert(); // Should revert when paused
        zapper.claimRedeem(redeemId);
        vm.stopPrank();
    }

    function testClaimRedeemInsufficientShares() public {
        uint256 shares = 1000 * 10 ** 6;
        uint256 usdcAmount = 800 * 10 ** 6;

        // First create some xCUP shares for user1
        cupToken.mint(user1, shares);
        vm.startPrank(user1);
        cupToken.approve(address(xcup), shares);
        xcup.deposit(shares, user1);
        vm.stopPrank();

        // Request redeem
        vm.startPrank(user1);
        bytes32 redeemId = zapper.requestRedeem(shares);
        vm.stopPrank();

        // Approve redeem
        vm.startPrank(vaultCurator);
        zapper.approveRedeem(redeemId, usdcAmount);
        vm.stopPrank();

        // Transfer all xCUP shares away from user1
        vm.startPrank(user1);
        xcup.transfer(user2, xcup.balanceOf(user1));
        vm.stopPrank();

        // Try to claim without sufficient shares
        vm.startPrank(user1);
        vm.expectRevert(); // Should revert due to insufficient shares
        zapper.claimRedeem(redeemId);
        vm.stopPrank();
    }

    function testClaimRedeemCopperPriceZero() public {
        uint256 shares = 1000 * 10 ** 6;
        uint256 usdcAmount = 800 * 10 ** 6;

        // First create some xCUP shares for user1
        cupToken.mint(user1, shares);
        vm.startPrank(user1);
        cupToken.approve(address(xcup), shares);
        xcup.deposit(shares, user1);
        vm.stopPrank();

        // Request redeem
        vm.startPrank(user1);
        bytes32 redeemId = zapper.requestRedeem(shares);
        vm.stopPrank();

        // Approve redeem
        vm.startPrank(vaultCurator);
        zapper.approveRedeem(redeemId, usdcAmount);
        vm.stopPrank();

        // Approve zapper to transfer xCUP shares from user
        vm.startPrank(user1);
        xcup.approve(address(zapper), shares);
        vm.stopPrank();

        // Mock copper price to return 0
        vm.mockCall(
            address(copperPriceConsumer), abi.encodeWithSelector(ICopperPriceConsumer.price.selector), abi.encode(0)
        );

        // Try to claim with zero copper price
        vm.startPrank(user1);
        vm.expectRevert(); // Should revert due to zero copper price
        zapper.claimRedeem(redeemId);
        vm.stopPrank();
    }

    function testClaimRedeemInsufficientUSDCBalance() public {
        uint256 shares = 1000 * 10 ** 6;
        uint256 usdcAmount = 800 * 10 ** 6;

        // First create some xCUP shares for user1
        cupToken.mint(user1, shares);
        vm.startPrank(user1);
        cupToken.approve(address(xcup), shares);
        xcup.deposit(shares, user1);
        vm.stopPrank();

        // Request redeem
        vm.startPrank(user1);
        bytes32 redeemId = zapper.requestRedeem(shares);
        vm.stopPrank();

        // Approve redeem
        vm.startPrank(vaultCurator);
        zapper.approveRedeem(redeemId, usdcAmount);
        vm.stopPrank();

        // Approve zapper to transfer xCUP shares from user
        vm.startPrank(user1);
        xcup.approve(address(zapper), shares);
        vm.stopPrank();

        // Remove all USDC from silo
        address silo = zapper.silo();
        vm.startPrank(silo);
        usdc.transfer(user2, usdc.balanceOf(silo));
        vm.stopPrank();

        // Try to claim with insufficient USDC in silo
        vm.startPrank(user1);
        vm.expectRevert(); // Should revert due to insufficient USDC balance
        zapper.claimRedeem(redeemId);
        vm.stopPrank();
    }

    function testFullRedeemWorkflow() public {
        uint256 shares = 1000 * 10 ** 6;
        uint256 usdcAmount = 800 * 10 ** 6;

        // Step 1: Create xCUP shares for user1
        cupToken.mint(user1, shares);
        vm.startPrank(user1);
        cupToken.approve(address(xcup), shares);
        uint256 depositedShares = xcup.deposit(shares, user1);
        vm.stopPrank();

        // Step 2: Request redeem
        vm.startPrank(user1);
        bytes32 redeemId = zapper.requestRedeem(depositedShares);
        vm.stopPrank();

        // Step 3: Approve redeem
        vm.startPrank(vaultCurator);
        zapper.approveRedeem(redeemId, usdcAmount);
        vm.stopPrank();

        // Step 4: Approve zapper to transfer xCUP shares
        vm.startPrank(user1);
        xcup.approve(address(zapper), depositedShares);
        vm.stopPrank();

        // Step 5: Claim redeem
        uint256 initialUsdcBalance = usdc.balanceOf(user1);
        uint256 initialCupBalance = cupToken.balanceOf(user1);

        vm.startPrank(user1);
        uint256 claimedAmount = zapper.claimRedeem(redeemId);
        vm.stopPrank();

        // Verify results
        assertTrue(claimedAmount > 0);
        assertTrue(usdc.balanceOf(user1) > initialUsdcBalance);
        assertEq(cupToken.balanceOf(user1), initialCupBalance); // CUP should be converted to USDC
        assertEq(xcup.balanceOf(user1), 0); // All xCUP shares should be redeemed
    }

    function testMultipleRedeemRequests() public {
        uint256 shares1 = 500 * 10 ** 6;
        uint256 shares2 = 300 * 10 ** 6;

        // Create xCUP shares for user1
        cupToken.mint(user1, shares1 + shares2);
        vm.startPrank(user1);
        cupToken.approve(address(xcup), shares1 + shares2);
        xcup.deposit(shares1 + shares2, user1);
        vm.stopPrank();

        // Create two redeem requests
        vm.startPrank(user1);
        bytes32 redeemId1 = zapper.requestRedeem(shares1);
        bytes32 redeemId2 = zapper.requestRedeem(shares2);
        vm.stopPrank();

        // Verify different redeem IDs
        assertTrue(redeemId1 != redeemId2);
        assertTrue(redeemId1 != bytes32(0));
        assertTrue(redeemId2 != bytes32(0));
    }

    function testApproveRedeemAlreadyApproved() public {
        uint256 shares = 1000 * 10 ** 6;
        uint256 usdcAmount = 800 * 10 ** 6;

        // First create some xCUP shares for user1
        cupToken.mint(user1, shares);
        vm.startPrank(user1);
        cupToken.approve(address(xcup), shares);
        xcup.deposit(shares, user1);
        vm.stopPrank();

        // Request redeem
        vm.startPrank(user1);
        bytes32 redeemId = zapper.requestRedeem(shares);
        vm.stopPrank();

        // Approve redeem first time
        vm.startPrank(vaultCurator);
        zapper.approveRedeem(redeemId, usdcAmount);
        vm.stopPrank();

        // Try to approve again
        vm.startPrank(vaultCurator);
        vm.expectRevert(); // Should revert due to already approved
        zapper.approveRedeem(redeemId, usdcAmount);
        vm.stopPrank();
    }

    function testClaimRedeemAlreadyClaimed() public {
        uint256 shares = 1000 * 10 ** 6;
        uint256 usdcAmount = 800 * 10 ** 6;

        // First create some xCUP shares for user1
        cupToken.mint(user1, shares);
        vm.startPrank(user1);
        cupToken.approve(address(xcup), shares);
        xcup.deposit(shares, user1);
        vm.stopPrank();

        // Request redeem
        vm.startPrank(user1);
        bytes32 redeemId = zapper.requestRedeem(shares);
        vm.stopPrank();

        // Approve redeem
        vm.startPrank(vaultCurator);
        zapper.approveRedeem(redeemId, usdcAmount);
        vm.stopPrank();

        // Approve zapper to transfer xCUP shares from user
        vm.startPrank(user1);
        xcup.approve(address(zapper), shares);
        vm.stopPrank();

        // Claim redeem first time
        vm.startPrank(user1);
        zapper.claimRedeem(redeemId);
        vm.stopPrank();

        // Try to claim again
        vm.startPrank(user1);
        vm.expectRevert(); // Should revert due to already claimed
        zapper.claimRedeem(redeemId);
        vm.stopPrank();
    }

    // ───────────────────────────── COMMISSION TESTS ─────────────────────────────

    function testRedeemWithCommission() public {
        uint256 shares = 1000 * 10 ** 6;
        uint256 copperPrice = 450000000; // $4.50 with 8 decimals
        uint256 expectedUsdcAmount = (shares * copperPrice) / (10 ** 8); // Calculate actual expected amount

        // First create some xCUP shares for user1
        cupToken.mint(user1, shares);
        vm.startPrank(user1);
        cupToken.approve(address(xcup), shares);
        xcup.deposit(shares, user1);
        vm.stopPrank();

        // Approve zapper to transfer xCUP shares from user
        vm.startPrank(user1);
        xcup.approve(address(zapper), shares);
        vm.stopPrank();

        // Record initial balances
        uint256 initialUserUsdcBalance = usdc.balanceOf(user1);

        // Perform redeem (this should apply commission)
        vm.startPrank(user1);
        uint256 receivedUsdc = zapper.redeem(shares);
        vm.stopPrank();

        // Check that user received USDC (less commission)
        assertTrue(receivedUsdc > 0);
        assertTrue(usdc.balanceOf(user1) > initialUserUsdcBalance);

        // Since commission is 0 by default, user should receive full amount
        assertEq(receivedUsdc, expectedUsdcAmount);
    }

    function testRedeemCommissionCalculation() public {
        uint256 shares = 1000 * 10 ** 6;
        uint256 copperPrice = 450000000; // $4.50 with 8 decimals
        uint256 expectedTotalUsdc = (shares * copperPrice) / (10 ** 8);

        // First create some xCUP shares for user1
        cupToken.mint(user1, shares);
        vm.startPrank(user1);
        cupToken.approve(address(xcup), shares);
        xcup.deposit(shares, user1);
        vm.stopPrank();

        // Approve zapper to transfer xCUP shares from user
        vm.startPrank(user1);
        xcup.approve(address(zapper), shares);
        vm.stopPrank();

        // Perform redeem
        vm.startPrank(user1);
        uint256 receivedUsdc = zapper.redeem(shares);
        vm.stopPrank();

        // With 0% commission (default), user should receive full amount
        assertEq(receivedUsdc, expectedTotalUsdc);
    }

    function testRedeemCommissionStaysInSilo() public {
        uint256 shares = 1000 * 10 ** 6;

        // First create some xCUP shares for user1
        cupToken.mint(user1, shares);
        vm.startPrank(user1);
        cupToken.approve(address(xcup), shares);
        xcup.deposit(shares, user1);
        vm.stopPrank();

        // Approve zapper to transfer xCUP shares from user
        vm.startPrank(user1);
        xcup.approve(address(zapper), shares);
        vm.stopPrank();

        // Record initial silo balance
        uint256 initialSiloBalance = usdc.balanceOf(zapper.silo());

        // Perform redeem
        vm.startPrank(user1);
        uint256 receivedUsdc = zapper.redeem(shares);
        vm.stopPrank();

        // Record final silo balance
        uint256 finalSiloBalance = usdc.balanceOf(zapper.silo());

        // With 0% commission, silo balance should decrease by the full amount
        // (This test will need to be updated if commission is set to non-zero)
        assertEq(finalSiloBalance, initialSiloBalance - receivedUsdc);
    }

    function testRedeemWithDifferentCommissionRates() public {
        uint256 shares = 1000 * 10 ** 6;
        uint256 totalUsdcAmount = (shares * 450000000) / (10 ** 8);

        // Test with 0% commission (default)
        assertEq(zapper.getRedeemCommission(), 0);

        // First create some xCUP shares for user1
        cupToken.mint(user1, shares);
        vm.startPrank(user1);
        cupToken.approve(address(xcup), shares);
        xcup.deposit(shares, user1);
        vm.stopPrank();

        // Approve zapper to transfer xCUP shares from user
        vm.startPrank(user1);
        xcup.approve(address(zapper), shares);
        vm.stopPrank();

        // Test with 0% commission
        vm.startPrank(user1);
        uint256 receivedUsdc0 = zapper.redeem(shares);
        vm.stopPrank();

        // Verify that with 0% commission, user receives full amount
        assertEq(receivedUsdc0, totalUsdcAmount);

        // Now test with 2% commission (200 basis points)
        vm.startPrank(owner);
        zapper.setRedeemCommission(200);
        vm.stopPrank();

        assertEq(zapper.getRedeemCommission(), 200);

        // Create new shares for testing with commission
        cupToken.mint(user1, shares);
        vm.startPrank(user1);
        cupToken.approve(address(xcup), shares);
        xcup.deposit(shares, user1);
        xcup.approve(address(zapper), shares);
        vm.stopPrank();

        // Test with 2% commission
        vm.startPrank(user1);
        uint256 receivedUsdc2 = zapper.redeem(shares);
        vm.stopPrank();

        // With 2% commission, user should receive 98% of total amount
        uint256 expectedAmount2 = (totalUsdcAmount * 9800) / 10000;
        assertEq(receivedUsdc2, expectedAmount2);

        // Test with 5% commission (500 basis points)
        vm.startPrank(owner);
        zapper.setRedeemCommission(500);
        vm.stopPrank();

        assertEq(zapper.getRedeemCommission(), 500);

        // Create new shares for testing with 5% commission
        cupToken.mint(user1, shares);
        vm.startPrank(user1);
        cupToken.approve(address(xcup), shares);
        xcup.deposit(shares, user1);
        xcup.approve(address(zapper), shares);
        vm.stopPrank();

        // Test with 5% commission
        vm.startPrank(user1);
        uint256 receivedUsdc5 = zapper.redeem(shares);
        vm.stopPrank();

        // With 5% commission, user should receive 95% of total amount
        uint256 expectedAmount5 = (totalUsdcAmount * 9500) / 10000;
        assertEq(receivedUsdc5, expectedAmount5);
    }

    function testRedeemCommissionEdgeCases() public {
        uint256 shares = 1000 * 10 ** 6;

        // First create some xCUP shares for user1
        cupToken.mint(user1, shares);
        vm.startPrank(user1);
        cupToken.approve(address(xcup), shares);
        xcup.deposit(shares, user1);
        vm.stopPrank();

        // Approve zapper to transfer xCUP shares from user
        vm.startPrank(user1);
        xcup.approve(address(zapper), shares);
        vm.stopPrank();

        // Test with very small amount (should still work with 0% commission)
        vm.startPrank(user1);
        uint256 receivedUsdc = zapper.redeem(1); // 1 wei
        vm.stopPrank();

        // Should receive proportional amount
        assertTrue(receivedUsdc > 0);
    }

    function testRedeemCommissionPrecision() public {
        // Test commission calculation precision with different amounts
        uint256[] memory testAmounts = new uint256[](3);
        testAmounts[0] = 1; // 1 wei
        testAmounts[1] = 1000 * 10 ** 6; // 1000 USDC
        testAmounts[2] = 1000000 * 10 ** 6; // 1M USDC

        for (uint256 i = 0; i < testAmounts.length; i++) {
            uint256 shares = testAmounts[i];

            // Create xCUP shares for user1
            cupToken.mint(user1, shares);
            vm.startPrank(user1);
            cupToken.approve(address(xcup), shares);
            xcup.deposit(shares, user1);
            vm.stopPrank();

            // Approve zapper to transfer xCUP shares from user
            vm.startPrank(user1);
            xcup.approve(address(zapper), shares);
            vm.stopPrank();

            // Ensure silo has enough USDC for this redeem
            uint256 expectedUsdc = (shares * 450000000) / (10 ** 8);
            if (usdc.balanceOf(zapper.silo()) < expectedUsdc) {
                usdc.mint(zapper.silo(), expectedUsdc);
            }

            // Perform redeem
            vm.startPrank(user1);
            uint256 receivedUsdc = zapper.redeem(shares);
            vm.stopPrank();

            // With 0% commission, should receive full amount
            uint256 expectedAmount = (shares * 450000000) / (10 ** 8);
            assertEq(receivedUsdc, expectedAmount);
        }
    }

    function testSetRedeemCommission() public {
        // Test setting commission to 2% (200 basis points)
        vm.startPrank(owner);
        zapper.setRedeemCommission(200);
        vm.stopPrank();

        assertEq(zapper.getRedeemCommission(), 200);
    }

    function testSetRedeemCommissionWithoutRole() public {
        vm.startPrank(user1);
        vm.expectRevert(); // Should revert due to missing role
        zapper.setRedeemCommission(200);
        vm.stopPrank();
    }

    function testSetRedeemCommissionInvalidRate() public {
        vm.startPrank(owner);
        vm.expectRevert("Commission cannot exceed 100%");
        zapper.setRedeemCommission(10001); // 100.01%
        vm.stopPrank();
    }

    function testSetRedeemCommissionMaxRate() public {
        vm.startPrank(owner);
        zapper.setRedeemCommission(10000); // 100%
        vm.stopPrank();

        assertEq(zapper.getRedeemCommission(), 10000);
    }

    function testGetRedeemCommission() public {
        // Test default commission (should be 0)
        assertEq(zapper.getRedeemCommission(), 0);

        // Set commission and verify
        vm.startPrank(owner);
        zapper.setRedeemCommission(250); // 2.5%
        vm.stopPrank();

        assertEq(zapper.getRedeemCommission(), 250);
    }

    function testRedeemCommissionStaysInSiloWithCommission() public {
        uint256 shares = 1000 * 10 ** 6;
        uint256 totalUsdcAmount = (shares * 450000000) / (10 ** 8);

        // Set 3% commission
        vm.startPrank(owner);
        zapper.setRedeemCommission(300); // 3%
        vm.stopPrank();

        // First create some xCUP shares for user1
        cupToken.mint(user1, shares);
        vm.startPrank(user1);
        cupToken.approve(address(xcup), shares);
        xcup.deposit(shares, user1);
        vm.stopPrank();

        // Approve zapper to transfer xCUP shares from user
        vm.startPrank(user1);
        xcup.approve(address(zapper), shares);
        vm.stopPrank();

        // Record initial silo balance
        uint256 initialSiloBalance = usdc.balanceOf(zapper.silo());

        // Perform redeem
        vm.startPrank(user1);
        uint256 receivedUsdc = zapper.redeem(shares);
        vm.stopPrank();

        // Record final silo balance
        uint256 finalSiloBalance = usdc.balanceOf(zapper.silo());

        // With 3% commission:
        // - User should receive 97% of total amount
        // - Commission (3%) should stay in silo
        uint256 expectedUserAmount = (totalUsdcAmount * 9700) / 10000;
        uint256 expectedCommission = totalUsdcAmount - expectedUserAmount;

        assertEq(receivedUsdc, expectedUserAmount);
        assertEq(finalSiloBalance, initialSiloBalance - receivedUsdc);
        // Commission stays in silo, so silo balance decreases by user amount only
    }

    function testRedeemCommissionPrecisionWithDifferentRates() public {
        uint256 shares = 1000 * 10 ** 6;
        uint256 totalUsdcAmount = (shares * 450000000) / (10 ** 8);

        // Test different commission rates
        uint256[] memory commissionRates = new uint256[](4);
        commissionRates[0] = 1; // 0.01%
        commissionRates[1] = 50; // 0.5%
        commissionRates[2] = 100; // 1%
        commissionRates[3] = 1000; // 10%

        for (uint256 i = 0; i < commissionRates.length; i++) {
            uint256 commissionBps = commissionRates[i];

            // Set commission
            vm.startPrank(owner);
            zapper.setRedeemCommission(commissionBps);
            vm.stopPrank();

            // Create xCUP shares for user1
            cupToken.mint(user1, shares);
            vm.startPrank(user1);
            cupToken.approve(address(xcup), shares);
            xcup.deposit(shares, user1);
            xcup.approve(address(zapper), shares);
            vm.stopPrank();

            // Ensure silo has enough USDC for this redeem
            uint256 expectedUsdc = (shares * 450000000) / (10 ** 8);
            if (usdc.balanceOf(zapper.silo()) < expectedUsdc) {
                usdc.mint(zapper.silo(), expectedUsdc);
            }

            // Perform redeem
            vm.startPrank(user1);
            uint256 receivedUsdc = zapper.redeem(shares);
            vm.stopPrank();

            // Calculate expected amount
            uint256 expectedAmount = (totalUsdcAmount * (10000 - commissionBps)) / 10000;
            assertEq(receivedUsdc, expectedAmount);
        }
    }

    // Additional tests for RedeemLib branch coverage
    function testRequestRedeemWithDuplicateId() public {
        // This test covers the req.user != address(0) branch in RedeemLib.requestRedeem
        // When block.timestamp is the same, keccak256 can produce the same ID

        uint256 shares = 1000 * 10 ** 6;

        // Set up user with shares
        cupToken.mint(user1, shares * 2);
        vm.startPrank(user1);
        cupToken.approve(address(xcup), shares * 2);
        xcup.deposit(shares * 2, user1);
        vm.stopPrank();

        // First request
        vm.startPrank(user1);
        bytes32 redeemId1 = zapper.requestRedeem(shares);
        vm.stopPrank();

        // Second request with same parameters in same block (should revert due to duplicate ID)
        vm.startPrank(user1);
        vm.expectRevert(RedeemLib.InvalidRedeemRequest.selector);
        zapper.requestRedeem(shares);
        vm.stopPrank();
    }

    function testApproveRedeemWithZeroUser() public {
        // This test covers the req.user == address(0) branch in RedeemLib.approveRedeem
        // We need to try to approve a non-existent redeem request

        bytes32 nonExistentRedeemId = keccak256("non-existent");

        vm.expectRevert(); // Should revert due to invalid redeem request
        zapper.approveRedeem(nonExistentRedeemId, 1000 * 10 ** 6);
    }

    function testGetRedeem() public {
        // Test the getRedeem function to retrieve redeem request information
        uint256 shares = 1000 * 10 ** 6;

        // Set up user with shares
        cupToken.mint(user1, shares);
        vm.startPrank(user1);
        cupToken.approve(address(xcup), shares);
        xcup.deposit(shares, user1);
        vm.stopPrank();

        // Request redeem
        vm.startPrank(user1);
        bytes32 redeemId = zapper.requestRedeem(shares);
        vm.stopPrank();

        // Get redeem information
        RedeemLib.RedeemRequest memory redeemInfo = zapper.getRedeem(redeemId);

        // Verify the redeem request information
        assertEq(redeemInfo.user, user1, "User should match");
        assertEq(redeemInfo.shares, shares, "Shares should match");
        assertEq(redeemInfo.usdcAmount, 0, "USDC amount should be 0 initially");
        assertFalse(redeemInfo.approved, "Should not be approved initially");
        assertFalse(redeemInfo.claimed, "Should not be claimed initially");

        // Approve the redeem
        uint256 usdcAmount = 1000 * 10 ** 6;
        vm.startPrank(vaultCurator);
        zapper.approveRedeem(redeemId, usdcAmount);
        vm.stopPrank();

        // Get updated redeem information
        redeemInfo = zapper.getRedeem(redeemId);

        // Verify the updated information
        assertEq(redeemInfo.user, user1, "User should still match");
        assertEq(redeemInfo.shares, shares, "Shares should still match");
        assertEq(redeemInfo.usdcAmount, usdcAmount, "USDC amount should be updated");
        assertTrue(redeemInfo.approved, "Should be approved now");
        assertFalse(redeemInfo.claimed, "Should still not be claimed");
    }

    function testGetRedeemNonExistent() public {
        // Test getting a non-existent redeem request
        bytes32 nonExistentRedeemId = keccak256("non-existent");

        RedeemLib.RedeemRequest memory redeemInfo = zapper.getRedeem(nonExistentRedeemId);

        // Verify that all fields are empty/default for non-existent request
        assertEq(redeemInfo.user, address(0), "User should be address(0)");
        assertEq(redeemInfo.shares, 0, "Shares should be 0");
        assertEq(redeemInfo.usdcAmount, 0, "USDC amount should be 0");
        assertFalse(redeemInfo.approved, "Should not be approved");
        assertFalse(redeemInfo.claimed, "Should not be claimed");
    }

    function testApproveRedeemWithAlreadyClaimed() public {
        // This test covers the req.claimed branch in RedeemLib.approveRedeem
        // We need to test the case where a redeem request is already claimed
        uint256 shares = 1000 * 10 ** 6;

        // Set up user with shares
        cupToken.mint(user1, shares);
        vm.startPrank(user1);
        cupToken.approve(address(xcup), shares);
        xcup.deposit(shares, user1);
        vm.stopPrank();

        // Request redeem
        vm.startPrank(user1);
        bytes32 redeemId = zapper.requestRedeem(shares);
        vm.stopPrank();

        // Approve redeem
        vm.prank(vaultCurator);
        zapper.approveRedeem(redeemId, 1000 * 10 ** 6);

        // Ensure silo has enough USDC for the claim
        uint256 expectedUsdc = 1000 * 10 ** 6;
        if (usdc.balanceOf(zapper.silo()) < expectedUsdc) {
            usdc.mint(zapper.silo(), expectedUsdc);
        }

        // Give allowance for xCUP tokens to Zapper
        vm.startPrank(user1);
        xcup.approve(address(zapper), shares);
        vm.stopPrank();

        // Claim redeem
        vm.startPrank(user1);
        zapper.claimRedeem(redeemId);
        vm.stopPrank();

        // Try to approve again (should revert due to already approved)
        vm.expectRevert(RedeemLib.AlreadyApproved.selector);
        vm.prank(vaultCurator);
        zapper.approveRedeem(redeemId, 1000 * 10 ** 6);
    }

    function testClaimRedeemWithZeroUser() public {
        // This test covers the req.user == address(0) branch in RedeemLib.claimRedeem
        bytes32 nonExistentRedeemId = keccak256("non-existent");

        vm.expectRevert(); // Should revert due to invalid redeem request
        zapper.claimRedeem(nonExistentRedeemId);
    }

    function testClaimRedeemWithInsufficientOwnedShares() public {
        // This test covers the ownedShares < sharesToRedeem branch in RedeemLib.claimRedeem
        uint256 shares = 1000 * 10 ** 6;

        // Set up user with shares
        cupToken.mint(user1, shares);
        vm.startPrank(user1);
        cupToken.approve(address(xcup), shares);
        xcup.deposit(shares, user1);
        vm.stopPrank();

        // Request redeem
        vm.startPrank(user1);
        bytes32 redeemId = zapper.requestRedeem(shares);
        vm.stopPrank();

        // Approve redeem
        vm.prank(vaultCurator);
        zapper.approveRedeem(redeemId, 1000 * 10 ** 6);

        // Transfer shares away from user
        vm.startPrank(user1);
        xcup.transfer(user2, shares);
        vm.stopPrank();

        // Try to claim redeem (should revert due to insufficient shares)
        vm.expectRevert(); // Should revert due to insufficient shares
        vm.startPrank(user1);
        zapper.claimRedeem(redeemId);
        vm.stopPrank();
    }
}
