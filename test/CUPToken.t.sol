// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";

import {Upgrades} from "openzeppelin-foundry-upgrades/Upgrades.sol";

import {CUPToken} from "../contracts/CUPToken.sol";
import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";

contract CUPTokenTest is Test {
    CUPToken public cupToken;

    address public owner;
    address public minter;
    address public burner;
    address public user1;
    address public user2;
    address public unauthorized;

    event Transfer(address indexed from, address indexed to, uint256 value);
    event RoleGranted(bytes32 indexed role, address indexed account, address indexed sender);
    event RoleRevoked(bytes32 indexed role, address indexed account, address indexed sender);

    function setUp() public {
        owner = address(this);
        minter = makeAddr("minter");
        burner = makeAddr("burner");
        user1 = makeAddr("user1");
        user2 = makeAddr("user2");
        unauthorized = makeAddr("unauthorized");

        // Deploy CUPToken using upgradeable pattern
        address cupTokenProxy = Upgrades.deployTransparentProxy(
            "CUPToken.sol:CUPToken",
            owner,
            abi.encodeCall(CUPToken.initialize, ())
        );
        cupToken = CUPToken(cupTokenProxy);
    }

    function testInitialState() public {
        assertEq(cupToken.name(), "CUP");
        assertEq(cupToken.symbol(), "CUP");
        assertEq(cupToken.decimals(), 6);
        assertEq(cupToken.totalSupply(), 0);

        // Check that deployer has DEFAULT_ADMIN_ROLE
        assertTrue(cupToken.hasRole(cupToken.DEFAULT_ADMIN_ROLE(), owner));
    }

    function testGrantMinterRole() public {
        // Grant MINTER_ROLE to minter address
        cupToken.grantRole(cupToken.MINTER_ROLE(), minter);

        assertTrue(cupToken.hasRole(cupToken.MINTER_ROLE(), minter));
    }

    function testGrantBurnerRole() public {
        // Grant BURNER_ROLE to burner address
        cupToken.grantRole(cupToken.BURNER_ROLE(), burner);

        assertTrue(cupToken.hasRole(cupToken.BURNER_ROLE(), burner));
    }

    function testMintWithMinterRole() public {
        // Grant MINTER_ROLE to minter
        cupToken.grantRole(cupToken.MINTER_ROLE(), minter);

        uint256 mintAmount = 1000e6; // 1000 CUP tokens

        vm.expectEmit(true, true, false, true);
        emit Transfer(address(0), user1, mintAmount);

        vm.prank(minter);
        cupToken.mint(user1, mintAmount);

        assertEq(cupToken.balanceOf(user1), mintAmount);
        assertEq(cupToken.totalSupply(), mintAmount);
    }

    function testMintRevertWithoutMinterRole() public {
        uint256 mintAmount = 1000e6;

        vm.prank(unauthorized);
        vm.expectRevert();
        cupToken.mint(user1, mintAmount);

        assertEq(cupToken.balanceOf(user1), 0);
        assertEq(cupToken.totalSupply(), 0);
    }

    function testBurnWithBurnerRole() public {
        // Setup: mint tokens first
        cupToken.grantRole(cupToken.MINTER_ROLE(), minter);
        cupToken.grantRole(cupToken.BURNER_ROLE(), burner);

        uint256 mintAmount = 1000e6;
        vm.prank(minter);
        cupToken.mint(user1, mintAmount);

        uint256 burnAmount = 500e6;

        vm.expectEmit(true, true, false, true);
        emit Transfer(user1, address(0), burnAmount);

        vm.prank(burner);
        cupToken.burn(user1, burnAmount);

        assertEq(cupToken.balanceOf(user1), mintAmount - burnAmount);
        assertEq(cupToken.totalSupply(), mintAmount - burnAmount);
    }

    function testBurnRevertWithoutBurnerRole() public {
        // Setup: mint tokens first
        cupToken.grantRole(cupToken.MINTER_ROLE(), minter);

        uint256 mintAmount = 1000e6;
        vm.prank(minter);
        cupToken.mint(user1, mintAmount);

        uint256 burnAmount = 500e6;

        vm.prank(unauthorized);
        vm.expectRevert();
        cupToken.burn(user1, burnAmount);

        assertEq(cupToken.balanceOf(user1), mintAmount);
        assertEq(cupToken.totalSupply(), mintAmount);
    }

    function testBurnRevertInsufficientBalance() public {
        cupToken.grantRole(cupToken.BURNER_ROLE(), burner);

        uint256 burnAmount = 500e6;

        vm.prank(burner);
        vm.expectRevert();
        cupToken.burn(user1, burnAmount);
    }

    function testRevokeRole() public {
        // Grant role first
        cupToken.grantRole(cupToken.MINTER_ROLE(), minter);
        assertTrue(cupToken.hasRole(cupToken.MINTER_ROLE(), minter));

        // Revoke role
        vm.expectEmit(true, true, true, false);
        emit RoleRevoked(cupToken.MINTER_ROLE(), minter, owner);

        cupToken.revokeRole(cupToken.MINTER_ROLE(), minter);
        assertFalse(cupToken.hasRole(cupToken.MINTER_ROLE(), minter));

        // Should not be able to mint anymore
        vm.prank(minter);
        vm.expectRevert();
        cupToken.mint(user1, 1000e6);
    }

    function testRenounceRole() public {
        // Grant role first
        cupToken.grantRole(cupToken.MINTER_ROLE(), minter);
        assertTrue(cupToken.hasRole(cupToken.MINTER_ROLE(), minter));

        // Renounce role
        vm.prank(minter);
        cupToken.renounceRole(cupToken.MINTER_ROLE(), minter);

        assertFalse(cupToken.hasRole(cupToken.MINTER_ROLE(), minter));
    }

    function testOnlyAdminCanGrantRoles() public {
        vm.prank(unauthorized);
        vm.expectRevert();
        cupToken.grantRole(cupToken.MINTER_ROLE(), minter);
    }

    function testOnlyAdminCanRevokeRoles() public {
        // Grant role first
        cupToken.grantRole(cupToken.MINTER_ROLE(), minter);

        vm.prank(unauthorized);
        vm.expectRevert();
        cupToken.revokeRole(cupToken.MINTER_ROLE(), minter);
    }

    function testTransferFunctionality() public {
        // Setup: mint tokens to user1
        cupToken.grantRole(cupToken.MINTER_ROLE(), minter);

        uint256 mintAmount = 1000e6;
        vm.prank(minter);
        cupToken.mint(user1, mintAmount);

        uint256 transferAmount = 300e6;

        vm.expectEmit(true, true, false, true);
        emit Transfer(user1, user2, transferAmount);

        vm.prank(user1);
        cupToken.transfer(user2, transferAmount);

        assertEq(cupToken.balanceOf(user1), mintAmount - transferAmount);
        assertEq(cupToken.balanceOf(user2), transferAmount);
    }

    function testApproveAndTransferFrom() public {
        // Setup: mint tokens to user1
        cupToken.grantRole(cupToken.MINTER_ROLE(), minter);

        uint256 mintAmount = 1000e6;
        vm.prank(minter);
        cupToken.mint(user1, mintAmount);

        uint256 approveAmount = 500e6;
        uint256 transferAmount = 300e6;

        // Approve user2 to spend user1's tokens
        vm.prank(user1);
        cupToken.approve(user2, approveAmount);

        assertEq(cupToken.allowance(user1, user2), approveAmount);

        // Transfer from user1 to user2 via user2
        vm.expectEmit(true, true, false, true);
        emit Transfer(user1, user2, transferAmount);

        vm.prank(user2);
        cupToken.transferFrom(user1, user2, transferAmount);

        assertEq(cupToken.balanceOf(user1), mintAmount - transferAmount);
        assertEq(cupToken.balanceOf(user2), transferAmount);
        assertEq(cupToken.allowance(user1, user2), approveAmount - transferAmount);
    }

    function testMintLargeAmount() public {
        cupToken.grantRole(cupToken.MINTER_ROLE(), minter);

        uint256 largeAmount = type(uint256).max / 2; // Very large amount

        vm.prank(minter);
        cupToken.mint(user1, largeAmount);

        assertEq(cupToken.balanceOf(user1), largeAmount);
        assertEq(cupToken.totalSupply(), largeAmount);
    }

    function testBurnAllTokens() public {
        cupToken.grantRole(cupToken.MINTER_ROLE(), minter);
        cupToken.grantRole(cupToken.BURNER_ROLE(), burner);

        uint256 mintAmount = 1000e6;
        vm.prank(minter);
        cupToken.mint(user1, mintAmount);

        vm.prank(burner);
        cupToken.burn(user1, mintAmount);

        assertEq(cupToken.balanceOf(user1), 0);
        assertEq(cupToken.totalSupply(), 0);
    }

    function testMultipleRoleHolders() public {
        address minter2 = makeAddr("minter2");
        address burner2 = makeAddr("burner2");

        // Grant roles to multiple addresses
        cupToken.grantRole(cupToken.MINTER_ROLE(), minter);
        cupToken.grantRole(cupToken.MINTER_ROLE(), minter2);
        cupToken.grantRole(cupToken.BURNER_ROLE(), burner);
        cupToken.grantRole(cupToken.BURNER_ROLE(), burner2);

        uint256 mintAmount = 500e6;

        // Both minters should be able to mint
        vm.prank(minter);
        cupToken.mint(user1, mintAmount);

        vm.prank(minter2);
        cupToken.mint(user2, mintAmount);

        assertEq(cupToken.balanceOf(user1), mintAmount);
        assertEq(cupToken.balanceOf(user2), mintAmount);
        assertEq(cupToken.totalSupply(), mintAmount * 2);

        // Both burners should be able to burn
        vm.prank(burner);
        cupToken.burn(user1, mintAmount / 2);

        vm.prank(burner2);
        cupToken.burn(user2, mintAmount / 2);

        assertEq(cupToken.balanceOf(user1), mintAmount / 2);
        assertEq(cupToken.balanceOf(user2), mintAmount / 2);
        assertEq(cupToken.totalSupply(), mintAmount);
    }

    function testRoleConstants() public {
        // Test that role constants are correctly defined
        bytes32 expectedMinterRole = keccak256("MINTER_ROLE");
        bytes32 expectedBurnerRole = keccak256("BURNER_ROLE");

        assertEq(cupToken.MINTER_ROLE(), expectedMinterRole);
        assertEq(cupToken.BURNER_ROLE(), expectedBurnerRole);
    }

    function testSupportsInterface() public {
        // Test ERC165 interface support
        assertTrue(cupToken.supportsInterface(type(AccessControlUpgradeable).interfaceId));
    }

    function testZeroAddressMint() public {
        cupToken.grantRole(cupToken.MINTER_ROLE(), minter);

        vm.prank(minter);
        vm.expectRevert();
        cupToken.mint(address(0), 1000e6);
    }

    function testZeroAddressBurn() public {
        cupToken.grantRole(cupToken.BURNER_ROLE(), burner);

        vm.prank(burner);
        vm.expectRevert();
        cupToken.burn(address(0), 1000e6);
    }

    function testMintZeroAmount() public {
        cupToken.grantRole(cupToken.MINTER_ROLE(), minter);

        vm.prank(minter);
        cupToken.mint(user1, 0);

        assertEq(cupToken.balanceOf(user1), 0);
        assertEq(cupToken.totalSupply(), 0);
    }

    function testBurnZeroAmount() public {
        cupToken.grantRole(cupToken.BURNER_ROLE(), burner);

        vm.prank(burner);
        cupToken.burn(user1, 0);

        assertEq(cupToken.balanceOf(user1), 0);
        assertEq(cupToken.totalSupply(), 0);
    }
}
