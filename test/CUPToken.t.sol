// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test, console} from "forge-std/Test.sol";
import {CUPToken} from "../contracts/CUPToken.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

contract CUPTokenTest is Test {
    CUPToken public cupToken;
    address public owner;
    address public minter;
    address public burner;
    address public user;

    function setUp() public {
        owner = address(this);
        minter = makeAddr("minter");
        burner = makeAddr("burner");
        user = makeAddr("user");

        // Deploy implementation
        CUPToken implementation = new CUPToken();

        // Deploy proxy
        bytes memory initData = abi.encodeWithSelector(CUPToken.initialize.selector);
        ERC1967Proxy proxy = new ERC1967Proxy(address(implementation), initData);

        cupToken = CUPToken(address(proxy));
    }

    function testInitialization() public {
        assertEq(cupToken.name(), "CUP");
        assertEq(cupToken.symbol(), "CUP");
        assertEq(cupToken.decimals(), 6);
        assertTrue(cupToken.hasRole(cupToken.DEFAULT_ADMIN_ROLE(), owner));
    }

    function testMint() public {
        uint256 amount = 1000 * 10 ** 6;

        cupToken.grantRole(cupToken.MINTER_ROLE(), minter);

        vm.prank(minter);
        cupToken.mint(user, amount);

        assertEq(cupToken.balanceOf(user), amount);
        assertEq(cupToken.totalSupply(), amount);
    }

    function testMintWithoutRole() public {
        uint256 amount = 1000 * 10 ** 6;

        vm.prank(user);
        vm.expectRevert();
        cupToken.mint(user, amount);
    }

    function testBurn() public {
        uint256 amount = 1000 * 10 ** 6;

        // First mint some tokens
        cupToken.grantRole(cupToken.MINTER_ROLE(), minter);
        vm.prank(minter);
        cupToken.mint(user, amount);

        // Grant burner role
        cupToken.grantRole(cupToken.BURNER_ROLE(), burner);

        // Burn tokens
        vm.prank(burner);
        cupToken.burn(user, amount);

        assertEq(cupToken.balanceOf(user), 0);
        assertEq(cupToken.totalSupply(), 0);
    }

    function testBurnInsufficientBalance() public {
        uint256 amount = 1000 * 10 ** 6;

        cupToken.grantRole(cupToken.BURNER_ROLE(), burner);

        vm.prank(burner);
        vm.expectRevert();
        cupToken.burn(user, amount);
    }

    function testBurnWithoutRole() public {
        uint256 amount = 1000 * 10 ** 6;

        // First mint some tokens
        cupToken.grantRole(cupToken.MINTER_ROLE(), minter);
        vm.prank(minter);
        cupToken.mint(user, amount);

        vm.prank(user);
        vm.expectRevert();
        cupToken.burn(user, amount);
    }

    function testGrantRole() public {
        cupToken.grantRole(cupToken.MINTER_ROLE(), minter);
        assertTrue(cupToken.hasRole(cupToken.MINTER_ROLE(), minter));
    }

    function testRevokeRole() public {
        cupToken.grantRole(cupToken.MINTER_ROLE(), minter);
        cupToken.revokeRole(cupToken.MINTER_ROLE(), minter);
        assertFalse(cupToken.hasRole(cupToken.MINTER_ROLE(), minter));
    }

    function testTransfer() public {
        uint256 amount = 1000 * 10 ** 6;

        // Mint tokens to user
        cupToken.grantRole(cupToken.MINTER_ROLE(), minter);
        vm.prank(minter);
        cupToken.mint(user, amount);

        // Transfer tokens
        vm.prank(user);
        cupToken.transfer(owner, amount);

        assertEq(cupToken.balanceOf(owner), amount);
        assertEq(cupToken.balanceOf(user), 0);
    }

    function testApprove() public {
        uint256 amount = 1000 * 10 ** 6;

        // Mint tokens to user
        cupToken.grantRole(cupToken.MINTER_ROLE(), minter);
        vm.prank(minter);
        cupToken.mint(user, amount);

        // Approve tokens
        vm.prank(user);
        cupToken.approve(owner, amount);

        assertEq(cupToken.allowance(user, owner), amount);
    }

    function testTransferFrom() public {
        uint256 amount = 1000 * 10 ** 6;

        // Mint tokens to user
        cupToken.grantRole(cupToken.MINTER_ROLE(), minter);
        vm.prank(minter);
        cupToken.mint(user, amount);

        // Approve and transfer
        vm.prank(user);
        cupToken.approve(owner, amount);

        cupToken.transferFrom(user, owner, amount);

        assertEq(cupToken.balanceOf(owner), amount);
        assertEq(cupToken.balanceOf(user), 0);
    }

    function testApproveWithZeroAmount() public {
        vm.prank(user);
        cupToken.approve(owner, 0);

        assertEq(cupToken.allowance(user, owner), 0);
    }

    function testApproveWithMaxAmount() public {
        vm.prank(user);
        cupToken.approve(owner, type(uint256).max);

        assertEq(cupToken.allowance(user, owner), type(uint256).max);
    }

    function testGrantRoleWithValidRole() public {
        bytes32 role = keccak256("TEST_ROLE");
        cupToken.grantRole(role, user);
        assertTrue(cupToken.hasRole(role, user));
    }

    function testRevokeRoleWithValidRole() public {
        bytes32 role = keccak256("TEST_ROLE");
        cupToken.grantRole(role, user);
        cupToken.revokeRole(role, user);
        assertFalse(cupToken.hasRole(role, user));
    }

    // Test error cases for better branch coverage
    function testMintToZeroAddress() public {
        uint256 amount = 1000 * 10 ** 6;

        cupToken.grantRole(cupToken.MINTER_ROLE(), minter);

        vm.prank(minter);
        vm.expectRevert(CUPToken.MintToZeroAddress.selector);
        cupToken.mint(address(0), amount);
    }

    function testMintWithZeroAmount() public {
        cupToken.grantRole(cupToken.MINTER_ROLE(), minter);

        vm.prank(minter);
        vm.expectRevert(CUPToken.InvalidMintAmount.selector);
        cupToken.mint(user, 0);
    }

    function testBurnFromZeroAddress() public {
        uint256 amount = 1000 * 10 ** 6;

        cupToken.grantRole(cupToken.BURNER_ROLE(), burner);

        vm.prank(burner);
        vm.expectRevert(CUPToken.BurnFromZeroAddress.selector);
        cupToken.burn(address(0), amount);
    }

    function testBurnWithZeroAmount() public {
        uint256 amount = 1000 * 10 ** 6;

        // First mint some tokens
        cupToken.grantRole(cupToken.MINTER_ROLE(), minter);
        vm.prank(minter);
        cupToken.mint(user, amount);

        // Grant burner role
        cupToken.grantRole(cupToken.BURNER_ROLE(), burner);

        // Try to burn zero amount
        vm.prank(burner);
        vm.expectRevert(CUPToken.InvalidBurnAmount.selector);
        cupToken.burn(user, 0);
    }
}
