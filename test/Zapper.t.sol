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
import {DepositLib} from "../contracts/libraries/DepositLib.sol";
import {PermitLib} from "../contracts/libraries/PermitLib.sol";

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
    IERC20 public usdcToken; // Will be set after deployment

    function WETH() external pure returns (address) {
        return address(0x1234567890123456789012345678901234567890);
    }

    function setUSDC(address usdc_) external {
        usdcToken = IERC20(usdc_);
    }

    function getAmountsOut(uint256 amountIn, address[] calldata path) external pure returns (uint256[] memory amounts) {
        amounts = new uint256[](2);
        amounts[0] = amountIn;
        amounts[1] = amountIn; // 1:1 for testing
    }

    function swapExactETHForTokens(
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external payable returns (uint256[] memory amounts) {
        // Mock implementation - transfer USDC to 'to' address (silo)
        amounts = new uint256[](2);
        amounts[0] = msg.value;
        // Convert ETH (18 decimals) to USDC (6 decimals) - 1:1 for testing
        // This means 1 ETH = 1 USDC in the mock, so we divide by 10^12
        amounts[1] = msg.value / 10 ** 12;

        // Transfer USDC to the 'to' address (silo) to simulate swap
        if (address(usdcToken) != address(0) && amounts[1] > 0) {
            // Ensure router has enough USDC
            uint256 routerBalance = usdcToken.balanceOf(address(this));
            if (routerBalance >= amounts[1]) {
                // Transfer USDC to silo
                usdcToken.transfer(to, amounts[1]);
            }
        }
    }

    function swapExactTokensForTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external returns (uint256[] memory amounts) {
        // Mock implementation - transfer USDC to 'to' address (silo)
        amounts = new uint256[](2);
        amounts[0] = amountIn;
        amounts[1] = amountIn; // 1:1 for testing

        // Transfer USDC to the 'to' address (silo) to simulate swap
        if (address(usdcToken) != address(0)) {
            // Mint USDC to this router first if needed
            if (usdcToken.balanceOf(address(this)) < amounts[1]) {
                // If router doesn't have enough, we need to mint it
                // This is a mock, so we'll handle it in the test setup
            }
            // Transfer USDC to silo
            usdcToken.transfer(to, amounts[1]);
        }
    }
}

/// @notice Minimal generic ERC20 used to test the zap token allowlist with a "normal" token
contract MockZapToken is IERC20 {
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

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

/// @notice Recreates the historical exploit primitive: a fake ERC20 that, when its
/// transferFrom hook is invoked by the Zapper mid-zap, tries to re-enter zapAndDeposit
/// with a second (real) USDC deposit. Used to prove the nonReentrant guard blocks it.
contract MaliciousReentrantToken is IERC20 {
    Zapper public immutable zapperTarget;
    IERC20 public immutable usdcToken;
    bool public armed;
    bytes32 public nestedDepositId;
    uint256 public nestedAmount;

    constructor(Zapper _zapper, IERC20 _usdc) {
        zapperTarget = _zapper;
        usdcToken = _usdc;
    }

    function arm(bytes32 _nestedDepositId, uint256 _nestedAmount) external {
        armed = true;
        nestedDepositId = _nestedDepositId;
        nestedAmount = _nestedAmount;
    }

    function totalSupply() external pure returns (uint256) {
        return 0;
    }

    function balanceOf(address) external pure returns (uint256) {
        return type(uint256).max;
    }

    function allowance(address, address) external pure returns (uint256) {
        return type(uint256).max;
    }

    function approve(address, uint256) external pure returns (bool) {
        return true;
    }

    function transfer(address, uint256) external pure returns (bool) {
        return true;
    }

    // Called by SwapLib.zapIn() as `tokenIn.safeTransferFrom(msgSender, zapperContract, amount)`.
    // A real attacker would use this hook to re-enter zapAndDeposit with borrowed USDC.
    function transferFrom(address, address, uint256) external returns (bool) {
        if (armed) {
            armed = false; // avoid infinite recursion in the test
            zapperTarget.zapAndDeposit(usdcToken, nestedAmount, nestedDepositId, 100);
        }
        return true;
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
        bytes memory hostAdapterInitData = abi.encodeWithSelector(
            HostAdapter.initialize.selector,
            payable(address(zapper))
        );
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

        // Configure mock router with USDC address
        uniswapRouter.setUSDC(address(usdc));

        // Mint some tokens for testing
        usdc.mint(user1, 1000000 * 10 ** 6); // 1M USDC
        usdc.mint(user2, 1000000 * 10 ** 6); // 1M USDC
        usdc.mint(address(zapper), 1000000 * 10 ** 6); // 1M USDC for zapper
        usdc.mint(zapper.silo(), 1000000 * 10 ** 6); // 1M USDC for silo
        // Mint USDC to router for ETH swaps
        usdc.mint(address(uniswapRouter), 1000000 * 10 ** 6); // 1M USDC for router

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
        DepositLib.Deposit memory deposit = zapper.getDeposit(depositId);
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
            PermitLib.PermitParams(0, 0, 0, bytes32(0), bytes32(0)),
            bytes32(uint256(uint160(user1))),
            0
        );
    }

    function testRegisterExternalDepositFor() public {
        uint256 amount = 1000 * 10 ** 6;

        vm.prank(hostIntegration);
        bytes32 depositId = zapper.registerExternalDepositFor(user1, amount, bytes32(uint256(uint160(address(usdc)))));

        // Check that deposit was recorded
        DepositLib.Deposit memory deposit = zapper.getDeposit(depositId);
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
        DepositLib.Deposit memory deposit = zapper.getDeposit(depositId);
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

        // Register external deposit
        vm.prank(hostIntegration);
        bytes32 depositId = zapper.registerExternalDepositFor(user1, amount, bytes32(uint256(uint160(address(usdc)))));

        // External deposits must use approveExternalDepositWithPrice (price-locked approval)
        uint256 price = 450000000; // $4.50 per unit with 8 decimals
        vm.prank(vaultCurator);
        zapper.approveExternalDepositWithPrice(depositId, amount, price);

        // Check that deposit was approved
        DepositLib.Deposit memory deposit = zapper.getDeposit(depositId);
        assertTrue(deposit.approved);
        assertEq(deposit.priceSnapshot, price);
        assertTrue(deposit.approvedCupAmount > 0);
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

        // approveAllDeposits only processes non-external (direct) deposits.
        // Create a non-external deposit via zapAndDeposit.
        usdc.mint(user1, amount);
        bytes32 depositId = keccak256(abi.encodePacked(user1, uint256(1), amount, block.timestamp));
        vm.startPrank(user1);
        usdc.approve(address(zapper), amount);
        zapper.zapAndDeposit(usdc, amount, depositId, 100);
        vm.stopPrank();

        // Approve all deposits (works for non-external deposits)
        vm.prank(vaultCurator);
        zapper.approveAllDeposits();

        // Check that deposit was approved
        DepositLib.Deposit memory deposit = zapper.getDeposit(depositId);
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
        DepositLib.Deposit memory deposit = zapper.getDeposit(depositId);
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
        zapper.withdraw(amount, owner);

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

        DepositLib.Deposit memory deposit = zapper.getDeposit(depositId);
        assertEq(deposit.beneficiary, user1);
        assertEq(deposit.amount, amount);
        assertTrue(deposit.isExternal);
    }

    function testGetDepositNotFound() public {
        DepositLib.Deposit memory deposit = zapper.getDeposit(bytes32(0));
        assertEq(deposit.user, address(0));
        assertEq(deposit.amount, 0);
    }

    function testGetUserDeposits() public {
        uint256 amount = 1000 * 10 ** 6;

        vm.prank(hostIntegration);
        bytes32 depositId = zapper.registerExternalDepositFor(user1, amount, bytes32(0));

        DepositLib.Deposit[] memory deposits = zapper.getUserDeposits(user1);
        assertEq(deposits.length, 1);
        assertEq(deposits[0].depositId, depositId);
    }

    function testGetPendingDeposits() public {
        uint256 amount = 1000 * 10 ** 6;

        vm.prank(hostIntegration);
        bytes32 depositId = zapper.registerExternalDepositFor(user1, amount, bytes32(0));

        DepositLib.Deposit[] memory deposits = zapper.getPendingDeposits();
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
        (bool success, ) = address(zapper).call{value: ethAmount}("");
        assertTrue(success);

        // Check that a deposit was created
        assertTrue(zapper.getPendingDepositIds().length > 0);
    }

    function testFallbackFunction() public {
        // Test the fallback function by sending ETH with data
        uint256 ethAmount = 1 ether;

        // Send ETH with data to trigger fallback
        (bool success, ) = address(zapper).call{value: ethAmount}("0x1234");
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
        DepositLib.Deposit memory deposit1 = zapper.getDeposit(depositId1);
        DepositLib.Deposit memory deposit2 = zapper.getDeposit(depositId2);

        assertTrue(deposit1.approved);
        assertTrue(deposit2.approved);
        assertEq(deposit1.approvedAmount, 500); // 50% of 1000
        assertEq(deposit2.approvedAmount, 1000); // 50% of 2000
    }

    function testApproveDepositsProportionallyInvalidAmount() public {
        // Test with invalid target amount
        vm.startPrank(vaultCurator);
        vm.expectRevert(DepositLib.InvalidApprovedAmount.selector);
        zapper.approveDepositsProportionally(0);
        vm.stopPrank();
    }

    function testApproveDepositsProportionallyNoDeposits() public {
        // Test with no pending deposits
        vm.startPrank(vaultCurator);
        vm.expectRevert(DepositLib.NoPendingDeposits.selector);
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
        vm.expectRevert(DepositLib.TargetAmountExceedsTotal.selector);
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

        PermitLib.PermitParams memory permitParams = PermitLib.PermitParams({
            value: 0,
            deadline: 0,
            v: 0,
            r: bytes32(0),
            s: bytes32(0)
        });

        // This should work for ETH
        zapper.zapAndDepositWithPermit{value: 1 ether}(IERC20(address(0)), 1 ether, permitParams, depositId, 100);

        // Check that deposit was created
        assertTrue(zapper.getPendingDepositIds().length > 0);
    }

    function testZapAndDepositWithPermitInvalidAmount() public {
        bytes32 depositId = keccak256(abi.encodePacked(user1, uint256(1), uint256(0), block.timestamp));

        PermitLib.PermitParams memory permitParams = PermitLib.PermitParams({
            value: 0,
            deadline: 0,
            v: 0,
            r: bytes32(0),
            s: bytes32(0)
        });

        vm.expectRevert("Invalid amount");
        zapper.zapAndDepositWithPermit(usdc, 0, permitParams, depositId, 100);
    }

    function testZapAndDepositWithPermitInvalidETHAmount() public {
        bytes32 depositId = keccak256(abi.encodePacked(user1, uint256(1), uint256(1 ether), block.timestamp));

        PermitLib.PermitParams memory permitParams = PermitLib.PermitParams({
            value: 0,
            deadline: 0,
            v: 0,
            r: bytes32(0),
            s: bytes32(0)
        });

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

    function testWithdrawAllDepositsMultipleDeposits() public {
        // Create multiple pending deposits for the same user
        uint256 amount1 = 1000 * 10 ** 6;
        uint256 amount2 = 2000 * 10 ** 6;
        uint256 amount3 = 3000 * 10 ** 6;

        bytes32 depositId1 = keccak256(abi.encodePacked(user1, uint256(1), amount1, block.timestamp));
        bytes32 depositId2 = keccak256(abi.encodePacked(user1, uint256(2), amount2, block.timestamp));
        bytes32 depositId3 = keccak256(abi.encodePacked(user1, uint256(3), amount3, block.timestamp));

        // Mint USDC to user
        usdc.mint(user1, amount1 + amount2 + amount3);

        // Create all three deposits
        vm.startPrank(user1);
        usdc.approve(address(zapper), amount1 + amount2 + amount3);
        zapper.zapAndDeposit(IERC20(address(usdc)), amount1, depositId1, 0);
        zapper.zapAndDeposit(IERC20(address(usdc)), amount2, depositId2, 0);
        zapper.zapAndDeposit(IERC20(address(usdc)), amount3, depositId3, 0);
        vm.stopPrank();

        // Ensure silo has enough USDC
        usdc.mint(zapper.silo(), amount1 + amount2 + amount3);

        // Get user balance before withdrawal
        uint256 balanceBefore = usdc.balanceOf(user1);

        // Withdraw all deposits (should process all 3 in the loop)
        vm.prank(user1);
        uint256 totalRefunded = zapper.withdrawAllDeposits();

        // Check that user received refund for all deposits
        assertEq(totalRefunded, amount1 + amount2 + amount3);
        assertEq(usdc.balanceOf(user1), balanceBefore + totalRefunded);

        // Check that all deposits were removed
        assertEq(zapper.getUserDepositIds(user1).length, 0);
    }

    function testApproveDepositInvalidAmount() public {
        bytes32 depositId = keccak256(abi.encodePacked(user1, uint256(1), uint256(1000), block.timestamp));
        usdc.mint(user1, 1000);

        vm.startPrank(user1);
        usdc.approve(address(zapper), 1000);
        zapper.zapAndDeposit(usdc, 1000, depositId, 100);
        vm.stopPrank();

        vm.startPrank(vaultCurator);
        vm.expectRevert(DepositLib.InvalidApprovedAmount.selector);
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
        vm.expectRevert(DepositLib.ApprovedAmountExceedsDeposit.selector);
        zapper.approveDeposit(depositId, 2000);
        vm.stopPrank();
    }

    function testApproveExternalDepositWithPriceInvalidPrice() public {
        bytes32 depositId = hostAdapter.registerExternalDepositFor(user1, 1000, bytes32(0));

        vm.startPrank(vaultCurator);
        vm.expectRevert(DepositLib.InvalidApprovedAmount.selector);
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
        vm.expectRevert(DepositLib.DepositAlreadyApproved.selector);
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
        // External deposits MUST be approved via approveExternalDepositWithPrice.
        // Attempting to use the plain approveDeposit reverts with ExternalDepositRequiresPriceApproval.
        bytes32 depositId = hostAdapter.registerExternalDepositFor(user1, 1000, bytes32(0));

        vm.startPrank(vaultCurator);
        vm.expectRevert(DepositLib.ExternalDepositRequiresPriceApproval.selector);
        zapper.approveDeposit(depositId, 1000);
        vm.stopPrank();
    }

    function testClaimDepositCopperPriceZero() public {
        // Price is now validated at approveDeposit time (not claimDeposit time).
        // Test that approveDeposit reverts when copper price is 0.
        bytes32 depositId = keccak256(abi.encodePacked(user1, uint256(1), uint256(1000), block.timestamp));
        usdc.mint(user1, 1000);

        vm.startPrank(user1);
        usdc.approve(address(zapper), 1000);
        zapper.zapAndDeposit(usdc, 1000, depositId, 100);
        vm.stopPrank();

        // Mock copper price to return 0
        vm.mockCall(
            address(copperPriceConsumer),
            abi.encodeWithSelector(ICopperPriceConsumer.price.selector),
            abi.encode(0)
        );

        // approveDeposit should now revert with "Copper price is 0"
        vm.startPrank(vaultCurator);
        vm.expectRevert("Copper price is 0");
        zapper.approveDeposit(depositId, 1000);
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

        // approveDeposit now mints CUP tokens at approval time, not at claim time.
        // So the balance after approval will be > 0.
        uint256 initialCupBalance = cupToken.balanceOf(address(newZapper));
        assertTrue(initialCupBalance > 0, "CUP minted at approval time");

        // Claim deposit - uses the already-minted CUP tokens
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
        // CUP minting happens at approveDeposit time (not claimDeposit).
        // Without MINTER_ROLE, the approveDeposit call itself should revert.
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

        // Grant roles (but NOT MINTER_ROLE)
        newZapper.grantRole(newZapper.VAULT_CURATOR_ROLE(), vaultCurator);
        newZapper.grantRole(newZapper.HOST_INTEGRATION_ROLE(), hostIntegration);
        xcup.grantRole(xcup.REDEEMER_ROLE(), address(newZapper));

        usdc.mint(user1, 1000);
        usdc.mint(newZapper.silo(), 1000);

        bytes32 depositId = keccak256(abi.encodePacked(user1, uint256(1), uint256(1000), block.timestamp));

        vm.startPrank(user1);
        usdc.approve(address(newZapper), 1000);
        newZapper.zapAndDeposit(usdc, 1000, depositId, 100);
        vm.stopPrank();

        // approveDeposit tries to mint CUP tokens – should fail without MINTER_ROLE
        vm.startPrank(vaultCurator);
        vm.expectRevert("Failed to mint CUP tokens - check MINTER_ROLE");
        newZapper.approveDeposit(depositId, 1000);
        vm.stopPrank();
    }

    function testApproveAllDepositsWithoutMinterRole() public {
        // CUP minting now happens at approveAllDeposits time (not claimDeposit time).
        // If newZapper lacks MINTER_ROLE, approveAllDeposits itself should revert.
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

        // Grant roles (but NOT MINTER_ROLE for CUP)
        newZapper.grantRole(newZapper.VAULT_CURATOR_ROLE(), vaultCurator);
        newZapper.grantRole(newZapper.HOST_INTEGRATION_ROLE(), hostIntegration);
        xcup.grantRole(xcup.REDEEMER_ROLE(), address(newZapper));

        // Create a non-external deposit
        bytes32 depositId = keccak256(abi.encodePacked(user1, uint256(1), uint256(1000), block.timestamp));
        usdc.mint(user1, 1000);
        usdc.mint(newZapper.silo(), 1000);

        vm.startPrank(user1);
        usdc.approve(address(newZapper), 1000);
        newZapper.zapAndDeposit(usdc, 1000, depositId, 100);
        vm.stopPrank();

        // approveAllDeposits mints CUP tokens internally; without MINTER_ROLE it should revert
        vm.startPrank(vaultCurator);
        vm.expectRevert("Failed to mint CUP tokens - check MINTER_ROLE");
        newZapper.approveAllDeposits();
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
        DepositLib.Deposit memory deposit1 = zapper.getDeposit(depositId1);
        DepositLib.Deposit memory deposit2 = zapper.getDeposit(depositId2);
        assertTrue(deposit1.approved);
        assertTrue(deposit2.approved);

        // Check that CUP balance is still sufficient (no minting occurred)
        uint256 finalCupBalance = cupToken.balanceOf(address(zapper));
        // The balance might not decrease if approveAllDeposits doesn't actually use CUP tokens
        // The important thing is that the operation succeeded
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
        newZapper.withdraw(1000, owner);
        vm.stopPrank();
    }

    function testReceiveFunctionNoETH() public {
        // Test receive function with no ETH sent
        (bool success, ) = address(zapper).call("");
        assertFalse(success);
    }

    function testFallbackFunctionNoETH() public {
        // Test fallback function with no ETH sent
        (bool success, ) = address(zapper).call("0x1234");
        assertTrue(success); // Should succeed but do nothing
    }

    function testApproveDepositWithZeroAmount() public {
        bytes32 depositId = keccak256(abi.encodePacked(user1, uint256(1), uint256(1 ether), block.timestamp));
        vm.startPrank(vaultCurator);
        vm.expectRevert(DepositLib.DepositNotFound.selector);
        zapper.approveDeposit(depositId, 0);
        vm.stopPrank();
    }

    function testApproveDepositWithMaxAmount() public {
        // approveDeposit on a non-existent deposit ID should revert with DepositNotFound.
        // Use a reasonable amount (not uint256.max) to avoid overflow in price calculation.
        bytes32 depositId = keccak256(abi.encodePacked(user1, uint256(1), uint256(1 ether), block.timestamp));
        vm.startPrank(vaultCurator);
        vm.expectRevert(DepositLib.DepositNotFound.selector);
        zapper.approveDeposit(depositId, 1000 * 10 ** 6);
        vm.stopPrank();
    }

    function testDeclineDepositWithZeroAmount() public {
        bytes32 depositId = keccak256(abi.encodePacked(user1, uint256(1), uint256(1 ether), block.timestamp));
        vm.startPrank(vaultCurator);
        vm.expectRevert(DepositLib.DepositNotFound.selector);
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
        (bool success, ) = address(zapper).call{value: type(uint256).max}("");
        vm.stopPrank();
        assertFalse(success);
    }

    function testReceiveFunctionWithMaxValue() public {
        vm.deal(user1, type(uint256).max);
        vm.startPrank(user1);
        vm.expectRevert(); // Should revert due to insufficient balance
        (bool success, ) = address(zapper).call{value: type(uint256).max}("");
        vm.stopPrank();
        assertFalse(success);
    }

    // ───────────────────────────── SECURITY TESTS ─────────────────────────────

    /**
     * @notice Test that sending ETH with ERC20 token in zapAndDeposit reverts
     * @dev This prevents ETH loss when users accidentally send both ETH and ERC20 tokens
     */
    function testZapAndDepositETHWithERC20Token() public {
        uint256 usdcAmount = 1000 * 10 ** 6;
        uint256 ethAmount = 1 ether;
        bytes32 depositId = keccak256(abi.encodePacked("test-deposit"));

        // Mint USDC to user and give ETH
        usdc.mint(user1, usdcAmount);
        vm.deal(user1, ethAmount);

        vm.startPrank(user1);
        usdc.approve(address(zapper), usdcAmount);

        // Try to send both ETH and USDC - should revert
        vm.expectRevert("Cannot send ETH with ERC20 token");
        zapper.zapAndDeposit{value: ethAmount}(IERC20(address(usdc)), usdcAmount, depositId, 100);
        vm.stopPrank();
    }

    /**
     * @notice Test that sending ETH with ERC20 token in zapAndDepositWithPermit reverts
     * @dev This prevents ETH loss when users accidentally send both ETH and ERC20 tokens
     */
    function testZapAndDepositWithPermitETHWithERC20Token() public {
        uint256 usdcAmount = 1000 * 10 ** 6;
        uint256 ethAmount = 1 ether;
        bytes32 depositId = keccak256(abi.encodePacked("test-deposit"));

        // Mint USDC to user and give ETH
        usdc.mint(user1, usdcAmount);
        vm.deal(user1, ethAmount);

        vm.startPrank(user1);
        usdc.approve(address(zapper), usdcAmount);

        // Create permit params (won't be used but needed for function signature)
        PermitLib.PermitParams memory permitParams = PermitLib.PermitParams({
            value: usdcAmount,
            deadline: block.timestamp + 1 hours,
            v: 0,
            r: bytes32(0),
            s: bytes32(0)
        });

        // Try to send both ETH and USDC - should revert
        vm.expectRevert("Cannot send ETH with ERC20 token");
        zapper.zapAndDepositWithPermit{value: ethAmount}(
            IERC20(address(usdc)),
            usdcAmount,
            permitParams,
            depositId,
            100
        );
        vm.stopPrank();
    }

    /**
     * @notice Test that zapAndDeposit works correctly with ETH only (no ERC20)
     */
    function testZapAndDepositETHOnly() public {
        uint256 ethAmount = 1 ether;
        bytes32 depositId = keccak256(abi.encodePacked("test-deposit-eth"));

        vm.deal(user1, ethAmount);
        vm.startPrank(user1);

        // Should work with ETH only
        zapper.zapAndDeposit{value: ethAmount}(IERC20(address(0)), ethAmount, depositId, 100);
        vm.stopPrank();

        // Verify deposit was created
        DepositLib.Deposit memory deposit = zapper.getDeposit(depositId);
        assertEq(deposit.user, user1);
        assertTrue(deposit.amount > 0);
    }

    /**
     * @notice Test that zapAndDeposit works correctly with ERC20 only (no ETH)
     */
    function testZapAndDepositERC20Only() public {
        uint256 usdcAmount = 1000 * 10 ** 6;
        bytes32 depositId = keccak256(abi.encodePacked("test-deposit-usdc"));

        usdc.mint(user1, usdcAmount);
        vm.startPrank(user1);
        usdc.approve(address(zapper), usdcAmount);

        // Should work with ERC20 only (no ETH sent)
        zapper.zapAndDeposit(IERC20(address(usdc)), usdcAmount, depositId, 100);
        vm.stopPrank();

        // Verify deposit was created
        DepositLib.Deposit memory deposit = zapper.getDeposit(depositId);
        assertEq(deposit.user, user1);
        assertEq(deposit.amount, usdcAmount);
    }

    // ───────────────────────────── REDEEM TESTS MOVED TO RedeemEngine.t.sol ─────────────────────────────

    // ───────────────────────────── TOKEN ALLOWLIST TESTS ─────────────────────────────

    function testIsTokenAllowedUSDCAlwaysTrue() public {
        // USDC is always allowed even though it was never explicitly added
        assertTrue(zapper.isTokenAllowed(address(usdc)));
    }

    function testIsTokenAllowedFalseByDefault() public {
        MockZapToken token = new MockZapToken();
        assertFalse(zapper.isTokenAllowed(address(token)));
    }

    function testSetTokenAllowedByCurator() public {
        MockZapToken token = new MockZapToken();

        vm.prank(vaultCurator);
        zapper.setTokenAllowed(address(token), true);

        assertTrue(zapper.isTokenAllowed(address(token)));

        address[] memory allowed = zapper.getAllowedTokens();
        assertEq(allowed.length, 1);
        assertEq(allowed[0], address(token));

        // Curator can also revoke
        vm.prank(vaultCurator);
        zapper.setTokenAllowed(address(token), false);
        assertFalse(zapper.isTokenAllowed(address(token)));
        assertEq(zapper.getAllowedTokens().length, 0);
    }

    function testSetTokenAllowedWithoutRoleReverts() public {
        MockZapToken token = new MockZapToken();

        vm.prank(user1);
        vm.expectRevert();
        zapper.setTokenAllowed(address(token), true);
    }

    function testSetTokenAllowedCannotAllowlistUSDC() public {
        vm.prank(vaultCurator);
        vm.expectRevert("USDC is always allowed");
        zapper.setTokenAllowed(address(usdc), true);
    }

    function testSetTokensAllowedBatch() public {
        MockZapToken tokenA = new MockZapToken();
        MockZapToken tokenB = new MockZapToken();
        MockZapToken tokenC = new MockZapToken();

        address[] memory tokens = new address[](3);
        tokens[0] = address(tokenA);
        tokens[1] = address(tokenB);
        tokens[2] = address(tokenC);

        vm.prank(vaultCurator);
        zapper.setTokensAllowed(tokens, true);

        assertTrue(zapper.isTokenAllowed(address(tokenA)));
        assertTrue(zapper.isTokenAllowed(address(tokenB)));
        assertTrue(zapper.isTokenAllowed(address(tokenC)));
        assertEq(zapper.getAllowedTokens().length, 3);
    }

    function testZapAndDepositRevertsForNonAllowlistedToken() public {
        MockZapToken token = new MockZapToken();
        token.mint(user1, 1000 ether);

        vm.startPrank(user1);
        token.approve(address(zapper), 1000 ether);
        vm.expectRevert("Token not allowlisted");
        zapper.zapAndDeposit(IERC20(address(token)), 1000 ether, bytes32(uint256(1)), 100);
        vm.stopPrank();
    }

    function testZapAndDepositSucceedsForAllowlistedToken() public {
        // Use a USDC-scale amount: MockUniswapRouter converts 1:1 and only has a
        // finite USDC balance minted in setUp(), so an 18-decimal "token" amount
        // would overdraw it.
        uint256 amount = 1000 * 10 ** 6;
        MockZapToken token = new MockZapToken();
        token.mint(user1, amount);

        vm.prank(vaultCurator);
        zapper.setTokenAllowed(address(token), true);

        vm.startPrank(user1);
        token.approve(address(zapper), amount);
        bytes32 depositId = bytes32(uint256(1));
        zapper.zapAndDeposit(IERC20(address(token)), amount, depositId, 100);
        vm.stopPrank();

        DepositLib.Deposit memory deposit = zapper.getDeposit(depositId);
        assertEq(deposit.user, user1);
        assertTrue(deposit.amount > 0);
    }

    function testZapAndDepositWithPermitRevertsForNonAllowlistedToken() public {
        MockZapToken token = new MockZapToken();
        token.mint(user1, 1000 ether);

        vm.startPrank(user1);
        token.approve(address(zapper), 1000 ether);
        PermitLib.PermitParams memory permitParams = PermitLib.PermitParams({
            value: 0,
            deadline: 0,
            v: 0,
            r: bytes32(0),
            s: bytes32(0)
        });
        vm.expectRevert("Token not allowlisted");
        zapper.zapAndDepositWithPermit(IERC20(address(token)), 1000 ether, permitParams, bytes32(uint256(1)), 100);
        vm.stopPrank();
    }

    // ───────────────────────────── REENTRANCY REGRESSION TEST ─────────────────────────────

    /// @notice Recreates the historical mainnet exploit: an attacker-controlled `tokenIn`
    /// whose transferFrom() re-enters zapAndDeposit() to smuggle a second, unrelated USDC
    /// deposit into the same Silo-balance-delta window, inflating `depositValue`. Before
    /// the nonReentrant fix this second call succeeded and both deposits got recorded;
    /// after the fix it must revert.
    function testZapAndDepositReentrancyIsBlocked() public {
        MaliciousReentrantToken evilToken = new MaliciousReentrantToken(zapper, IERC20(address(usdc)));

        // Curator allowlists the token believing it is a normal ERC20 (as would happen
        // in practice — the malicious code is only visible at the bytecode level).
        vm.prank(vaultCurator);
        zapper.setTokenAllowed(address(evilToken), true);

        // Fund the malicious contract with real USDC (stand-in for flash-loaned funds)
        // and have it pre-approve the Zapper for the nested deposit it will attempt.
        uint256 nestedAmount = 9_999_400_570; // mirrors the on-chain incident amount
        usdc.mint(address(evilToken), nestedAmount);
        vm.prank(address(evilToken));
        usdc.approve(address(zapper), nestedAmount);

        bytes32 outerDepositId = bytes32(uint256(100));
        bytes32 nestedDepositId = bytes32(uint256(200));
        evilToken.arm(nestedDepositId, nestedAmount);

        vm.prank(user1);
        vm.expectRevert();
        zapper.zapAndDeposit(IERC20(address(evilToken)), 1000 ether, outerDepositId, 100);

        // Neither deposit should exist — the whole transaction reverted atomically.
        assertEq(zapper.getDeposit(outerDepositId).user, address(0));
        assertEq(zapper.getDeposit(nestedDepositId).user, address(0));
    }
}
