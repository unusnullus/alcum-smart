// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test, console} from "forge-std/Test.sol";
import {RedeemLib} from "../contracts/libraries/RedeemLib.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC4626} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";

// Mock ERC20 token
contract MockERC20 is ERC20 {
    constructor(string memory name, string memory symbol) ERC20(name, symbol) {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

// Mock ERC4626 vault for testing
contract MockVault is ERC4626 {
    ERC20 private _asset;
    uint256 private _totalAssets;

    constructor(ERC20 asset) ERC4626(asset) ERC20("MockVault", "MV") {
        _asset = asset;
    }

    function deposit(uint256 assets, address receiver) public override returns (uint256) {
        _asset.transferFrom(msg.sender, address(this), assets);
        _totalAssets += assets;
        uint256 shares = assets; // 1:1 for simplicity
        _mint(receiver, shares);
        return shares;
    }

    function mint(uint256 shares, address receiver) public override returns (uint256) {
        uint256 assets = shares; // 1:1 for simplicity
        _asset.transferFrom(msg.sender, address(this), assets);
        _totalAssets += assets;
        _mint(receiver, shares);
        return assets;
    }

    function withdraw(uint256 assets, address receiver, address owner) public override returns (uint256) {
        uint256 shares = assets; // 1:1 for simplicity
        if (msg.sender != owner) {
            _spendAllowance(owner, msg.sender, shares);
        }
        _burn(owner, shares);
        _totalAssets -= assets;
        _asset.transfer(receiver, assets);
        return shares;
    }

    function redeem(uint256 shares, address receiver, address owner) public override returns (uint256) {
        uint256 assets = shares; // 1:1 for simplicity
        if (msg.sender != owner) {
            _spendAllowance(owner, msg.sender, shares);
        }
        _burn(owner, shares);
        _totalAssets -= assets;
        _asset.transfer(receiver, assets);
        return assets;
    }

    function totalAssets() public view override returns (uint256) {
        return _totalAssets;
    }

    function convertToShares(uint256 assets) public view override returns (uint256) {
        return assets; // 1:1 for simplicity
    }

    function convertToAssets(uint256 shares) public view override returns (uint256) {
        return shares; // 1:1 for simplicity
    }
}

// Mock price consumer
contract MockPriceConsumer {
    uint256 private _price;

    constructor(uint256 price_) {
        _price = price_;
    }

    function price() external view returns (uint256) {
        return _price;
    }
}

// Mock invalid price consumer (returns invalid data)
contract MockInvalidPriceConsumer {
    function price() external pure returns (uint256) {
        revert("Price oracle call failed");
    }
}

// Mock Silo
contract MockSilo {
    MockERC20 public token;
    mapping(address => uint256) public balanceOf;

    constructor(MockERC20 _token) {
        token = _token;
        // Auto-approve msg.sender (test contract) for unlimited spending
        token.approve(msg.sender, type(uint256).max);
    }

    function fund(uint256 amount) external {
        token.transferFrom(msg.sender, address(this), amount);
        balanceOf[address(this)] += amount;
    }

    // Allow testContract to spend from silo
    function approveSpender(address spender) external {
        token.approve(spender, type(uint256).max);
    }
}

// Test contract that uses RedeemLib
contract TestRedeemContract {
    using RedeemLib for mapping(bytes32 => RedeemLib.RedeemRequest);

    mapping(bytes32 => RedeemLib.RedeemRequest) public redeems;
    bytes32[] public pendingRedeemIds;
    mapping(address => bytes32[]) public userRedeems;

    function requestRedeem(bytes32 redeemId, address user, uint256 shares) external {
        RedeemLib.requestRedeem(redeems, pendingRedeemIds, userRedeems, redeemId, user, shares);
    }

    function approveRedeem(bytes32 redeemId, uint256 usdcAmount) external {
        RedeemLib.approveRedeem(redeems, redeemId, usdcAmount);
    }

    function claimRedeem(
        bytes32 redeemId,
        address user,
        IERC4626 vault,
        IERC20 usdc,
        address silo,
        address zapper,
        address copperPriceConsumer
    ) external returns (uint256) {
        return
            RedeemLib.claimRedeem(redeems, redeemId, user, vault, usdc, silo, zapper, copperPriceConsumer, userRedeems);
    }

    function getRedeem(bytes32 redeemId) external view returns (RedeemLib.RedeemRequest memory) {
        return RedeemLib.getRedeem(redeems, redeemId);
    }
}

contract RedeemLibTest is Test {
    TestRedeemContract public testContract;
    MockERC20 public cupToken;
    MockERC20 public usdcToken;
    MockVault public vault;
    MockPriceConsumer public priceConsumer;
    MockSilo public silo;
    address public zapper; // Mock Zapper address (where CUP tokens are sent)
    address public user1;
    address public user2;

    function setUp() public {
        testContract = new TestRedeemContract();
        cupToken = new MockERC20("CUP", "CUP");
        usdcToken = new MockERC20("USDC", "USDC");
        vault = new MockVault(cupToken);
        priceConsumer = new MockPriceConsumer(450000000); // $4.50 with 8 decimals
        silo = new MockSilo(usdcToken);
        zapper = makeAddr("zapper"); // Mock Zapper address

        user1 = makeAddr("user1");
        user2 = makeAddr("user2");

        // Mint tokens
        cupToken.mint(user1, 10000 * 10 ** 6);
        usdcToken.mint(address(this), 100000 * 10 ** 6);

        // Fund silo - approve and transfer
        usdcToken.approve(address(silo), 100000 * 10 ** 6);
        usdcToken.transfer(address(silo), 100000 * 10 ** 6);

        // Allow testContract to spend from silo
        silo.approveSpender(address(testContract));

        // User deposits to vault
        vm.startPrank(user1);
        cupToken.approve(address(vault), 10000 * 10 ** 6);
        vault.deposit(10000 * 10 ** 6, user1);
        vm.stopPrank();
    }

    // ───────────────────────────── REQUEST REDEEM TESTS ─────────────────────────────

    function testRequestRedeem() public {
        uint256 shares = 1000 * 10 ** 6;
        bytes32 redeemId = keccak256(abi.encodePacked(user1, block.timestamp, shares));
        testContract.requestRedeem(redeemId, user1, shares);

        RedeemLib.RedeemRequest memory req = testContract.getRedeem(redeemId);
        assertEq(req.user, user1);
        assertEq(req.shares, shares);
        assertEq(req.usdcAmount, 0);
        assertFalse(req.approved);
        assertFalse(req.claimed);
    }

    function testRequestRedeemInvalidUser() public {
        uint256 shares = 1000 * 10 ** 6;
        bytes32 redeemId = keccak256(abi.encodePacked(address(0), block.timestamp, shares));
        vm.expectRevert(RedeemLib.InvalidRedeemRequest.selector);
        testContract.requestRedeem(redeemId, address(0), shares);
    }

    function testRequestRedeemInvalidAmount() public {
        uint256 zeroShares = 0;
        bytes32 redeemId = keccak256(abi.encodePacked(user1, block.timestamp, zeroShares));
        vm.expectRevert(RedeemLib.InvalidAmount.selector);
        testContract.requestRedeem(redeemId, user1, 0);
    }

    function testRequestRedeemCollision() public {
        // Create two requests with same redeemId (should fail on second)
        uint256 shares = 1000 * 10 ** 6;
        bytes32 redeemId = keccak256(abi.encodePacked(user1, block.timestamp, shares));
        testContract.requestRedeem(redeemId, user1, shares);

        // Second request with same redeemId should fail due to collision
        vm.expectRevert(RedeemLib.RedeemIdAlreadyExists.selector);
        testContract.requestRedeem(redeemId, user1, shares);
    }

    // ───────────────────────────── APPROVE REDEEM TESTS ─────────────────────────────

    function testApproveRedeem() public {
        uint256 shares = 1000 * 10 ** 6;
        bytes32 redeemId = keccak256(abi.encodePacked(user1, block.timestamp, shares));
        testContract.requestRedeem(redeemId, user1, shares);
        uint256 usdcAmount = 4500 * 10 ** 6;

        testContract.approveRedeem(redeemId, usdcAmount);

        RedeemLib.RedeemRequest memory req = testContract.getRedeem(redeemId);
        assertTrue(req.approved);
        assertEq(req.usdcAmount, usdcAmount);
    }

    function testApproveRedeemInvalidRequest() public {
        bytes32 fakeId = keccak256("fake");
        vm.expectRevert(RedeemLib.InvalidRedeemRequest.selector);
        testContract.approveRedeem(fakeId, 1000 * 10 ** 6);
    }

    function testApproveRedeemAlreadyApproved() public {
        uint256 shares = 1000 * 10 ** 6;
        bytes32 redeemId = keccak256(abi.encodePacked(user1, block.timestamp, shares));
        testContract.requestRedeem(redeemId, user1, shares);
        uint256 usdcAmount = 4500 * 10 ** 6;

        testContract.approveRedeem(redeemId, usdcAmount);
        vm.expectRevert(RedeemLib.AlreadyApproved.selector);
        testContract.approveRedeem(redeemId, usdcAmount);
    }

    function testApproveRedeemAlreadyClaimed() public {
        uint256 shares = 1000 * 10 ** 6;
        bytes32 redeemId = keccak256(abi.encodePacked(user1, block.timestamp, shares));
        testContract.requestRedeem(redeemId, user1, shares);
        uint256 usdcAmount = 4500 * 10 ** 6;

        testContract.approveRedeem(redeemId, usdcAmount);

        // Transfer xCUP shares to testContract (simulating requestRedeem behavior)
        vm.startPrank(user1);
        vault.approve(address(testContract), shares);
        vault.transfer(address(testContract), shares);
        testContract.claimRedeem(redeemId, user1, vault, usdcToken, address(silo), zapper, address(priceConsumer));
        vm.stopPrank();

        // After claiming, trying to approve again should fail with AlreadyApproved
        // (because approved is checked before claimed in the code)
        vm.expectRevert(RedeemLib.AlreadyApproved.selector);
        testContract.approveRedeem(redeemId, usdcAmount);
    }

    // ───────────────────────────── CLAIM REDEEM TESTS ─────────────────────────────

    function testClaimRedeem() public {
        uint256 shares = 1000 * 10 ** 6;
        bytes32 redeemId = keccak256(abi.encodePacked(user1, block.timestamp, shares));
        testContract.requestRedeem(redeemId, user1, shares);
        uint256 usdcAmount = 4500 * 10 ** 6;

        testContract.approveRedeem(redeemId, usdcAmount);

        // Transfer xCUP shares to testContract (simulating requestRedeem behavior)
        vm.startPrank(user1);
        vault.approve(address(testContract), shares);
        vault.transfer(address(testContract), shares);

        uint256 usdcBefore = usdcToken.balanceOf(user1);
        uint256 usdcReceived = testContract.claimRedeem(
            redeemId,
            user1,
            vault,
            usdcToken,
            address(silo),
            zapper,
            address(priceConsumer)
        );
        uint256 usdcAfter = usdcToken.balanceOf(user1);

        assertEq(usdcAfter - usdcBefore, usdcReceived);
        assertTrue(usdcReceived > 0);

        RedeemLib.RedeemRequest memory req = testContract.getRedeem(redeemId);
        assertTrue(req.claimed);
        vm.stopPrank();
    }

    function testClaimRedeemInvalidRequest() public {
        bytes32 fakeId = keccak256("fake");
        vm.expectRevert(RedeemLib.InvalidRedeemRequest.selector);
        testContract.claimRedeem(fakeId, user1, vault, usdcToken, address(silo), zapper, address(priceConsumer));
    }

    function testClaimRedeemNotApproved() public {
        uint256 shares = 1000 * 10 ** 6;
        bytes32 redeemId = keccak256(abi.encodePacked(user1, block.timestamp, shares));
        testContract.requestRedeem(redeemId, user1, shares);

        // Transfer xCUP shares to testContract (simulating requestRedeem behavior)
        vm.startPrank(user1);
        vault.approve(address(testContract), shares);
        vault.transfer(address(testContract), shares);
        vm.expectRevert(RedeemLib.NotApproved.selector);
        testContract.claimRedeem(redeemId, user1, vault, usdcToken, address(silo), zapper, address(priceConsumer));
        vm.stopPrank();
    }

    function testClaimRedeemNotUser() public {
        uint256 shares = 1000 * 10 ** 6;
        bytes32 redeemId = keccak256(abi.encodePacked(user1, block.timestamp, shares));
        testContract.requestRedeem(redeemId, user1, shares);
        uint256 usdcAmount = 4500 * 10 ** 6;

        testContract.approveRedeem(redeemId, usdcAmount);

        // Transfer xCUP shares to testContract (simulating requestRedeem behavior)
        vm.startPrank(user1);
        vault.approve(address(testContract), shares);
        vault.transfer(address(testContract), shares);
        vm.stopPrank();

        vm.startPrank(user2);
        vm.expectRevert(RedeemLib.NotUser.selector);
        testContract.claimRedeem(redeemId, user2, vault, usdcToken, address(silo), zapper, address(priceConsumer));
        vm.stopPrank();
    }

    function testClaimRedeemAlreadyClaimed() public {
        uint256 shares = 1000 * 10 ** 6;
        bytes32 redeemId = keccak256(abi.encodePacked(user1, block.timestamp, shares));
        testContract.requestRedeem(redeemId, user1, shares);
        uint256 usdcAmount = 4500 * 10 ** 6;

        testContract.approveRedeem(redeemId, usdcAmount);

        // Transfer xCUP shares to testContract (simulating requestRedeem behavior)
        vm.startPrank(user1);
        vault.approve(address(testContract), shares);
        vault.transfer(address(testContract), shares);
        testContract.claimRedeem(redeemId, user1, vault, usdcToken, address(silo), zapper, address(priceConsumer));

        vm.expectRevert(RedeemLib.AlreadyClaimed.selector);
        testContract.claimRedeem(redeemId, user1, vault, usdcToken, address(silo), zapper, address(priceConsumer));
        vm.stopPrank();
    }

    function testClaimRedeemInsufficientBalance() public {
        uint256 shares = 20000 * 10 ** 6; // More than user has (user has 10000)
        bytes32 redeemId = keccak256(abi.encodePacked(user1, block.timestamp, shares));
        testContract.requestRedeem(redeemId, user1, shares);
        uint256 usdcAmount = 90000 * 10 ** 6;

        testContract.approveRedeem(redeemId, usdcAmount);

        // Transfer only part of shares (less than requested) to testContract
        vm.startPrank(user1);
        vault.approve(address(testContract), 10000 * 10 ** 6);
        vault.transfer(address(testContract), 10000 * 10 ** 6);
        // Should revert with InsufficientBalance because contract doesn't have enough shares
        vm.expectRevert(RedeemLib.InsufficientBalance.selector);
        testContract.claimRedeem(redeemId, user1, vault, usdcToken, address(silo), zapper, address(priceConsumer));
        vm.stopPrank();
    }

    function testClaimRedeemInvalidPrice() public {
        // RedeemLib.claimRedeem no longer validates the price oracle at claim time.
        // The USDC amount is locked at approveRedeem time. This test verifies that
        // claimRedeem succeeds even when the oracle price is 0.
        uint256 shares = 1000 * 10 ** 6;
        bytes32 redeemId = keccak256(abi.encodePacked(user1, block.timestamp, shares));
        testContract.requestRedeem(redeemId, user1, shares);
        uint256 usdcAmount = 4500 * 10 ** 6;

        testContract.approveRedeem(redeemId, usdcAmount);

        MockPriceConsumer zeroPriceConsumer = new MockPriceConsumer(0);

        vm.startPrank(user1);
        vault.approve(address(testContract), shares);
        vault.transfer(address(testContract), shares);
        // Should succeed: price oracle is not consulted at claim time
        uint256 received = testContract.claimRedeem(
            redeemId, user1, vault, usdcToken, address(silo), zapper, address(zeroPriceConsumer)
        );
        vm.stopPrank();

        assertEq(received, usdcAmount);
    }

    function testClaimRedeemPriceOracleCallFailed() public {
        // RedeemLib.claimRedeem no longer calls the price oracle at claim time.
        // This test verifies that even an invalid oracle address doesn't break claim.
        uint256 shares = 1000 * 10 ** 6;
        bytes32 redeemId = keccak256(abi.encodePacked(user1, block.timestamp, shares));
        testContract.requestRedeem(redeemId, user1, shares);
        uint256 usdcAmount = 4500 * 10 ** 6;

        testContract.approveRedeem(redeemId, usdcAmount);

        MockInvalidPriceConsumer invalidPriceConsumer = new MockInvalidPriceConsumer();

        vm.startPrank(user1);
        vault.approve(address(testContract), shares);
        vault.transfer(address(testContract), shares);
        // Should succeed: oracle is not called
        uint256 received = testContract.claimRedeem(
            redeemId,
            user1,
            vault,
            usdcToken,
            address(silo),
            zapper,
            address(invalidPriceConsumer)
        );
        vm.stopPrank();

        assertEq(received, usdcAmount);
    }

    // ───────────────────────────── GET REDEEM TESTS ─────────────────────────────

    function testGetRedeem() public {
        uint256 shares = 1000 * 10 ** 6;
        bytes32 redeemId = keccak256(abi.encodePacked(user1, block.timestamp, shares));
        testContract.requestRedeem(redeemId, user1, shares);

        RedeemLib.RedeemRequest memory req = testContract.getRedeem(redeemId);
        assertEq(req.user, user1);
        assertEq(req.shares, shares);
    }

    function testGetRedeemNonExistent() public {
        bytes32 fakeId = keccak256("fake");
        RedeemLib.RedeemRequest memory req = testContract.getRedeem(fakeId);
        assertEq(req.user, address(0));
        assertEq(req.shares, 0);
    }
}
