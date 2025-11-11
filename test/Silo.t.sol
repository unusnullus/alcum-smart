// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test, console} from "forge-std/Test.sol";
import {Silo} from "../contracts/Silo.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

// Mock ERC20 token
contract MockERC20 is ERC20 {
    constructor(string memory name, string memory symbol) ERC20(name, symbol) {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract SiloTest is Test {
    Silo public silo;
    MockERC20 public token;
    address public zapper;

    function setUp() public {
        token = new MockERC20("TestToken", "TEST");
        zapper = makeAddr("zapper");

        // Deploy Silo as zapper (msg.sender will be zapper)
        vm.prank(zapper);
        silo = new Silo(token);
    }

    function test_Constructor() public {
        // Check that Silo was deployed
        assertTrue(address(silo) != address(0));
    }

    function test_ApprovalSet() public {
        // Check that unlimited approval was set for zapper
        uint256 allowance = token.allowance(address(silo), zapper);
        assertEq(allowance, type(uint256).max);
    }

    function test_ApprovalSetForDifferentZapper() public {
        address differentZapper = makeAddr("differentZapper");

        // Deploy new Silo with different zapper
        vm.prank(differentZapper);
        Silo newSilo = new Silo(token);

        // Check that approval is set for the correct zapper
        assertEq(token.allowance(address(newSilo), differentZapper), type(uint256).max);
        // Original zapper should not have approval from new silo
        assertEq(token.allowance(address(newSilo), zapper), 0);
    }

    function test_SiloCanHoldTokens() public {
        uint256 amount = 1000 * 10 ** 6;
        token.mint(address(silo), amount);

        assertEq(token.balanceOf(address(silo)), amount);
    }

    function test_ZapperCanSpendFromSilo() public {
        uint256 amount = 1000 * 10 ** 6;
        token.mint(address(silo), amount);

        // Zapper should be able to transfer tokens from Silo
        vm.prank(zapper);
        token.transferFrom(address(silo), zapper, amount);

        assertEq(token.balanceOf(zapper), amount);
        assertEq(token.balanceOf(address(silo)), 0);
    }

    function test_NonZapperCannotSpendFromSilo() public {
        uint256 amount = 1000 * 10 ** 6;
        address attacker = makeAddr("attacker");
        token.mint(address(silo), amount);

        // Attacker should not be able to transfer tokens from Silo
        vm.prank(attacker);
        vm.expectRevert();
        token.transferFrom(address(silo), attacker, amount);
    }
}
