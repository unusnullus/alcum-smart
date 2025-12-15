// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test, console} from "forge-std/Test.sol";
import {GovernanceToken} from "../contracts/GovernanceToken.sol";

contract GovernanceTokenTest is Test {
    GovernanceToken public token;
    address public admin;
    address public user1;
    address public user2;

    function setUp() public {
        admin = address(this);
        user1 = makeAddr("user1");
        user2 = makeAddr("user2");

        token = new GovernanceToken("Governance Token", "GOV", admin);
    }

    function testInitialization() public {
        assertEq(token.name(), "Governance Token");
        assertEq(token.symbol(), "GOV");
        assertEq(token.decimals(), 18);
        assertTrue(token.hasRole(token.DEFAULT_ADMIN_ROLE(), admin));
        assertTrue(token.hasRole(token.MINTER_ROLE(), admin));
        assertEq(token.totalSupply(), 0);
    }

    function testMint() public {
        uint256 amount = 1000 * 10 ** 18;

        token.mint(user1, amount);

        assertEq(token.balanceOf(user1), amount);
        assertEq(token.totalSupply(), amount);
    }

    function testMintMultiple() public {
        uint256 amount1 = 1000 * 10 ** 18;
        uint256 amount2 = 500 * 10 ** 18;

        token.mint(user1, amount1);
        token.mint(user2, amount2);

        assertEq(token.balanceOf(user1), amount1);
        assertEq(token.balanceOf(user2), amount2);
        assertEq(token.totalSupply(), amount1 + amount2);
    }

    function testMintToZeroAddress() public {
        uint256 amount = 1000 * 10 ** 18;

        vm.expectRevert(GovernanceToken.MintToZeroAddress.selector);
        token.mint(address(0), amount);
    }

    function testMintZeroAmount() public {
        vm.expectRevert(GovernanceToken.InvalidMintAmount.selector);
        token.mint(user1, 0);
    }

    function testMintWithoutRole() public {
        uint256 amount = 1000 * 10 ** 18;

        vm.prank(user1);
        vm.expectRevert();
        token.mint(user1, amount);
    }

    function testGrantMinterRole() public {
        uint256 amount = 1000 * 10 ** 18;

        // Grant MINTER_ROLE to user1
        token.grantRole(token.MINTER_ROLE(), user1);

        // Now user1 can mint
        vm.prank(user1);
        token.mint(user2, amount);

        assertEq(token.balanceOf(user2), amount);
    }

    function testRevokeMinterRole() public {
        uint256 amount = 1000 * 10 ** 18;

        // Grant and then revoke MINTER_ROLE
        token.grantRole(token.MINTER_ROLE(), user1);
        token.revokeRole(token.MINTER_ROLE(), user1);

        // Now user1 cannot mint
        vm.prank(user1);
        vm.expectRevert();
        token.mint(user2, amount);
    }

    function testTransfer() public {
        uint256 amount = 1000 * 10 ** 18;
        token.mint(user1, amount);

        vm.prank(user1);
        token.transfer(user2, amount);

        assertEq(token.balanceOf(user1), 0);
        assertEq(token.balanceOf(user2), amount);
    }

    function testTransferPartial() public {
        uint256 mintAmount = 1000 * 10 ** 18;
        uint256 transferAmount = 300 * 10 ** 18;
        token.mint(user1, mintAmount);

        vm.prank(user1);
        token.transfer(user2, transferAmount);

        assertEq(token.balanceOf(user1), mintAmount - transferAmount);
        assertEq(token.balanceOf(user2), transferAmount);
    }

    function testApprove() public {
        uint256 amount = 1000 * 10 ** 18;
        token.mint(user1, amount);

        vm.prank(user1);
        token.approve(user2, amount);

        assertEq(token.allowance(user1, user2), amount);
    }

    function testTransferFrom() public {
        uint256 amount = 1000 * 10 ** 18;
        token.mint(user1, amount);

        vm.prank(user1);
        token.approve(user2, amount);

        vm.prank(user2);
        token.transferFrom(user1, user2, amount);

        assertEq(token.balanceOf(user1), 0);
        assertEq(token.balanceOf(user2), amount);
        assertEq(token.allowance(user1, user2), 0);
    }

    function testVotingPower() public {
        uint256 amount = 1000 * 10 ** 18;
        token.mint(user1, amount);

        assertEq(token.getVotes(user1), 0); // No votes before delegation
        assertEq(token.getPastVotes(user1, block.number - 1), 0);
    }

    function testDelegation() public {
        uint256 amount = 1000 * 10 ** 18;
        token.mint(user1, amount);

        vm.prank(user1);
        token.delegate(user1);

        assertEq(token.getVotes(user1), amount);
    }

    function testDelegationToOther() public {
        uint256 amount = 1000 * 10 ** 18;
        token.mint(user1, amount);

        vm.prank(user1);
        token.delegate(user2);

        assertEq(token.getVotes(user1), 0);
        assertEq(token.getVotes(user2), amount);
    }

    function testPermit() public {
        uint256 amount = 1000 * 10 ** 18;
        token.mint(user1, amount);

        uint256 nonce = token.nonces(user1);
        uint256 deadline = block.timestamp + 1 days;

        // Use a test private key
        uint256 privateKey = 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80;
        address signer = vm.addr(privateKey);

        // Mint tokens to signer for permit
        token.mint(signer, amount);

        bytes32 structHash = keccak256(
            abi.encode(
                keccak256("Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)"),
                signer,
                user2,
                amount,
                token.nonces(signer),
                deadline
            )
        );

        bytes32 hash = keccak256(abi.encodePacked("\x19\x01", token.DOMAIN_SEPARATOR(), structHash));

        (uint8 v, bytes32 r, bytes32 s) = vm.sign(privateKey, hash);

        token.permit(signer, user2, amount, deadline, v, r, s);

        assertEq(token.allowance(signer, user2), amount);
    }

    function testNonces() public {
        assertEq(token.nonces(user1), 0);

        uint256 amount = 1000 * 10 ** 18;
        token.mint(user1, amount);

        // Nonce should increment after permit
        uint256 nonce1 = token.nonces(user1);
        assertEq(nonce1, 0); // Initial nonce is 0
    }

    function testTokensMintedEvent() public {
        uint256 amount = 1000 * 10 ** 18;

        vm.expectEmit(true, false, false, true);
        emit GovernanceToken.TokensMinted(user1, amount);

        token.mint(user1, amount);
    }

    function testUpdateVotingPower() public {
        uint256 amount1 = 1000 * 10 ** 18;
        uint256 amount2 = 500 * 10 ** 18;

        token.mint(user1, amount1);
        vm.prank(user1);
        token.delegate(user1);

        assertEq(token.getVotes(user1), amount1);

        // Mint more tokens
        token.mint(user1, amount2);
        assertEq(token.getVotes(user1), amount1 + amount2);
    }

    function testPastVotes() public {
        uint256 amount = 1000 * 10 ** 18;
        token.mint(user1, amount);

        vm.prank(user1);
        token.delegate(user1);

        vm.roll(block.number + 1);
        uint256 pastBlock = block.number - 1;

        assertEq(token.getPastVotes(user1, pastBlock), amount);
    }

    function testCheckpoints() public {
        uint256 amount = 1000 * 10 ** 18;
        token.mint(user1, amount);

        vm.prank(user1);
        token.delegate(user1);

        uint256 checkpoint1 = block.number;
        vm.roll(block.number + 1);

        token.mint(user1, amount);
        vm.roll(block.number + 1);
        uint256 checkpoint2 = block.number - 1;

        assertEq(token.getPastVotes(user1, checkpoint1), amount);
        assertEq(token.getPastVotes(user1, checkpoint2), amount * 2);
    }
}
