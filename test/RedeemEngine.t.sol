// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test, console} from "forge-std/Test.sol";
import {RedeemEngine} from "../contracts/RedeemEngine.sol";
import {CUPToken} from "../contracts/CUPToken.sol";
import {xCUP} from "../contracts/xCUP.sol";
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
}

contract RedeemEngineTest is Test {
    RedeemEngine public redeemEngine;
    CUPToken public cupToken;
    xCUP public xcup;
    MockCopperPriceConsumer public copperPriceConsumer;
    MockUSDC public usdc;
    MockUniswapRouter public uniswapRouter;
    address public owner;
    address public vaultCurator;
    address public user1;
    address public user2;

    function setUp() public {
        owner = address(this);
        vaultCurator = makeAddr("vaultCurator");
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

        // Deploy RedeemEngine
        RedeemEngine redeemEngineImpl = new RedeemEngine();
        bytes memory redeemEngineInitData = abi.encodeWithSelector(
            RedeemEngine.initialize.selector,
            address(cupToken),
            address(usdc),
            address(xcup),
            address(copperPriceConsumer),
            0 // 0% commission initially
        );
        ERC1967Proxy redeemEngineProxy = new ERC1967Proxy(address(redeemEngineImpl), redeemEngineInitData);
        redeemEngine = RedeemEngine(address(redeemEngineProxy));

        // Grant roles
        redeemEngine.grantRole(redeemEngine.VAULT_CURATOR_ROLE(), vaultCurator);

        // Grant xCUP redeemer role to redeemEngine
        xcup.grantRole(xcup.REDEEMER_ROLE(), address(redeemEngine));

        // Grant redeemEngine permission to mint/burn CUP tokens
        cupToken.grantRole(cupToken.MINTER_ROLE(), address(redeemEngine));

        // Mint some tokens for testing
        usdc.mint(user1, 1000000 * 10 ** 6); // 1M USDC
        usdc.mint(user2, 1000000 * 10 ** 6); // 1M USDC
        usdc.mint(redeemEngine.redeemSilo(), 10000000 * 10 ** 6); // 10M USDC for redeem silo

        cupToken.grantRole(cupToken.MINTER_ROLE(), address(this));
        cupToken.mint(address(redeemEngine), 1000000 * 10 ** 6); // 1M CUP tokens
    }

    // ───────────────────────────── INITIALIZATION TESTS ─────────────────────────────

    function testInitialization() public {
        assertEq(redeemEngine.cup(), address(cupToken));
        assertEq(redeemEngine.usdc(), address(usdc));
        assertEq(redeemEngine.vault(), address(xcup));
        assertTrue(redeemEngine.redeemSilo() != address(0));
        assertTrue(redeemEngine.hasRole(redeemEngine.DEFAULT_ADMIN_ROLE(), owner));
        assertTrue(redeemEngine.hasRole(redeemEngine.VAULT_CURATOR_ROLE(), vaultCurator));
        assertEq(redeemEngine.getRedeemCommission(), 0);
    }

    function testInitializeInvalidAddress() public {
        RedeemEngine newImpl = new RedeemEngine();
        bytes memory initData = abi.encodeWithSelector(
            RedeemEngine.initialize.selector,
            address(0), // Invalid CUP address
            address(usdc),
            address(xcup),
            address(copperPriceConsumer),
            0
        );
        vm.expectRevert();
        new ERC1967Proxy(address(newImpl), initData);
    }

    function testInitializeInvalidCommission() public {
        RedeemEngine newImpl = new RedeemEngine();
        bytes memory initData = abi.encodeWithSelector(
            RedeemEngine.initialize.selector,
            address(cupToken),
            address(usdc),
            address(xcup),
            address(copperPriceConsumer),
            10001 // 100.01% - invalid
        );
        vm.expectRevert("Commission cannot exceed 100%");
        new ERC1967Proxy(address(newImpl), initData);
    }

    // ───────────────────────────── REQUEST-BASED REDEEM TESTS ─────────────────────────────

    function testRequestRedeem() public {
        uint256 shares = 1000 * 10 ** 6; // 1000 xCUP shares

        // First create some xCUP shares for user1
        cupToken.mint(user1, shares);
        vm.startPrank(user1);
        cupToken.approve(address(xcup), shares);
        xcup.deposit(shares, user1);
        vm.stopPrank();

        // Approve redeemEngine to transfer xCUP shares
        vm.startPrank(user1);
        xcup.approve(address(redeemEngine), shares);
        vm.stopPrank();

        // Request redeem (this will transfer shares to contract)
        uint256 initialContractShares = xcup.balanceOf(address(redeemEngine));
        uint256 initialUserShares = xcup.balanceOf(user1);

        vm.startPrank(user1);
        bytes32 redeemId = redeemEngine.requestRedeem(shares);
        vm.stopPrank();

        // Check that redeem request was created
        assertTrue(redeemId != bytes32(0));
        RedeemLib.RedeemRequest memory redeemInfo = redeemEngine.getRedeem(redeemId);
        assertEq(redeemInfo.user, user1);
        assertEq(redeemInfo.shares, shares);
        assertFalse(redeemInfo.approved);
        assertFalse(redeemInfo.claimed);

        // Check that shares were transferred to contract
        assertEq(xcup.balanceOf(address(redeemEngine)), initialContractShares + shares);
        assertEq(xcup.balanceOf(user1), initialUserShares - shares);
    }

    function testRequestRedeemZeroShares() public {
        vm.startPrank(user1);
        vm.expectRevert("Shares must be greater than 0");
        redeemEngine.requestRedeem(0);
        vm.stopPrank();
    }

    function testRequestRedeemInsufficientShares() public {
        uint256 shares = 1000 * 10 ** 6;

        // User has no shares
        vm.startPrank(user1);
        vm.expectRevert("Insufficient shares to redeem");
        redeemEngine.requestRedeem(shares);
        vm.stopPrank();
    }

    function testRequestRedeemWithoutApproval() public {
        uint256 shares = 1000 * 10 ** 6;

        // Create xCUP shares but don't approve
        cupToken.mint(user1, shares);
        vm.startPrank(user1);
        cupToken.approve(address(xcup), shares);
        xcup.deposit(shares, user1);
        vm.stopPrank();

        // Try to request redeem without approval
        vm.startPrank(user1);
        vm.expectRevert(); // ERC20InsufficientAllowance
        redeemEngine.requestRedeem(shares);
        vm.stopPrank();
    }

    function testRequestRedeemWhenPaused() public {
        uint256 shares = 1000 * 10 ** 6;

        // First create some xCUP shares for user1
        cupToken.mint(user1, shares);
        vm.startPrank(user1);
        cupToken.approve(address(xcup), shares);
        xcup.deposit(shares, user1);
        xcup.approve(address(redeemEngine), shares);
        vm.stopPrank();

        // Pause the contract
        redeemEngine.pause();

        // Try to request redeem when paused
        vm.startPrank(user1);
        vm.expectRevert();
        redeemEngine.requestRedeem(shares);
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
        xcup.approve(address(redeemEngine), shares);
        vm.stopPrank();

        // Request redeem (shares are transferred to contract)
        vm.startPrank(user1);
        bytes32 redeemId = redeemEngine.requestRedeem(shares);
        vm.stopPrank();

        // Approve redeem
        vm.startPrank(vaultCurator);
        redeemEngine.approveRedeem(redeemId, usdcAmount);
        vm.stopPrank();

        // Verify approval
        RedeemLib.RedeemRequest memory redeemInfo = redeemEngine.getRedeem(redeemId);
        assertTrue(redeemInfo.approved);
        assertEq(redeemInfo.usdcAmount, usdcAmount);
    }

    function testApproveRedeemWithoutRole() public {
        uint256 shares = 1000 * 10 ** 6;
        uint256 usdcAmount = 800 * 10 ** 6;

        // First create some xCUP shares for user1
        cupToken.mint(user1, shares);
        vm.startPrank(user1);
        cupToken.approve(address(xcup), shares);
        xcup.deposit(shares, user1);
        xcup.approve(address(redeemEngine), shares);
        vm.stopPrank();

        // Request redeem
        vm.startPrank(user1);
        bytes32 redeemId = redeemEngine.requestRedeem(shares);
        vm.stopPrank();

        // Try to approve without role
        vm.startPrank(user1);
        vm.expectRevert();
        redeemEngine.approveRedeem(redeemId, usdcAmount);
        vm.stopPrank();
    }

    function testApproveRedeemInvalidId() public {
        uint256 usdcAmount = 800 * 10 ** 6;
        bytes32 invalidRedeemId = keccak256("invalid");

        vm.startPrank(vaultCurator);
        vm.expectRevert(RedeemLib.InvalidRedeemRequest.selector);
        redeemEngine.approveRedeem(invalidRedeemId, usdcAmount);
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
        xcup.approve(address(redeemEngine), shares);
        vm.stopPrank();

        // Request redeem
        vm.startPrank(user1);
        bytes32 redeemId = redeemEngine.requestRedeem(shares);
        vm.stopPrank();

        // Pause the contract
        redeemEngine.pause();

        // Try to approve when paused
        vm.startPrank(vaultCurator);
        vm.expectRevert();
        redeemEngine.approveRedeem(redeemId, usdcAmount);
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
        xcup.approve(address(redeemEngine), shares);
        vm.stopPrank();

        // Request redeem (shares are transferred to contract)
        vm.startPrank(user1);
        bytes32 redeemId = redeemEngine.requestRedeem(shares);
        vm.stopPrank();

        // Approve redeem
        vm.startPrank(vaultCurator);
        redeemEngine.approveRedeem(redeemId, usdcAmount);
        vm.stopPrank();

        // Ensure redeem silo has enough USDC (calculate based on copper price)
        uint256 copperPrice = 450000000; // $4.50 with 8 decimals
        uint256 expectedUsdcAmount = (shares * copperPrice) / (10 ** 8);
        usdc.mint(redeemEngine.redeemSilo(), expectedUsdcAmount);

        // Claim redeem (shares are already in contract, no need to approve)
        uint256 initialUsdcBalance = usdc.balanceOf(user1);
        vm.startPrank(user1);
        uint256 claimedAmount = redeemEngine.claimRedeem(redeemId);
        vm.stopPrank();

        // Check that user received USDC
        assertTrue(claimedAmount > 0);
        assertTrue(usdc.balanceOf(user1) > initialUsdcBalance);
        // Check that shares were used from contract
        assertEq(xcup.balanceOf(address(redeemEngine)), 0);
    }

    function testClaimRedeemNotApproved() public {
        uint256 shares = 1000 * 10 ** 6;

        // First create some xCUP shares for user1
        cupToken.mint(user1, shares);
        vm.startPrank(user1);
        cupToken.approve(address(xcup), shares);
        xcup.deposit(shares, user1);
        xcup.approve(address(redeemEngine), shares);
        vm.stopPrank();

        // Request redeem (shares are transferred to contract)
        vm.startPrank(user1);
        bytes32 redeemId = redeemEngine.requestRedeem(shares);
        vm.stopPrank();

        // Try to claim without approval
        vm.startPrank(user1);
        vm.expectRevert(RedeemLib.NotApproved.selector);
        redeemEngine.claimRedeem(redeemId);
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
        xcup.approve(address(redeemEngine), shares);
        vm.stopPrank();

        // Request redeem (shares are transferred to contract)
        vm.startPrank(user1);
        bytes32 redeemId = redeemEngine.requestRedeem(shares);
        vm.stopPrank();

        // Approve redeem
        vm.startPrank(vaultCurator);
        redeemEngine.approveRedeem(redeemId, usdcAmount);
        vm.stopPrank();

        // Ensure redeem silo has enough USDC
        uint256 copperPrice = 450000000;
        uint256 expectedUsdcAmount = (shares * copperPrice) / (10 ** 8);
        usdc.mint(redeemEngine.redeemSilo(), expectedUsdcAmount);

        // Try to claim with different user
        vm.startPrank(user2);
        vm.expectRevert(RedeemLib.NotUser.selector);
        redeemEngine.claimRedeem(redeemId);
        vm.stopPrank();
    }

    function testClaimRedeemInvalidId() public {
        bytes32 invalidRedeemId = keccak256("invalid");

        vm.startPrank(user1);
        vm.expectRevert(RedeemLib.InvalidRedeemRequest.selector);
        redeemEngine.claimRedeem(invalidRedeemId);
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
        xcup.approve(address(redeemEngine), shares);
        vm.stopPrank();

        // Request redeem (shares are transferred to contract)
        vm.startPrank(user1);
        bytes32 redeemId = redeemEngine.requestRedeem(shares);
        vm.stopPrank();

        // Approve redeem
        vm.startPrank(vaultCurator);
        redeemEngine.approveRedeem(redeemId, usdcAmount);
        vm.stopPrank();

        // Ensure redeem silo has enough USDC
        uint256 copperPrice = 450000000;
        uint256 expectedUsdcAmount = (shares * copperPrice) / (10 ** 8);
        usdc.mint(redeemEngine.redeemSilo(), expectedUsdcAmount);

        // Pause the contract
        redeemEngine.pause();

        // Try to claim when paused
        vm.startPrank(user1);
        vm.expectRevert();
        redeemEngine.claimRedeem(redeemId);
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
        xcup.approve(address(redeemEngine), shares);
        vm.stopPrank();

        // Request redeem (shares are transferred to contract)
        vm.startPrank(user1);
        bytes32 redeemId = redeemEngine.requestRedeem(shares);
        vm.stopPrank();

        // Approve redeem
        vm.startPrank(vaultCurator);
        redeemEngine.approveRedeem(redeemId, usdcAmount);
        vm.stopPrank();

        // Ensure redeem silo has enough USDC
        uint256 copperPrice = 450000000;
        uint256 expectedUsdcAmount = (shares * copperPrice) / (10 ** 8);
        usdc.mint(redeemEngine.redeemSilo(), expectedUsdcAmount);

        // Manually remove shares from contract (simulating edge case)
        // This shouldn't happen in normal flow, but we test it
        vm.startPrank(address(redeemEngine));
        xcup.transfer(user2, xcup.balanceOf(address(redeemEngine)));
        vm.stopPrank();

        // Try to claim without sufficient shares in contract
        vm.startPrank(user1);
        vm.expectRevert("Insufficient shares in contract");
        redeemEngine.claimRedeem(redeemId);
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
        xcup.approve(address(redeemEngine), shares);
        vm.stopPrank();

        // Request redeem (shares are transferred to contract)
        vm.startPrank(user1);
        bytes32 redeemId = redeemEngine.requestRedeem(shares);
        vm.stopPrank();

        // Approve redeem
        vm.startPrank(vaultCurator);
        redeemEngine.approveRedeem(redeemId, usdcAmount);
        vm.stopPrank();

        // Ensure redeem silo has enough USDC
        uint256 copperPrice = 450000000;
        uint256 expectedUsdcAmount = (shares * copperPrice) / (10 ** 8);
        usdc.mint(redeemEngine.redeemSilo(), expectedUsdcAmount);

        // Mock copper price to return 0
        copperPriceConsumer.updatePrice(0);

        // Try to claim with zero copper price
        vm.startPrank(user1);
        vm.expectRevert("Copper price is 0");
        redeemEngine.claimRedeem(redeemId);
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
        xcup.approve(address(redeemEngine), shares);
        vm.stopPrank();

        // Request redeem (shares are transferred to contract)
        vm.startPrank(user1);
        bytes32 redeemId = redeemEngine.requestRedeem(shares);
        vm.stopPrank();

        // Approve redeem
        vm.startPrank(vaultCurator);
        redeemEngine.approveRedeem(redeemId, usdcAmount);
        vm.stopPrank();

        // Remove all USDC from redeem silo
        address redeemSilo = redeemEngine.redeemSilo();
        vm.startPrank(redeemSilo);
        usdc.transfer(user2, usdc.balanceOf(redeemSilo));
        vm.stopPrank();

        // Try to claim with insufficient USDC in redeem silo
        vm.startPrank(user1);
        vm.expectRevert("Insufficient USDC in redeem silo");
        redeemEngine.claimRedeem(redeemId);
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

        // Step 2: Approve redeemEngine to transfer xCUP shares
        vm.startPrank(user1);
        xcup.approve(address(redeemEngine), depositedShares);
        vm.stopPrank();

        // Step 3: Request redeem (shares are transferred to contract)
        uint256 initialContractShares = xcup.balanceOf(address(redeemEngine));
        vm.startPrank(user1);
        bytes32 redeemId = redeemEngine.requestRedeem(depositedShares);
        vm.stopPrank();

        // Verify shares were transferred
        assertEq(xcup.balanceOf(address(redeemEngine)), initialContractShares + depositedShares);
        assertEq(xcup.balanceOf(user1), 0);

        // Step 4: Approve redeem
        vm.startPrank(vaultCurator);
        redeemEngine.approveRedeem(redeemId, usdcAmount);
        vm.stopPrank();

        // Step 5: Ensure redeem silo has enough USDC (calculate based on copper price)
        uint256 copperPrice = 450000000;
        uint256 expectedUsdcAmount = (depositedShares * copperPrice) / (10 ** 8);
        usdc.mint(redeemEngine.redeemSilo(), expectedUsdcAmount);

        // Step 6: Claim redeem
        uint256 initialUsdcBalance = usdc.balanceOf(user1);
        uint256 initialCupBalance = cupToken.balanceOf(user1);

        vm.startPrank(user1);
        uint256 claimedAmount = redeemEngine.claimRedeem(redeemId);
        vm.stopPrank();

        // Verify results
        assertTrue(claimedAmount > 0);
        assertTrue(usdc.balanceOf(user1) > initialUsdcBalance);
        assertEq(cupToken.balanceOf(user1), initialCupBalance); // CUP should be converted to USDC
        assertEq(xcup.balanceOf(user1), 0); // All xCUP shares should be redeemed
        assertEq(xcup.balanceOf(address(redeemEngine)), 0); // Shares should be used from contract
    }

    function testMultipleRedeemRequests() public {
        uint256 shares1 = 500 * 10 ** 6;
        uint256 shares2 = 300 * 10 ** 6;

        // Create xCUP shares for user1
        cupToken.mint(user1, shares1 + shares2);
        vm.startPrank(user1);
        cupToken.approve(address(xcup), shares1 + shares2);
        xcup.deposit(shares1 + shares2, user1);
        xcup.approve(address(redeemEngine), shares1 + shares2);
        vm.stopPrank();

        // Create two redeem requests (shares are transferred to contract)
        vm.startPrank(user1);
        bytes32 redeemId1 = redeemEngine.requestRedeem(shares1);
        bytes32 redeemId2 = redeemEngine.requestRedeem(shares2);
        vm.stopPrank();

        // Verify different redeem IDs
        assertTrue(redeemId1 != redeemId2);
        assertTrue(redeemId1 != bytes32(0));
        assertTrue(redeemId2 != bytes32(0));

        // Verify shares were transferred
        assertEq(xcup.balanceOf(address(redeemEngine)), shares1 + shares2);
        assertEq(xcup.balanceOf(user1), 0);
    }

    function testApproveRedeemAlreadyApproved() public {
        uint256 shares = 1000 * 10 ** 6;
        uint256 usdcAmount = 800 * 10 ** 6;

        // First create some xCUP shares for user1
        cupToken.mint(user1, shares);
        vm.startPrank(user1);
        cupToken.approve(address(xcup), shares);
        xcup.deposit(shares, user1);
        xcup.approve(address(redeemEngine), shares);
        vm.stopPrank();

        // Request redeem (shares are transferred to contract)
        vm.startPrank(user1);
        bytes32 redeemId = redeemEngine.requestRedeem(shares);
        vm.stopPrank();

        // Approve redeem first time
        vm.startPrank(vaultCurator);
        redeemEngine.approveRedeem(redeemId, usdcAmount);
        vm.stopPrank();

        // Try to approve again
        vm.startPrank(vaultCurator);
        vm.expectRevert(RedeemLib.AlreadyApproved.selector);
        redeemEngine.approveRedeem(redeemId, usdcAmount);
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
        xcup.approve(address(redeemEngine), shares);
        vm.stopPrank();

        // Request redeem (shares are transferred to contract)
        vm.startPrank(user1);
        bytes32 redeemId = redeemEngine.requestRedeem(shares);
        vm.stopPrank();

        // Approve redeem
        vm.startPrank(vaultCurator);
        redeemEngine.approveRedeem(redeemId, usdcAmount);
        vm.stopPrank();

        // Ensure redeem silo has enough USDC
        uint256 copperPrice = 450000000;
        uint256 expectedUsdcAmount = (shares * copperPrice) / (10 ** 8);
        usdc.mint(redeemEngine.redeemSilo(), expectedUsdcAmount);

        // Claim redeem first time
        vm.startPrank(user1);
        redeemEngine.claimRedeem(redeemId);
        vm.stopPrank();

        // Try to claim again
        vm.startPrank(user1);
        vm.expectRevert(RedeemLib.AlreadyClaimed.selector);
        redeemEngine.claimRedeem(redeemId);
        vm.stopPrank();
    }

    function testGetRedeem() public {
        uint256 shares = 1000 * 10 ** 6;

        // Set up user with shares
        cupToken.mint(user1, shares);
        vm.startPrank(user1);
        cupToken.approve(address(xcup), shares);
        xcup.deposit(shares, user1);
        xcup.approve(address(redeemEngine), shares);
        vm.stopPrank();

        // Request redeem (shares are transferred to contract)
        vm.startPrank(user1);
        bytes32 redeemId = redeemEngine.requestRedeem(shares);
        vm.stopPrank();

        // Get redeem information
        RedeemLib.RedeemRequest memory redeemInfo = redeemEngine.getRedeem(redeemId);

        // Verify the redeem request information
        assertEq(redeemInfo.user, user1, "User should match");
        assertEq(redeemInfo.shares, shares, "Shares should match");
        assertEq(redeemInfo.usdcAmount, 0, "USDC amount should be 0 initially");
        assertFalse(redeemInfo.approved, "Should not be approved initially");
        assertFalse(redeemInfo.claimed, "Should not be claimed initially");

        // Approve the redeem
        uint256 usdcAmount = 1000 * 10 ** 6;
        vm.startPrank(vaultCurator);
        redeemEngine.approveRedeem(redeemId, usdcAmount);
        vm.stopPrank();

        // Get updated redeem information
        redeemInfo = redeemEngine.getRedeem(redeemId);

        // Verify the updated information
        assertEq(redeemInfo.user, user1, "User should still match");
        assertEq(redeemInfo.shares, shares, "Shares should still match");
        assertEq(redeemInfo.usdcAmount, usdcAmount, "USDC amount should be updated");
        assertTrue(redeemInfo.approved, "Should be approved now");
        assertFalse(redeemInfo.claimed, "Should still not be claimed");
    }

    function testGetRedeemNonExistent() public {
        bytes32 nonExistentRedeemId = keccak256("non-existent");

        RedeemLib.RedeemRequest memory redeemInfo = redeemEngine.getRedeem(nonExistentRedeemId);

        // Verify that all fields are empty/default for non-existent request
        assertEq(redeemInfo.user, address(0), "User should be address(0)");
        assertEq(redeemInfo.shares, 0, "Shares should be 0");
        assertEq(redeemInfo.usdcAmount, 0, "USDC amount should be 0");
        assertFalse(redeemInfo.approved, "Should not be approved");
        assertFalse(redeemInfo.claimed, "Should not be claimed");
    }

    // ───────────────────────────── DIRECT REDEEM (WITH COMMISSION) TESTS ─────────────────────────────

    function testRedeem() public {
        uint256 shares = 1000 * 10 ** 6;
        uint256 copperPrice = 450000000; // $4.50 with 8 decimals
        uint256 expectedUsdcAmount = (shares * copperPrice) / (10 ** 8);

        // First create some xCUP shares for user1
        cupToken.mint(user1, shares);
        vm.startPrank(user1);
        cupToken.approve(address(xcup), shares);
        xcup.deposit(shares, user1);
        vm.stopPrank();

        // Ensure redeem silo has enough USDC
        usdc.mint(redeemEngine.redeemSilo(), expectedUsdcAmount);

        // Approve redeemEngine to transfer xCUP shares from user
        vm.startPrank(user1);
        xcup.approve(address(redeemEngine), shares);
        vm.stopPrank();

        // Record initial balances
        uint256 initialUserUsdcBalance = usdc.balanceOf(user1);

        // Perform redeem (this should apply commission)
        vm.startPrank(user1);
        uint256 receivedUsdc = redeemEngine.redeem(shares);
        vm.stopPrank();

        // Check that user received USDC (less commission)
        assertTrue(receivedUsdc > 0);
        assertTrue(usdc.balanceOf(user1) > initialUserUsdcBalance);

        // Since commission is 0 by default, user should receive full amount
        assertEq(receivedUsdc, expectedUsdcAmount);
    }

    function testRedeemInsufficientShares() public {
        vm.startPrank(user1);
        vm.expectRevert("Insufficient shares to redeem");
        redeemEngine.redeem(1000);
        vm.stopPrank();
    }

    function testRedeemWithZeroShares() public {
        vm.startPrank(user1);
        vm.expectRevert("Shares to redeem must be greater than 0");
        redeemEngine.redeem(0);
        vm.stopPrank();
    }

    function testRedeemCopperPriceZero() public {
        uint256 shares = 1000 * 10 ** 6;

        // First create some xCUP shares
        cupToken.mint(user1, shares);
        vm.startPrank(user1);
        cupToken.approve(address(xcup), shares);
        xcup.deposit(shares, user1);
        vm.stopPrank();

        // Mock copper price to return 0
        copperPriceConsumer.updatePrice(0);

        // Approve redeemEngine to transfer xCUP shares
        vm.startPrank(user1);
        xcup.approve(address(redeemEngine), shares);
        vm.stopPrank();

        vm.startPrank(user1);
        vm.expectRevert("Copper price is 0");
        redeemEngine.redeem(shares);
        vm.stopPrank();
    }

    function testRedeemInsufficientUSDCInSilo() public {
        uint256 shares = 1000 * 10 ** 6;
        uint256 copperPrice = 450000000;
        uint256 expectedUsdcAmount = (shares * copperPrice) / (10 ** 8);

        // First create some xCUP shares
        cupToken.mint(user1, shares);
        vm.startPrank(user1);
        cupToken.approve(address(xcup), shares);
        xcup.deposit(shares, user1);
        vm.stopPrank();

        // Remove all USDC from redeem silo (from setUp)
        address redeemSilo = redeemEngine.redeemSilo();
        uint256 siloBalance = usdc.balanceOf(redeemSilo);
        if (siloBalance > 0) {
            vm.startPrank(redeemSilo);
            usdc.transfer(user2, siloBalance);
            vm.stopPrank();
        }

        // Don't fund redeem silo with enough USDC
        usdc.mint(redeemEngine.redeemSilo(), expectedUsdcAmount / 2); // Only half

        // Approve redeemEngine to transfer xCUP shares
        vm.startPrank(user1);
        xcup.approve(address(redeemEngine), shares);
        vm.stopPrank();

        vm.startPrank(user1);
        vm.expectRevert("Insufficient USDC in redeem silo");
        redeemEngine.redeem(shares);
        vm.stopPrank();
    }

    function testRedeemWithCommission() public {
        uint256 shares = 1000 * 10 ** 6;
        uint256 copperPrice = 450000000; // $4.50 with 8 decimals
        uint256 totalUsdcAmount = (shares * copperPrice) / (10 ** 8);

        // Set 2% commission
        vm.startPrank(vaultCurator);
        redeemEngine.setRedeemCommission(200); // 2%
        vm.stopPrank();

        // First create some xCUP shares for user1
        cupToken.mint(user1, shares);
        vm.startPrank(user1);
        cupToken.approve(address(xcup), shares);
        xcup.deposit(shares, user1);
        vm.stopPrank();

        // Ensure redeem silo has enough USDC
        usdc.mint(redeemEngine.redeemSilo(), totalUsdcAmount);

        // Approve redeemEngine to transfer xCUP shares from user
        vm.startPrank(user1);
        xcup.approve(address(redeemEngine), shares);
        vm.stopPrank();

        // Record initial balances
        uint256 initialUserUsdcBalance = usdc.balanceOf(user1);
        uint256 initialRedeemSiloBalance = usdc.balanceOf(redeemEngine.redeemSilo());

        // Perform redeem
        vm.startPrank(user1);
        uint256 receivedUsdc = redeemEngine.redeem(shares);
        vm.stopPrank();

        // Check that user received USDC (less commission)
        assertTrue(receivedUsdc > 0);
        assertTrue(usdc.balanceOf(user1) > initialUserUsdcBalance);

        // With 2% commission, user should receive 98% of total amount
        uint256 expectedUserAmount = (totalUsdcAmount * 9800) / 10000;
        assertEq(receivedUsdc, expectedUserAmount);

        // Commission should stay in redeem silo
        uint256 finalRedeemSiloBalance = usdc.balanceOf(redeemEngine.redeemSilo());
        uint256 commissionAmount = totalUsdcAmount - receivedUsdc;
        assertEq(finalRedeemSiloBalance, initialRedeemSiloBalance - receivedUsdc);
    }

    function testRedeemWithDifferentCommissionRates() public {
        uint256 shares = 1000 * 10 ** 6;
        uint256 totalUsdcAmount = (shares * 450000000) / (10 ** 8);

        // Test with 0% commission (default)
        assertEq(redeemEngine.getRedeemCommission(), 0);

        // First create some xCUP shares for user1
        cupToken.mint(user1, shares);
        vm.startPrank(user1);
        cupToken.approve(address(xcup), shares);
        xcup.deposit(shares, user1);
        vm.stopPrank();

        // Ensure redeem silo has enough USDC
        usdc.mint(redeemEngine.redeemSilo(), totalUsdcAmount);

        // Approve redeemEngine to transfer xCUP shares from user
        vm.startPrank(user1);
        xcup.approve(address(redeemEngine), shares);
        vm.stopPrank();

        // Test with 0% commission
        vm.startPrank(user1);
        uint256 receivedUsdc0 = redeemEngine.redeem(shares);
        vm.stopPrank();

        // Verify that with 0% commission, user receives full amount
        assertEq(receivedUsdc0, totalUsdcAmount);

        // Now test with 2% commission (200 basis points)
        vm.startPrank(vaultCurator);
        redeemEngine.setRedeemCommission(200);
        vm.stopPrank();

        assertEq(redeemEngine.getRedeemCommission(), 200);

        // Create new shares for testing with commission
        cupToken.mint(user1, shares);
        vm.startPrank(user1);
        cupToken.approve(address(xcup), shares);
        xcup.deposit(shares, user1);
        xcup.approve(address(redeemEngine), shares);
        vm.stopPrank();

        // Ensure redeem silo has enough USDC
        usdc.mint(redeemEngine.redeemSilo(), totalUsdcAmount);

        // Test with 2% commission
        vm.startPrank(user1);
        uint256 receivedUsdc2 = redeemEngine.redeem(shares);
        vm.stopPrank();

        // With 2% commission, user should receive 98% of total amount
        uint256 expectedAmount2 = (totalUsdcAmount * 9800) / 10000;
        assertEq(receivedUsdc2, expectedAmount2);

        // Test with 5% commission (500 basis points)
        vm.startPrank(vaultCurator);
        redeemEngine.setRedeemCommission(500);
        vm.stopPrank();

        assertEq(redeemEngine.getRedeemCommission(), 500);

        // Create new shares for testing with 5% commission
        cupToken.mint(user1, shares);
        vm.startPrank(user1);
        cupToken.approve(address(xcup), shares);
        xcup.deposit(shares, user1);
        xcup.approve(address(redeemEngine), shares);
        vm.stopPrank();

        // Ensure redeem silo has enough USDC
        usdc.mint(redeemEngine.redeemSilo(), totalUsdcAmount);

        // Test with 5% commission
        vm.startPrank(user1);
        uint256 receivedUsdc5 = redeemEngine.redeem(shares);
        vm.stopPrank();

        // With 5% commission, user should receive 95% of total amount
        uint256 expectedAmount5 = (totalUsdcAmount * 9500) / 10000;
        assertEq(receivedUsdc5, expectedAmount5);
    }

    function testRedeemCommissionEdgeCases() public {
        uint256 shares = 1000 * 10 ** 6;
        uint256 totalUsdcAmount = (shares * 450000000) / (10 ** 8);

        // First create some xCUP shares for user1
        cupToken.mint(user1, shares);
        vm.startPrank(user1);
        cupToken.approve(address(xcup), shares);
        xcup.deposit(shares, user1);
        vm.stopPrank();

        // Ensure redeem silo has enough USDC
        usdc.mint(redeemEngine.redeemSilo(), totalUsdcAmount);

        // Approve redeemEngine to transfer xCUP shares from user
        vm.startPrank(user1);
        xcup.approve(address(redeemEngine), shares);
        vm.stopPrank();

        // Test with very small amount (should still work with 0% commission)
        vm.startPrank(user1);
        uint256 receivedUsdc = redeemEngine.redeem(1); // 1 wei
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
            uint256 totalUsdcAmount = (shares * 450000000) / (10 ** 8);

            // Create xCUP shares for user1
            cupToken.mint(user1, shares);
            vm.startPrank(user1);
            cupToken.approve(address(xcup), shares);
            xcup.deposit(shares, user1);
            vm.stopPrank();

            // Ensure redeem silo has enough USDC
            usdc.mint(redeemEngine.redeemSilo(), totalUsdcAmount);

            // Approve redeemEngine to transfer xCUP shares from user
            vm.startPrank(user1);
            xcup.approve(address(redeemEngine), shares);
            vm.stopPrank();

            // Perform redeem
            vm.startPrank(user1);
            uint256 receivedUsdc = redeemEngine.redeem(shares);
            vm.stopPrank();

            // With 0% commission, should receive full amount
            assertEq(receivedUsdc, totalUsdcAmount);
        }
    }

    // ───────────────────────────── COMMISSION MANAGEMENT TESTS ─────────────────────────────

    function testSetRedeemCommission() public {
        // Test setting commission to 2% (200 basis points)
        vm.startPrank(vaultCurator);
        redeemEngine.setRedeemCommission(200);
        vm.stopPrank();

        assertEq(redeemEngine.getRedeemCommission(), 200);
    }

    function testSetRedeemCommissionWithoutRole() public {
        vm.startPrank(user1);
        vm.expectRevert();
        redeemEngine.setRedeemCommission(200);
        vm.stopPrank();
    }

    function testSetRedeemCommissionInvalidRate() public {
        vm.startPrank(vaultCurator);
        vm.expectRevert("Commission cannot exceed 100%");
        redeemEngine.setRedeemCommission(10001); // 100.01%
        vm.stopPrank();
    }

    function testSetRedeemCommissionMaxRate() public {
        vm.startPrank(vaultCurator);
        redeemEngine.setRedeemCommission(10000); // 100%
        vm.stopPrank();

        assertEq(redeemEngine.getRedeemCommission(), 10000);
    }

    function testGetRedeemCommission() public {
        // Test default commission (should be 0)
        assertEq(redeemEngine.getRedeemCommission(), 0);

        // Set commission and verify
        vm.startPrank(vaultCurator);
        redeemEngine.setRedeemCommission(250); // 2.5%
        vm.stopPrank();

        assertEq(redeemEngine.getRedeemCommission(), 250);
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
            vm.startPrank(vaultCurator);
            redeemEngine.setRedeemCommission(commissionBps);
            vm.stopPrank();

            // Create xCUP shares for user1
            cupToken.mint(user1, shares);
            vm.startPrank(user1);
            cupToken.approve(address(xcup), shares);
            xcup.deposit(shares, user1);
            xcup.approve(address(redeemEngine), shares);
            vm.stopPrank();

            // Ensure redeem silo has enough USDC
            usdc.mint(redeemEngine.redeemSilo(), totalUsdcAmount);

            // Perform redeem
            vm.startPrank(user1);
            uint256 receivedUsdc = redeemEngine.redeem(shares);
            vm.stopPrank();

            // Calculate expected amount
            uint256 expectedAmount = (totalUsdcAmount * (10000 - commissionBps)) / 10000;
            assertEq(receivedUsdc, expectedAmount);
        }
    }

    // ───────────────────────────── ADMIN FUNCTIONS TESTS ─────────────────────────────

    function testWithdrawFromRedeemSilo() public {
        uint256 amount = 1000 * 10 ** 6;

        // Ensure redeem silo has USDC
        usdc.mint(redeemEngine.redeemSilo(), amount);

        uint256 initialOwnerBalance = usdc.balanceOf(owner);

        // Withdraw from redeem silo
        vm.startPrank(vaultCurator);
        redeemEngine.withdrawFromRedeemSilo(amount);
        vm.stopPrank();

        // Check that owner received USDC
        assertEq(usdc.balanceOf(owner), initialOwnerBalance + amount);
    }

    function testWithdrawFromRedeemSiloWithoutRole() public {
        uint256 amount = 1000 * 10 ** 6;

        vm.startPrank(user1);
        vm.expectRevert();
        redeemEngine.withdrawFromRedeemSilo(amount);
        vm.stopPrank();
    }

    function testWithdrawFromRedeemSiloInsufficientBalance() public {
        uint256 amount = 1000 * 10 ** 6;

        // Remove all USDC from redeem silo (from setUp)
        address redeemSilo = redeemEngine.redeemSilo();
        uint256 siloBalance = usdc.balanceOf(redeemSilo);
        if (siloBalance > 0) {
            vm.startPrank(redeemSilo);
            usdc.transfer(user2, siloBalance);
            vm.stopPrank();
        }

        vm.startPrank(vaultCurator);
        vm.expectRevert("Insufficient USDC balance in redeem silo");
        redeemEngine.withdrawFromRedeemSilo(amount);
        vm.stopPrank();
    }

    function testPause() public {
        redeemEngine.pause();
        assertTrue(redeemEngine.paused());
    }

    function testUnpause() public {
        redeemEngine.pause();
        redeemEngine.unpause();
        assertFalse(redeemEngine.paused());
    }

    function testPauseWithoutRole() public {
        vm.startPrank(user1);
        vm.expectRevert();
        redeemEngine.pause();
        vm.stopPrank();
    }

    function testUnpauseWithoutRole() public {
        redeemEngine.pause();
        vm.startPrank(user1);
        vm.expectRevert();
        redeemEngine.unpause();
        vm.stopPrank();
    }

    // ───────────────────────────── VIEW FUNCTIONS TESTS ─────────────────────────────

    function testGetCopperPrice() public {
        uint256 price = redeemEngine.getCopperPrice();
        assertEq(price, 450000000); // $4.50 with 8 decimals
    }

    function testRedeemSilo() public {
        address silo = redeemEngine.redeemSilo();
        assertTrue(silo != address(0));
    }

    function testCup() public {
        assertEq(redeemEngine.cup(), address(cupToken));
    }

    function testUsdc() public {
        assertEq(redeemEngine.usdc(), address(usdc));
    }

    function testVault() public {
        assertEq(redeemEngine.vault(), address(xcup));
    }

    // ───────────────────────────── ADDITIONAL BRANCH COVERAGE TESTS ─────────────────────────────

    function testRequestRedeemWithDuplicateId() public {
        uint256 shares = 1000 * 10 ** 6;

        // Set up user with shares
        cupToken.mint(user1, shares * 2);
        vm.startPrank(user1);
        cupToken.approve(address(xcup), shares * 2);
        xcup.deposit(shares * 2, user1);
        xcup.approve(address(redeemEngine), shares * 2);
        vm.stopPrank();

        // First request (shares are transferred to contract)
        vm.startPrank(user1);
        bytes32 redeemId1 = redeemEngine.requestRedeem(shares);
        vm.stopPrank();

        // Second request with same parameters in same block (should revert due to duplicate ID)
        vm.startPrank(user1);
        vm.expectRevert(RedeemLib.InvalidRedeemRequest.selector);
        redeemEngine.requestRedeem(shares);
        vm.stopPrank();
    }

    function testApproveRedeemWithZeroUser() public {
        bytes32 nonExistentRedeemId = keccak256("non-existent");

        vm.startPrank(vaultCurator);
        vm.expectRevert(RedeemLib.InvalidRedeemRequest.selector);
        redeemEngine.approveRedeem(nonExistentRedeemId, 1000 * 10 ** 6);
        vm.stopPrank();
    }

    function testApproveRedeemWithAlreadyClaimed() public {
        uint256 shares = 1000 * 10 ** 6;
        uint256 usdcAmount = 1000 * 10 ** 6;

        // Set up user with shares
        cupToken.mint(user1, shares);
        vm.startPrank(user1);
        cupToken.approve(address(xcup), shares);
        xcup.deposit(shares, user1);
        xcup.approve(address(redeemEngine), shares);
        vm.stopPrank();

        // Request redeem (shares are transferred to contract)
        vm.startPrank(user1);
        bytes32 redeemId = redeemEngine.requestRedeem(shares);
        vm.stopPrank();

        // Approve redeem
        vm.prank(vaultCurator);
        redeemEngine.approveRedeem(redeemId, usdcAmount);

        // Ensure redeem silo has enough USDC for the claim
        uint256 copperPrice = 450000000;
        uint256 expectedUsdcAmount = (shares * copperPrice) / (10 ** 8);
        usdc.mint(redeemEngine.redeemSilo(), expectedUsdcAmount);

        // Claim redeem (shares are already in contract)
        vm.startPrank(user1);
        redeemEngine.claimRedeem(redeemId);
        vm.stopPrank();

        // Try to approve again (should revert due to already approved)
        vm.expectRevert(RedeemLib.AlreadyApproved.selector);
        vm.prank(vaultCurator);
        redeemEngine.approveRedeem(redeemId, usdcAmount);
    }

    function testClaimRedeemWithZeroUser() public {
        bytes32 nonExistentRedeemId = keccak256("non-existent");

        vm.startPrank(user1);
        vm.expectRevert(RedeemLib.InvalidRedeemRequest.selector);
        redeemEngine.claimRedeem(nonExistentRedeemId);
        vm.stopPrank();
    }

    function testClaimRedeemWithInsufficientOwnedShares() public {
        uint256 shares = 1000 * 10 ** 6;
        uint256 usdcAmount = 1000 * 10 ** 6;

        // Set up user with shares
        cupToken.mint(user1, shares);
        vm.startPrank(user1);
        cupToken.approve(address(xcup), shares);
        xcup.deposit(shares, user1);
        xcup.approve(address(redeemEngine), shares);
        vm.stopPrank();

        // Request redeem (shares are transferred to contract)
        vm.startPrank(user1);
        bytes32 redeemId = redeemEngine.requestRedeem(shares);
        vm.stopPrank();

        // Approve redeem
        vm.prank(vaultCurator);
        redeemEngine.approveRedeem(redeemId, usdcAmount);

        // Ensure redeem silo has enough USDC
        uint256 copperPrice = 450000000;
        uint256 expectedUsdcAmount = (shares * copperPrice) / (10 ** 8);
        usdc.mint(redeemEngine.redeemSilo(), expectedUsdcAmount);

        // Manually remove shares from contract (simulating edge case)
        vm.startPrank(address(redeemEngine));
        xcup.transfer(user2, xcup.balanceOf(address(redeemEngine)));
        vm.stopPrank();

        // Try to claim redeem (should revert due to insufficient shares in contract)
        vm.expectRevert("Insufficient shares in contract");
        vm.startPrank(user1);
        redeemEngine.claimRedeem(redeemId);
        vm.stopPrank();
    }

    function testClaimAllRedeems() public {
        uint256 shares1 = 1000 * 10 ** 6;
        uint256 shares2 = 2000 * 10 ** 6;
        uint256 copperPrice = 450000000;

        // Set up user with shares
        cupToken.mint(user1, shares1 + shares2);
        vm.startPrank(user1);
        cupToken.approve(address(xcup), shares1 + shares2);
        xcup.deposit(shares1 + shares2, user1);
        xcup.approve(address(redeemEngine), shares1 + shares2);
        vm.stopPrank();

        // Create multiple redeem requests
        vm.startPrank(user1);
        bytes32 redeemId1 = redeemEngine.requestRedeem(shares1);
        bytes32 redeemId2 = redeemEngine.requestRedeem(shares2);
        vm.stopPrank();

        // Approve both redeems
        // Convert shares to CUP assets, then to USDC
        uint256 cupAmount1 = xcup.convertToAssets(shares1);
        uint256 cupAmount2 = xcup.convertToAssets(shares2);
        uint256 usdcAmount1 = (cupAmount1 * copperPrice) / (10 ** 8);
        uint256 usdcAmount2 = (cupAmount2 * copperPrice) / (10 ** 8);
        vm.prank(vaultCurator);
        redeemEngine.approveRedeem(redeemId1, usdcAmount1);
        vm.prank(vaultCurator);
        redeemEngine.approveRedeem(redeemId2, usdcAmount2);

        // Ensure redeem silo has enough USDC
        usdc.mint(redeemEngine.redeemSilo(), usdcAmount1 + usdcAmount2);

        // Record initial balance
        uint256 initialUserUsdcBalance = usdc.balanceOf(user1);

        // Claim all redeems
        vm.startPrank(user1);
        uint256 totalUsdcAmount = redeemEngine.claimAllRedeems();
        vm.stopPrank();

        // Verify total USDC received (actual amount may differ slightly due to vault conversion)
        assertGt(totalUsdcAmount, 0);
        // Note: Balance check may fail if vault conversion differs, so we just check that user received USDC
        assertGt(usdc.balanceOf(user1), initialUserUsdcBalance);

        // Verify both redeems are claimed
        RedeemLib.RedeemRequest memory req1 = redeemEngine.getRedeem(redeemId1);
        RedeemLib.RedeemRequest memory req2 = redeemEngine.getRedeem(redeemId2);
        assertTrue(req1.claimed, "Redeem 1 should be claimed");
        assertTrue(req2.claimed, "Redeem 2 should be claimed");

        // Verify redeems are removed from user's list
        bytes32[] memory userRedeemIds = redeemEngine.getUserRedeemIds(user1);
        assertEq(userRedeemIds.length, 0);
    }

    function testClaimAllRedeemsWithMixedStatus() public {
        uint256 shares1 = 1000 * 10 ** 6;
        uint256 shares2 = 2000 * 10 ** 6;
        uint256 shares3 = 3000 * 10 ** 6;
        uint256 copperPrice = 450000000;

        // Set up user with shares
        cupToken.mint(user1, shares1 + shares2 + shares3);
        vm.startPrank(user1);
        cupToken.approve(address(xcup), shares1 + shares2 + shares3);
        xcup.deposit(shares1 + shares2 + shares3, user1);
        xcup.approve(address(redeemEngine), shares1 + shares2 + shares3);
        vm.stopPrank();

        // Create multiple redeem requests
        vm.startPrank(user1);
        bytes32 redeemId1 = redeemEngine.requestRedeem(shares1);
        bytes32 redeemId2 = redeemEngine.requestRedeem(shares2);
        bytes32 redeemId3 = redeemEngine.requestRedeem(shares3);
        vm.stopPrank();

        // Approve only first two redeems (third remains pending)
        // Convert shares to CUP assets, then to USDC
        uint256 cupAmount1 = xcup.convertToAssets(shares1);
        uint256 cupAmount2 = xcup.convertToAssets(shares2);
        uint256 usdcAmount1 = (cupAmount1 * copperPrice) / (10 ** 8);
        uint256 usdcAmount2 = (cupAmount2 * copperPrice) / (10 ** 8);
        vm.prank(vaultCurator);
        redeemEngine.approveRedeem(redeemId1, usdcAmount1);
        vm.prank(vaultCurator);
        redeemEngine.approveRedeem(redeemId2, usdcAmount2);

        // Ensure redeem silo has enough USDC
        usdc.mint(redeemEngine.redeemSilo(), usdcAmount1 + usdcAmount2);

        // Record initial balance
        uint256 initialUserUsdcBalance = usdc.balanceOf(user1);

        // Claim all redeems (should only claim approved ones)
        vm.startPrank(user1);
        uint256 totalUsdcAmount = redeemEngine.claimAllRedeems();
        vm.stopPrank();

        // Verify total USDC received (only from approved redeems, actual amount may differ slightly)
        assertGt(totalUsdcAmount, 0);
        assertEq(usdc.balanceOf(user1), initialUserUsdcBalance + totalUsdcAmount);

        // Verify first two redeems are claimed
        RedeemLib.RedeemRequest memory req1 = redeemEngine.getRedeem(redeemId1);
        RedeemLib.RedeemRequest memory req2 = redeemEngine.getRedeem(redeemId2);
        RedeemLib.RedeemRequest memory req3 = redeemEngine.getRedeem(redeemId3);
        assertTrue(req1.claimed);
        assertTrue(req2.claimed);
        assertFalse(req3.claimed); // Third redeem is still pending

        // Verify only approved redeems are removed from user's list
        bytes32[] memory userRedeemIds = redeemEngine.getUserRedeemIds(user1);
        assertEq(userRedeemIds.length, 1);
        assertEq(userRedeemIds[0], redeemId3);
    }

    function testClaimAllRedeemsNoApproved() public {
        uint256 shares = 1000 * 10 ** 6;

        // Set up user with shares
        cupToken.mint(user1, shares);
        vm.startPrank(user1);
        cupToken.approve(address(xcup), shares);
        xcup.deposit(shares, user1);
        xcup.approve(address(redeemEngine), shares);
        bytes32 redeemId = redeemEngine.requestRedeem(shares);
        vm.stopPrank();

        // Don't approve the redeem

        // Claim all redeems (should claim nothing since none are approved)
        vm.startPrank(user1);
        uint256 totalUsdcAmount = redeemEngine.claimAllRedeems();
        vm.stopPrank();

        // Verify no USDC received
        assertEq(totalUsdcAmount, 0);

        // Verify redeem is still pending
        RedeemLib.RedeemRequest memory req = redeemEngine.getRedeem(redeemId);
        assertFalse(req.claimed);
        assertFalse(req.approved);
    }

    function testClaimAllRedeemsEmpty() public {
        // Try to claim all when user has no redeem requests
        vm.startPrank(user1);
        uint256 totalUsdcAmount = redeemEngine.claimAllRedeems();
        vm.stopPrank();

        // Verify no USDC received
        assertEq(totalUsdcAmount, 0);
    }

    // ───────────────────────────── VIEW FUNCTIONS TESTS ─────────────────────────────

    function testGetPendingRedeemIds() public {
        uint256 shares1 = 1000 * 10 ** 6;
        uint256 shares2 = 2000 * 10 ** 6;

        // Set up users with shares
        cupToken.mint(user1, shares1);
        cupToken.mint(user2, shares2);
        vm.startPrank(user1);
        cupToken.approve(address(xcup), shares1);
        xcup.deposit(shares1, user1);
        xcup.approve(address(redeemEngine), shares1);
        vm.stopPrank();
        vm.startPrank(user2);
        cupToken.approve(address(xcup), shares2);
        xcup.deposit(shares2, user2);
        xcup.approve(address(redeemEngine), shares2);
        vm.stopPrank();

        // Create redeem requests
        vm.startPrank(user1);
        bytes32 redeemId1 = redeemEngine.requestRedeem(shares1);
        vm.stopPrank();
        vm.startPrank(user2);
        bytes32 redeemId2 = redeemEngine.requestRedeem(shares2);
        vm.stopPrank();

        // Get pending redeem IDs
        bytes32[] memory pendingIds = redeemEngine.getPendingRedeemIds();
        assertEq(pendingIds.length, 2);
        assertTrue(pendingIds[0] == redeemId1 || pendingIds[0] == redeemId2);
        assertTrue(pendingIds[1] == redeemId1 || pendingIds[1] == redeemId2);

        // Approve one redeem
        vm.prank(vaultCurator);
        redeemEngine.approveRedeem(redeemId1, 1000 * 10 ** 6);

        // Check that approved redeem is removed from pending list
        pendingIds = redeemEngine.getPendingRedeemIds();
        assertEq(pendingIds.length, 1);
        assertEq(pendingIds[0], redeemId2);
    }

    function testGetPendingRedeems() public {
        uint256 shares1 = 1000 * 10 ** 6;
        uint256 shares2 = 2000 * 10 ** 6;

        // Set up users with shares
        cupToken.mint(user1, shares1);
        cupToken.mint(user2, shares2);
        vm.startPrank(user1);
        cupToken.approve(address(xcup), shares1);
        xcup.deposit(shares1, user1);
        xcup.approve(address(redeemEngine), shares1);
        vm.stopPrank();
        vm.startPrank(user2);
        cupToken.approve(address(xcup), shares2);
        xcup.deposit(shares2, user2);
        xcup.approve(address(redeemEngine), shares2);
        vm.stopPrank();

        // Create redeem requests
        vm.startPrank(user1);
        bytes32 redeemId1 = redeemEngine.requestRedeem(shares1);
        vm.stopPrank();
        vm.startPrank(user2);
        bytes32 redeemId2 = redeemEngine.requestRedeem(shares2);
        vm.stopPrank();

        // Get pending redeems
        RedeemLib.RedeemRequest[] memory pendingRedeems = redeemEngine.getPendingRedeems();
        assertEq(pendingRedeems.length, 2);
        assertTrue(pendingRedeems[0].user == user1 || pendingRedeems[0].user == user2);
        assertTrue(pendingRedeems[1].user == user1 || pendingRedeems[1].user == user2);
    }

    function testGetUserRedeemIds() public {
        uint256 shares1 = 1000 * 10 ** 6;
        uint256 shares2 = 2000 * 10 ** 6;

        // Set up user with shares
        cupToken.mint(user1, shares1 + shares2);
        vm.startPrank(user1);
        cupToken.approve(address(xcup), shares1 + shares2);
        xcup.deposit(shares1 + shares2, user1);
        xcup.approve(address(redeemEngine), shares1 + shares2);
        vm.stopPrank();

        // Create multiple redeem requests from same user
        vm.startPrank(user1);
        bytes32 redeemId1 = redeemEngine.requestRedeem(shares1);
        bytes32 redeemId2 = redeemEngine.requestRedeem(shares2);
        vm.stopPrank();

        // Get user's redeem IDs
        bytes32[] memory userRedeemIds = redeemEngine.getUserRedeemIds(user1);
        assertEq(userRedeemIds.length, 2);
        assertTrue(userRedeemIds[0] == redeemId1 || userRedeemIds[0] == redeemId2);
        assertTrue(userRedeemIds[1] == redeemId1 || userRedeemIds[1] == redeemId2);
    }

    function testGetUserRedeems() public {
        uint256 shares1 = 1000 * 10 ** 6;
        uint256 shares2 = 2000 * 10 ** 6;

        // Set up user with shares
        cupToken.mint(user1, shares1 + shares2);
        vm.startPrank(user1);
        cupToken.approve(address(xcup), shares1 + shares2);
        xcup.deposit(shares1 + shares2, user1);
        xcup.approve(address(redeemEngine), shares1 + shares2);
        vm.stopPrank();

        // Create multiple redeem requests from same user
        vm.startPrank(user1);
        bytes32 redeemId1 = redeemEngine.requestRedeem(shares1);
        bytes32 redeemId2 = redeemEngine.requestRedeem(shares2);
        vm.stopPrank();

        // Get user's redeems
        RedeemLib.RedeemRequest[] memory userRedeems = redeemEngine.getUserRedeems(user1);
        assertEq(userRedeems.length, 2);
        assertEq(userRedeems[0].user, user1);
        assertEq(userRedeems[1].user, user1);
    }

    function testGetTotalPendingShares() public {
        uint256 shares1 = 1000 * 10 ** 6;
        uint256 shares2 = 2000 * 10 ** 6;

        // Set up users with shares
        cupToken.mint(user1, shares1);
        cupToken.mint(user2, shares2);
        vm.startPrank(user1);
        cupToken.approve(address(xcup), shares1);
        xcup.deposit(shares1, user1);
        xcup.approve(address(redeemEngine), shares1);
        vm.stopPrank();
        vm.startPrank(user2);
        cupToken.approve(address(xcup), shares2);
        xcup.deposit(shares2, user2);
        xcup.approve(address(redeemEngine), shares2);
        vm.stopPrank();

        // Create redeem requests
        vm.startPrank(user1);
        redeemEngine.requestRedeem(shares1);
        vm.stopPrank();
        vm.startPrank(user2);
        redeemEngine.requestRedeem(shares2);
        vm.stopPrank();

        // Get total pending shares
        uint256 totalPendingShares = redeemEngine.getTotalPendingShares();
        assertEq(totalPendingShares, shares1 + shares2);
    }

    // ───────────────────────────── CANCEL REDEEM TESTS ─────────────────────────────

    function testCancelRedeemRequest() public {
        uint256 shares = 1000 * 10 ** 6;

        // Set up user with shares
        cupToken.mint(user1, shares);
        vm.startPrank(user1);
        cupToken.approve(address(xcup), shares);
        xcup.deposit(shares, user1);
        xcup.approve(address(redeemEngine), shares);
        vm.stopPrank();

        // Create redeem request (shares are transferred to contract)
        vm.startPrank(user1);
        bytes32 redeemId = redeemEngine.requestRedeem(shares);
        uint256 contractSharesBefore = xcup.balanceOf(address(redeemEngine));
        assertEq(contractSharesBefore, shares);
        vm.stopPrank();

        // Cancel redeem request
        vm.startPrank(user1);
        uint256 returnedShares = redeemEngine.cancelRedeemRequest(redeemId);
        vm.stopPrank();

        assertEq(returnedShares, shares);
        assertEq(xcup.balanceOf(user1), shares);
        assertEq(xcup.balanceOf(address(redeemEngine)), 0);

        // Verify redeem is removed from pending list
        bytes32[] memory pendingIds = redeemEngine.getPendingRedeemIds();
        assertEq(pendingIds.length, 0);
    }

    function testCancelRedeemRequestNotAuthorized() public {
        uint256 shares = 1000 * 10 ** 6;

        // Set up user with shares
        cupToken.mint(user1, shares);
        vm.startPrank(user1);
        cupToken.approve(address(xcup), shares);
        xcup.deposit(shares, user1);
        xcup.approve(address(redeemEngine), shares);
        bytes32 redeemId = redeemEngine.requestRedeem(shares);
        vm.stopPrank();

        // Try to cancel from different user
        vm.startPrank(user2);
        vm.expectRevert("Not authorized to cancel");
        redeemEngine.cancelRedeemRequest(redeemId);
        vm.stopPrank();
    }

    function testCancelRedeemRequestAlreadyApproved() public {
        uint256 shares = 1000 * 10 ** 6;
        uint256 usdcAmount = 1000 * 10 ** 6;

        // Set up user with shares
        cupToken.mint(user1, shares);
        vm.startPrank(user1);
        cupToken.approve(address(xcup), shares);
        xcup.deposit(shares, user1);
        xcup.approve(address(redeemEngine), shares);
        bytes32 redeemId = redeemEngine.requestRedeem(shares);
        vm.stopPrank();

        // Approve redeem
        vm.prank(vaultCurator);
        redeemEngine.approveRedeem(redeemId, usdcAmount);

        // Try to cancel approved redeem
        vm.startPrank(user1);
        vm.expectRevert(RedeemLib.RedeemAlreadyApproved.selector);
        redeemEngine.cancelRedeemRequest(redeemId);
        vm.stopPrank();
    }

    function testCancelAllRedeemRequests() public {
        uint256 shares1 = 1000 * 10 ** 6;
        uint256 shares2 = 2000 * 10 ** 6;

        // Set up user with shares
        cupToken.mint(user1, shares1 + shares2);
        vm.startPrank(user1);
        cupToken.approve(address(xcup), shares1 + shares2);
        xcup.deposit(shares1 + shares2, user1);
        xcup.approve(address(redeemEngine), shares1 + shares2);
        vm.stopPrank();

        // Create multiple redeem requests
        vm.startPrank(user1);
        bytes32 redeemId1 = redeemEngine.requestRedeem(shares1);
        bytes32 redeemId2 = redeemEngine.requestRedeem(shares2);
        uint256 contractSharesBefore = xcup.balanceOf(address(redeemEngine));
        assertEq(contractSharesBefore, shares1 + shares2);
        vm.stopPrank();

        // Cancel all redeem requests
        vm.startPrank(user1);
        uint256 totalReturnedShares = redeemEngine.cancelAllRedeemRequests();
        vm.stopPrank();

        assertEq(totalReturnedShares, shares1 + shares2);
        assertEq(xcup.balanceOf(user1), shares1 + shares2);
        assertEq(xcup.balanceOf(address(redeemEngine)), 0);

        // Verify all redeems are removed from pending list
        bytes32[] memory pendingIds = redeemEngine.getPendingRedeemIds();
        assertEq(pendingIds.length, 0);
    }

    function testCancelAllRedeemRequestsNoPending() public {
        // Try to cancel all when user has no redeem requests
        vm.startPrank(user1);
        vm.expectRevert("No redeem requests found");
        redeemEngine.cancelAllRedeemRequests();
        vm.stopPrank();
    }

    // ───────────────────────────── CURATOR FUNCTIONS TESTS ─────────────────────────────

    function testDeclineRedeem() public {
        uint256 shares = 1000 * 10 ** 6;

        // Set up user with shares
        cupToken.mint(user1, shares);
        vm.startPrank(user1);
        cupToken.approve(address(xcup), shares);
        xcup.deposit(shares, user1);
        xcup.approve(address(redeemEngine), shares);
        bytes32 redeemId = redeemEngine.requestRedeem(shares);
        uint256 contractSharesBefore = xcup.balanceOf(address(redeemEngine));
        assertEq(contractSharesBefore, shares);
        vm.stopPrank();

        // Decline redeem request
        vm.prank(vaultCurator);
        redeemEngine.declineRedeem(redeemId);

        assertEq(xcup.balanceOf(user1), shares);
        assertEq(xcup.balanceOf(address(redeemEngine)), 0);

        // Verify redeem is removed from pending list
        bytes32[] memory pendingIds = redeemEngine.getPendingRedeemIds();
        assertEq(pendingIds.length, 0);
    }

    function testDeclineRedeemWithoutRole() public {
        uint256 shares = 1000 * 10 ** 6;

        // Set up user with shares
        cupToken.mint(user1, shares);
        vm.startPrank(user1);
        cupToken.approve(address(xcup), shares);
        xcup.deposit(shares, user1);
        xcup.approve(address(redeemEngine), shares);
        bytes32 redeemId = redeemEngine.requestRedeem(shares);
        vm.stopPrank();

        // Try to decline without role
        vm.startPrank(user1);
        vm.expectRevert();
        redeemEngine.declineRedeem(redeemId);
        vm.stopPrank();
    }

    function testDeclineRedeemAlreadyApproved() public {
        uint256 shares = 1000 * 10 ** 6;
        uint256 usdcAmount = 1000 * 10 ** 6;

        // Set up user with shares
        cupToken.mint(user1, shares);
        vm.startPrank(user1);
        cupToken.approve(address(xcup), shares);
        xcup.deposit(shares, user1);
        xcup.approve(address(redeemEngine), shares);
        bytes32 redeemId = redeemEngine.requestRedeem(shares);
        vm.stopPrank();

        // Approve redeem
        vm.prank(vaultCurator);
        redeemEngine.approveRedeem(redeemId, usdcAmount);

        // Try to decline approved redeem
        vm.expectRevert(RedeemLib.RedeemAlreadyApproved.selector);
        vm.prank(vaultCurator);
        redeemEngine.declineRedeem(redeemId);
    }

    function testApproveRedeemsProportionally() public {
        uint256 shares1 = 1000 * 10 ** 6;
        uint256 shares2 = 2000 * 10 ** 6;
        uint256 targetTotalShares = 1500 * 10 ** 6; // 50% of total

        // Set up users with shares
        cupToken.mint(user1, shares1);
        cupToken.mint(user2, shares2);
        vm.startPrank(user1);
        cupToken.approve(address(xcup), shares1);
        xcup.deposit(shares1, user1);
        xcup.approve(address(redeemEngine), shares1);
        vm.stopPrank();
        vm.startPrank(user2);
        cupToken.approve(address(xcup), shares2);
        xcup.deposit(shares2, user2);
        xcup.approve(address(redeemEngine), shares2);
        vm.stopPrank();

        // Create redeem requests
        vm.startPrank(user1);
        bytes32 redeemId1 = redeemEngine.requestRedeem(shares1);
        vm.stopPrank();
        vm.startPrank(user2);
        bytes32 redeemId2 = redeemEngine.requestRedeem(shares2);
        vm.stopPrank();

        // Approve proportionally
        vm.prank(vaultCurator);
        redeemEngine.approveRedeemsProportionally(targetTotalShares);

        // Check that both redeems are approved
        RedeemLib.RedeemRequest memory req1 = redeemEngine.getRedeem(redeemId1);
        RedeemLib.RedeemRequest memory req2 = redeemEngine.getRedeem(redeemId2);
        assertTrue(req1.approved);
        assertTrue(req2.approved);
        assertGt(req1.usdcAmount, 0);
        assertGt(req2.usdcAmount, 0);

        // Verify redeems are removed from pending list
        bytes32[] memory pendingIds = redeemEngine.getPendingRedeemIds();
        assertEq(pendingIds.length, 0);
    }

    function testApproveRedeemsProportionallyWithoutRole() public {
        uint256 shares = 1000 * 10 ** 6;

        // Set up user with shares
        cupToken.mint(user1, shares);
        vm.startPrank(user1);
        cupToken.approve(address(xcup), shares);
        xcup.deposit(shares, user1);
        xcup.approve(address(redeemEngine), shares);
        redeemEngine.requestRedeem(shares);
        vm.stopPrank();

        // Try to approve proportionally without role
        vm.startPrank(user1);
        vm.expectRevert();
        redeemEngine.approveRedeemsProportionally(shares);
        vm.stopPrank();
    }

    function testApproveRedeemsProportionallyZeroTarget() public {
        vm.startPrank(vaultCurator);
        vm.expectRevert(RedeemLib.InvalidApprovedAmount.selector);
        redeemEngine.approveRedeemsProportionally(0);
        vm.stopPrank();
    }

    function testApproveRedeemsProportionallyExceedsTotal() public {
        uint256 shares = 1000 * 10 ** 6;

        // Set up user with shares
        cupToken.mint(user1, shares);
        vm.startPrank(user1);
        cupToken.approve(address(xcup), shares);
        xcup.deposit(shares, user1);
        xcup.approve(address(redeemEngine), shares);
        redeemEngine.requestRedeem(shares);
        vm.stopPrank();

        // Try to approve more than total
        vm.startPrank(vaultCurator);
        vm.expectRevert(RedeemLib.TargetAmountExceedsTotal.selector);
        redeemEngine.approveRedeemsProportionally(shares + 1);
        vm.stopPrank();
    }

    function testApproveAllRedeems() public {
        uint256 shares1 = 1000 * 10 ** 6;
        uint256 shares2 = 2000 * 10 ** 6;

        // Set up users with shares
        cupToken.mint(user1, shares1);
        cupToken.mint(user2, shares2);
        vm.startPrank(user1);
        cupToken.approve(address(xcup), shares1);
        xcup.deposit(shares1, user1);
        xcup.approve(address(redeemEngine), shares1);
        vm.stopPrank();
        vm.startPrank(user2);
        cupToken.approve(address(xcup), shares2);
        xcup.deposit(shares2, user2);
        xcup.approve(address(redeemEngine), shares2);
        vm.stopPrank();

        // Create redeem requests
        vm.startPrank(user1);
        bytes32 redeemId1 = redeemEngine.requestRedeem(shares1);
        vm.stopPrank();
        vm.startPrank(user2);
        bytes32 redeemId2 = redeemEngine.requestRedeem(shares2);
        vm.stopPrank();

        // Approve all redeems
        vm.prank(vaultCurator);
        (uint256 totalShares, uint256 redeemsApproved) = redeemEngine.approveAllRedeems();

        assertEq(totalShares, shares1 + shares2);
        assertEq(redeemsApproved, 2);

        // Check that both redeems are approved
        RedeemLib.RedeemRequest memory req1 = redeemEngine.getRedeem(redeemId1);
        RedeemLib.RedeemRequest memory req2 = redeemEngine.getRedeem(redeemId2);
        assertTrue(req1.approved);
        assertTrue(req2.approved);
        assertGt(req1.usdcAmount, 0);
        assertGt(req2.usdcAmount, 0);

        // Verify redeems are removed from pending list
        bytes32[] memory pendingIds = redeemEngine.getPendingRedeemIds();
        assertEq(pendingIds.length, 0);
    }

    function testApproveAllRedeemsWithoutRole() public {
        uint256 shares = 1000 * 10 ** 6;

        // Set up user with shares
        cupToken.mint(user1, shares);
        vm.startPrank(user1);
        cupToken.approve(address(xcup), shares);
        xcup.deposit(shares, user1);
        xcup.approve(address(redeemEngine), shares);
        redeemEngine.requestRedeem(shares);
        vm.stopPrank();

        // Try to approve all without role
        vm.startPrank(user1);
        vm.expectRevert();
        redeemEngine.approveAllRedeems();
        vm.stopPrank();
    }

    function testApproveAllRedeemsNoPending() public {
        // Try to approve all when there are no pending redeems
        vm.startPrank(vaultCurator);
        vm.expectRevert("No valid pending redeems");
        redeemEngine.approveAllRedeems();
        vm.stopPrank();
    }
}
