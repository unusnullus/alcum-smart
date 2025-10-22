// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test, console} from "forge-std/Test.sol";
import {HostAdapter} from "../contracts/HostAdapter.sol";
import {Zapper} from "../contracts/Zapper.sol";
import {CUPToken} from "../contracts/CUPToken.sol";
import {xCUP} from "../contracts/xCUP.sol";
import {EpochManager} from "../contracts/EpochManager.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ICopperPriceConsumer} from "../contracts/interfaces/ICopperPriceConsumer.sol";

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

contract MockUSDC {
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function decimals() external pure returns (uint8) {
        return 6;
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
}

contract HostAdapterTest is Test {
    HostAdapter public hostAdapter;
    Zapper public zapper;
    CUPToken public cupToken;
    xCUP public xcup;
    EpochManager public epochManager;
    MockCopperPriceConsumer public copperPriceConsumer;
    MockUSDC public usdc;
    MockUniswapRouter public uniswapRouter;
    address public owner;
    address public vaultCurator;
    address public hostIntegration;
    address public user1;

    function setUp() public {
        owner = address(this);
        vaultCurator = makeAddr("vaultCurator");
        hostIntegration = makeAddr("hostIntegration");
        user1 = makeAddr("user1");

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
        bytes memory hostAdapterInitData = abi.encodeWithSelector(HostAdapter.initialize.selector, address(zapper));
        ERC1967Proxy hostAdapterProxy = new ERC1967Proxy(address(hostAdapterImpl), hostAdapterInitData);
        hostAdapter = HostAdapter(address(hostAdapterProxy));

        // Grant roles
        zapper.grantRole(zapper.HOST_INTEGRATION_ROLE(), address(hostAdapter));
        zapper.grantRole(zapper.VAULT_CURATOR_ROLE(), vaultCurator);
        zapper.grantRole(zapper.VAULT_CURATOR_ROLE(), hostIntegration);
        zapper.grantRole(zapper.VAULT_CURATOR_ROLE(), address(hostAdapter));
        hostAdapter.grantRole(hostAdapter.HOST_OPERATOR_ROLE(), hostIntegration);
        hostAdapter.grantRole(hostAdapter.CURATOR_OPERATOR_ROLE(), hostIntegration);

        // Grant xCUP redeemer role to zapper
        xcup.grantRole(xcup.REDEEMER_ROLE(), address(zapper));

        // Grant zapper permission to spend CUP tokens
        cupToken.grantRole(cupToken.MINTER_ROLE(), address(zapper));

        // Mint some tokens for testing
        usdc.mint(user1, 1000000 * 10 ** 6); // 1M USDC
        cupToken.grantRole(cupToken.MINTER_ROLE(), address(this));
        cupToken.mint(address(zapper), 1000000 * 10 ** 6); // 1M CUP tokens
    }

    function testInitialization() public {
        assertEq(hostAdapter.zapper(), address(zapper));
        assertTrue(hostAdapter.hasRole(hostAdapter.DEFAULT_ADMIN_ROLE(), owner));
        assertTrue(hostAdapter.hasRole(hostAdapter.HOST_OPERATOR_ROLE(), hostIntegration));
    }

    function testRegisterExternalDepositFor() public {
        uint256 amount = 1000 * 10 ** 6;

        vm.prank(hostIntegration);
        bytes32 depositId =
            hostAdapter.registerExternalDepositFor(user1, amount, bytes32(uint256(uint160(address(usdc)))));

        // Check that deposit was recorded in zapper
        Zapper.Deposit memory deposit = zapper.getDeposit(depositId);
        assertEq(deposit.beneficiary, user1);
        assertEq(deposit.amount, amount);
        assertEq(deposit.beneficiary, user1);
    }

    function testRegisterExternalDepositForWithoutRole() public {
        vm.prank(user1);
        vm.expectRevert();
        hostAdapter.registerExternalDepositFor(user1, 1000 * 10 ** 6, bytes32(uint256(uint160(address(usdc)))));
    }

    function testSetDepositBeneficiary() public {
        address newBeneficiary = makeAddr("newBeneficiary");
        uint256 amount = 1000 * 10 ** 6;

        // First register a deposit
        vm.prank(hostIntegration);
        bytes32 depositId =
            hostAdapter.registerExternalDepositFor(user1, amount, bytes32(uint256(uint160(address(usdc)))));

        // Then set beneficiary
        vm.prank(hostIntegration);
        hostAdapter.setDepositBeneficiary(depositId, newBeneficiary);

        // Check that beneficiary was updated
        Zapper.Deposit memory deposit = zapper.getDeposit(depositId);
        assertEq(deposit.beneficiary, newBeneficiary);
    }

    function testSetDepositBeneficiaryWithoutRole() public {
        vm.prank(user1);
        vm.expectRevert();
        hostAdapter.setDepositBeneficiary(bytes32(uint256(uint160(user1))), makeAddr("newBeneficiary"));
    }

    function testApproveExternalDepositWithPrice() public {
        uint256 amount = 1000 * 10 ** 6;
        uint256 price = 450000000; // $4.50 with 8 decimals

        // Register deposit first
        vm.prank(hostIntegration);
        bytes32 depositId =
            hostAdapter.registerExternalDepositFor(user1, amount, bytes32(uint256(uint160(address(usdc)))));

        // Approve with price
        vm.prank(hostIntegration);
        hostAdapter.approveExternalDepositWithPrice(depositId, amount, price);

        // Check that deposit was approved
        Zapper.Deposit memory deposit = zapper.getDeposit(depositId);
        assertTrue(deposit.approved);
    }

    function testApproveExternalDepositWithPriceWithoutRole() public {
        uint256 amount = 1000 * 10 ** 6;
        uint256 price = 450000000;

        // Register deposit first
        vm.prank(hostIntegration);
        hostAdapter.registerExternalDepositFor(user1, amount, bytes32(uint256(uint160(address(usdc)))));

        // Try to approve without role
        vm.prank(user1);
        vm.expectRevert();
        hostAdapter.approveExternalDepositWithPrice(bytes32(0), amount, price);
    }

    function testSetZapper() public {
        address newZapper = makeAddr("newZapper");
        hostAdapter.setZapper(payable(newZapper));
        assertEq(hostAdapter.zapper(), newZapper);
    }

    function testSetZapperWithoutRole() public {
        vm.prank(user1);
        vm.expectRevert();
        hostAdapter.setZapper(payable(makeAddr("newZapper")));
    }

    // Test error cases for better branch coverage
    function testRegisterExternalDepositForWithZeroBeneficiary() public {
        vm.prank(hostIntegration);
        vm.expectRevert(HostAdapter.InvalidBeneficiary.selector);
        hostAdapter.registerExternalDepositFor(address(0), 1000 * 10 ** 6, bytes32(uint256(uint160(address(usdc)))));
    }

    function testRegisterExternalDepositForWithZeroAmount() public {
        vm.prank(hostIntegration);
        vm.expectRevert(HostAdapter.InvalidAmount.selector);
        hostAdapter.registerExternalDepositFor(user1, 0, bytes32(uint256(uint160(address(usdc)))));
    }

    function testSetDepositBeneficiaryWithZeroBeneficiary() public {
        uint256 amount = 1000 * 10 ** 6;

        // First register a deposit
        vm.prank(hostIntegration);
        bytes32 depositId =
            hostAdapter.registerExternalDepositFor(user1, amount, bytes32(uint256(uint160(address(usdc)))));

        // Try to set zero beneficiary
        vm.prank(hostIntegration);
        vm.expectRevert(HostAdapter.InvalidBeneficiary.selector);
        hostAdapter.setDepositBeneficiary(depositId, address(0));
    }

    function testApproveExternalDepositWithPriceWithZeroAmount() public {
        uint256 amount = 1000 * 10 ** 6;
        uint256 price = 450000000;

        // Register deposit first
        vm.prank(hostIntegration);
        bytes32 depositId =
            hostAdapter.registerExternalDepositFor(user1, amount, bytes32(uint256(uint160(address(usdc)))));

        // Try to approve with zero amount
        vm.prank(hostIntegration);
        vm.expectRevert(HostAdapter.InvalidApprovedAmount.selector);
        hostAdapter.approveExternalDepositWithPrice(depositId, 0, price);
    }

    function testApproveExternalDepositWithPriceWithZeroPrice() public {
        uint256 amount = 1000 * 10 ** 6;

        // Register deposit first
        vm.prank(hostIntegration);
        bytes32 depositId =
            hostAdapter.registerExternalDepositFor(user1, amount, bytes32(uint256(uint160(address(usdc)))));

        // Try to approve with zero price
        vm.prank(hostIntegration);
        vm.expectRevert(HostAdapter.InvalidPrice.selector);
        hostAdapter.approveExternalDepositWithPrice(depositId, amount, 0);
    }

    function testSetZapperWithZeroAddress() public {
        vm.expectRevert(HostAdapter.InvalidZapperAddress.selector);
        hostAdapter.setZapper(payable(address(0)));
    }

    function testSetZapperWithSameAddress() public {
        vm.expectRevert(HostAdapter.SameZapperAddress.selector);
        hostAdapter.setZapper(payable(address(zapper)));
    }

    // Test initialization error case for better branch coverage
    function testInitializeWithZeroZapper() public {
        HostAdapter hostAdapterImpl = new HostAdapter();
        bytes memory hostAdapterInitData = abi.encodeWithSelector(HostAdapter.initialize.selector, address(0));

        vm.expectRevert(HostAdapter.InvalidZapperAddress.selector);
        new ERC1967Proxy(address(hostAdapterImpl), hostAdapterInitData);
    }
}
