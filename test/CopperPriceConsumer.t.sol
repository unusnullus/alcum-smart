// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test, console} from "forge-std/Test.sol";
import {CopperPriceConsumer} from "../contracts/CopperPriceConsumer.sol";

contract CopperPriceConsumerTest is Test {
    CopperPriceConsumer public copperPriceConsumer;
    address public owner;
    address public admin;
    address public user1;

    function setUp() public {
        owner = address(this);
        admin = makeAddr("admin");
        user1 = makeAddr("user1");

        copperPriceConsumer = new CopperPriceConsumer(
            makeAddr("oracle"), bytes32(uint256(uint160(makeAddr("jobId")))), 0.1 ether, makeAddr("link")
        );
    }

    function testInitialization() public {
        assertTrue(copperPriceConsumer.hasRole(copperPriceConsumer.DEFAULT_ADMIN_ROLE(), owner));
    }

    function testRequestCopperPrice() public {
        // This test requires LINK tokens, so we expect it to revert
        vm.expectRevert();
        copperPriceConsumer.requestCopperPrice();
    }

    function testFulfill() public {
        // This test requires a valid request ID, so we expect it to revert
        bytes32 requestId = bytes32(0);
        uint256 price = 450000000; // $4.50 with 8 decimals

        vm.expectRevert();
        copperPriceConsumer.fulfill(requestId, price);
    }

    function testSetOracle() public {
        address newOracle = makeAddr("newOracle");
        copperPriceConsumer.setOracle(newOracle);
        // Can't test directly as it's private, but function should not revert
    }

    function testSetOracleWithoutRole() public {
        vm.prank(admin);
        vm.expectRevert();
        copperPriceConsumer.setOracle(makeAddr("newOracle"));
    }

    function testSetJobId() public {
        bytes32 newJobId = bytes32(uint256(uint160(makeAddr("newJobId"))));
        copperPriceConsumer.setJobId(newJobId);
        // Can't test directly as it's private, but function should not revert
    }

    function testSetJobIdWithoutRole() public {
        vm.prank(admin);
        vm.expectRevert();
        copperPriceConsumer.setJobId(bytes32(uint256(uint160(makeAddr("newJobId")))));
    }

    function testSetFee() public {
        uint256 newFee = 0.2 ether; // Different from initial fee
        copperPriceConsumer.setFee(newFee);
        // Can't test directly as it's private, but function should not revert
    }

    function testSetFeeWithoutRole() public {
        vm.prank(admin);
        vm.expectRevert();
        copperPriceConsumer.setFee(0.1 ether);
    }

    function testUpdatePrice() public {
        uint256 newPrice = 500000000; // $5.00 with 8 decimals
        copperPriceConsumer.updatePrice(newPrice);
        assertEq(copperPriceConsumer.getPriceAsDecimal(), newPrice / 10 ** 8);
    }

    function testUpdatePriceWithoutRole() public {
        vm.prank(user1);
        vm.expectRevert();
        copperPriceConsumer.updatePrice(500000000);
    }

    function testSetOracleInvalidAddress() public {
        vm.expectRevert(CopperPriceConsumer.InvalidOracleAddress.selector);
        copperPriceConsumer.setOracle(address(0));
    }

    function testSetFeeInvalidFee() public {
        vm.expectRevert(CopperPriceConsumer.InvalidFee.selector);
        copperPriceConsumer.setFee(0);
    }

    function testRequestCopperPriceInsufficientLink() public {
        // This should revert due to insufficient LINK
        vm.expectRevert();
        copperPriceConsumer.requestCopperPrice();
    }

    function testFulfillInvalidRequest() public {
        // This should revert due to invalid request ID
        vm.expectRevert();
        copperPriceConsumer.fulfill(bytes32(0), 450000000);
    }

    function testSetOracleWithValidAddress() public {
        address newOracle = makeAddr("newOracle");
        copperPriceConsumer.setOracle(newOracle);
        // Function should not revert
        assertTrue(true);
    }

    function testSetJobIdWithValidJobId() public {
        bytes32 newJobId = bytes32(uint256(uint160(makeAddr("newJobId"))));
        copperPriceConsumer.setJobId(newJobId);
        // Function should not revert
        assertTrue(true);
    }

    function testSetFeeWithValidFee() public {
        uint256 newFee = 0.2 ether;
        copperPriceConsumer.setFee(newFee);
        // Function should not revert
        assertTrue(true);
    }

    function testUpdatePriceWithValidPrice() public {
        uint256 newPrice = 500000000; // $5.00 with 8 decimals
        copperPriceConsumer.updatePrice(newPrice);
        assertEq(copperPriceConsumer.price(), newPrice);
    }

    function testUpdatePriceWithZeroPrice() public {
        uint256 zeroPrice = 0;
        vm.expectRevert(CopperPriceConsumer.InvalidPrice.selector);
        copperPriceConsumer.updatePrice(zeroPrice);
    }

    function testUpdatePriceWithMaxPrice() public {
        uint256 maxPrice = type(uint256).max;
        copperPriceConsumer.updatePrice(maxPrice);
        assertEq(copperPriceConsumer.price(), maxPrice);
    }

    // Test error cases for better branch coverage
    function testSetJobIdWithSameJobId() public {
        bytes32 currentJobId = bytes32(uint256(uint160(makeAddr("jobId"))));
        vm.expectRevert(CopperPriceConsumer.SameJobId.selector);
        copperPriceConsumer.setJobId(currentJobId);
    }

    function testSetFeeWithSameFee() public {
        uint256 currentFee = 0.1 ether;
        vm.expectRevert(CopperPriceConsumer.SameFee.selector);
        copperPriceConsumer.setFee(currentFee);
    }

    function testSetOracleWithSameOracle() public {
        address currentOracle = makeAddr("oracle");
        vm.expectRevert(CopperPriceConsumer.SameOracle.selector);
        copperPriceConsumer.setOracle(currentOracle);
    }

    // Test constructor error cases for better branch coverage
    function testConstructorWithZeroOracle() public {
        vm.expectRevert(CopperPriceConsumer.InvalidOracleAddress.selector);
        new CopperPriceConsumer(address(0), bytes32(uint256(uint160(makeAddr("jobId")))), 0.1 ether, makeAddr("link"));
    }

    function testConstructorWithZeroLink() public {
        vm.expectRevert(CopperPriceConsumer.InvalidLinkAddress.selector);
        new CopperPriceConsumer(makeAddr("oracle"), bytes32(uint256(uint160(makeAddr("jobId")))), 0.1 ether, address(0));
    }

    function testConstructorWithZeroFee() public {
        vm.expectRevert(CopperPriceConsumer.InvalidFee.selector);
        new CopperPriceConsumer(makeAddr("oracle"), bytes32(uint256(uint160(makeAddr("jobId")))), 0, makeAddr("link"));
    }
}
