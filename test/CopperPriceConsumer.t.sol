// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";

import {Upgrades} from "openzeppelin-foundry-upgrades/Upgrades.sol";

import {CopperPriceConsumer} from "../contracts/CopperPriceConsumer.sol";
import {CopperPriceConsumerMock} from "../contracts/mock/CopperPriceConsumerMock.sol";
import {ERC20Mock} from "../contracts/mock/ERC20Mock.sol";

// Mock Chainlink Oracle
contract MockChainlinkOracle {
    mapping(bytes32 => uint256) public responses;

    function setResponse(bytes32 requestId, uint256 response) external {
        responses[requestId] = response;
    }

    function fulfillRequest(address consumer, bytes32 requestId) external {
        uint256 response = responses[requestId];
        CopperPriceConsumer(consumer).fulfill(requestId, response);
    }
}

contract CopperPriceConsumerTest is Test {
    CopperPriceConsumer public priceConsumer;
    CopperPriceConsumerMock public mockPriceConsumer;
    MockChainlinkOracle public mockOracle;
    ERC20Mock public linkToken;

    address public owner;
    address public user1;
    address public unauthorized;

    // Mock oracle parameters
    bytes32 constant JOB_ID = 0x1234567890123456789012345678901234567890123456789012345678901234;
    uint256 constant FEE = 0.1e18; // 0.1 LINK
    uint256 constant INITIAL_PRICE = 450000000; // $4.50 with 8 decimals

    function setUp() public {
        owner = address(this);
        user1 = makeAddr("user1");
        unauthorized = makeAddr("unauthorized");

        // Deploy mock LINK token
        linkToken = new ERC20Mock("LINK", "LINK", 18);

        // Deploy mock oracle
        mockOracle = new MockChainlinkOracle();

        // Deploy CopperPriceConsumer using upgradeable pattern
        address priceConsumerProxy = Upgrades.deployTransparentProxy(
            "CopperPriceConsumer.sol:CopperPriceConsumer",
            owner,
            abi.encodeCall(CopperPriceConsumer.initialize, (address(mockOracle), JOB_ID, FEE, address(linkToken)))
        );
        priceConsumer = CopperPriceConsumer(priceConsumerProxy);

        // Deploy mock price consumer for testing
        mockPriceConsumer = new CopperPriceConsumerMock();

        // Setup LINK tokens
        linkToken.mint(address(priceConsumer), 10e18); // 10 LINK
        linkToken.mint(owner, 10e18);
    }

    function testInitialState() public {
        assertEq(priceConsumer.price(), 0);
        assertEq(priceConsumer.owner(), owner);
    }

    function testMockPriceConsumer() public {
        // Test mock price consumer
        assertEq(mockPriceConsumer.price(), 0);

        // Set price
        mockPriceConsumer.setPrice(INITIAL_PRICE);
        assertEq(mockPriceConsumer.price(), INITIAL_PRICE);

        // Test getPriceAsDecimal
        uint256 expectedDecimalPrice = INITIAL_PRICE / (10 ** 8);
        assertEq(mockPriceConsumer.getPriceAsDecimal(), expectedDecimalPrice);
    }

    function testSetJobId() public {
        bytes32 newJobId = 0x9876543210987654321098765432109876543210987654321098765432109876;

        priceConsumer.setJobId(newJobId);
        // Note: jobId is private, so we can't directly test it
        // But we can test that only owner can call it
    }

    function testSetJobIdRevertNotOwner() public {
        bytes32 newJobId = 0x9876543210987654321098765432109876543210987654321098765432109876;

        vm.prank(unauthorized);
        vm.expectRevert();
        priceConsumer.setJobId(newJobId);
    }

    function testSetFee() public {
        uint256 newFee = 0.2e18; // 0.2 LINK

        priceConsumer.setFee(newFee);
        // Note: fee is private, so we can't directly test it
        // But we can test that only owner can call it
    }

    function testSetFeeRevertNotOwner() public {
        uint256 newFee = 0.2e18;

        vm.prank(unauthorized);
        vm.expectRevert();
        priceConsumer.setFee(newFee);
    }

    function testRequestCopperPrice() public {
        // This test simulates the Chainlink request flow
        bytes32 requestId = priceConsumer.requestCopperPrice();

        // Verify that a request was made (requestId should not be zero)
        assertTrue(requestId != bytes32(0));
    }

    function testFulfillPrice() public {
        // Set up a mock response
        bytes32 requestId = keccak256(abi.encodePacked("test_request"));
        uint256 newPrice = 500000000; // $5.00 with 8 decimals

        mockOracle.setResponse(requestId, newPrice);

        // Simulate oracle fulfillment
        vm.prank(address(mockOracle));
        priceConsumer.fulfill(requestId, newPrice);

        assertEq(priceConsumer.price(), newPrice);
    }

    function testGetPriceAsDecimal() public {
        // Set price first
        uint256 testPrice = 450000000; // $4.50 with 8 decimals
        bytes32 requestId = keccak256(abi.encodePacked("test_request"));

        mockOracle.setResponse(requestId, testPrice);
        vm.prank(address(mockOracle));
        priceConsumer.fulfill(requestId, testPrice);

        // Test decimal conversion
        uint256 expectedDecimal = testPrice / (10 ** 8);
        assertEq(priceConsumer.getPriceAsDecimal(), expectedDecimal);
        assertEq(priceConsumer.getPriceAsDecimal(), 4); // $4.50 -> 4 (integer part)
    }

    function testGetPriceAsDecimalZero() public {
        // When price is 0, decimal should also be 0
        assertEq(priceConsumer.getPriceAsDecimal(), 0);
    }

    function testGetPriceAsDecimalHighPrecision() public {
        uint256 highPrice = 1250000000; // $12.50 with 8 decimals
        bytes32 requestId = keccak256(abi.encodePacked("test_request"));

        mockOracle.setResponse(requestId, highPrice);
        vm.prank(address(mockOracle));
        priceConsumer.fulfill(requestId, highPrice);

        assertEq(priceConsumer.getPriceAsDecimal(), 12); // $12.50 -> 12
    }

    function testGetPriceAsDecimalSmallPrice() public {
        uint256 smallPrice = 50000000; // $0.50 with 8 decimals
        bytes32 requestId = keccak256(abi.encodePacked("test_request"));

        mockOracle.setResponse(requestId, smallPrice);
        vm.prank(address(mockOracle));
        priceConsumer.fulfill(requestId, smallPrice);

        assertEq(priceConsumer.getPriceAsDecimal(), 0); // $0.50 -> 0 (integer part)
    }

    function testMultiplePriceUpdates() public {
        uint256[] memory prices = new uint256[](3);
        prices[0] = 400000000; // $4.00
        prices[1] = 450000000; // $4.50
        prices[2] = 500000000; // $5.00

        for (uint256 i = 0; i < prices.length; i++) {
            bytes32 requestId = keccak256(abi.encodePacked("request", i));
            mockOracle.setResponse(requestId, prices[i]);

            vm.prank(address(mockOracle));
            priceConsumer.fulfill(requestId, prices[i]);

            assertEq(priceConsumer.price(), prices[i]);
            assertEq(priceConsumer.getPriceAsDecimal(), prices[i] / (10 ** 8));
        }
    }

    function testOwnershipTransfer() public {
        address newOwner = makeAddr("newOwner");

        // Transfer ownership
        priceConsumer.transferOwnership(newOwner);
        assertEq(priceConsumer.owner(), newOwner);

        // Old owner should not be able to set job ID
        vm.expectRevert();
        priceConsumer.setJobId(JOB_ID);

        // New owner should be able to set job ID
        vm.prank(newOwner);
        priceConsumer.setJobId(JOB_ID);
    }

    function testLinkTokenIntegration() public {
        // Test that the contract can handle LINK tokens
        uint256 initialBalance = linkToken.balanceOf(address(priceConsumer));
        assertGt(initialBalance, 0);

        // Test that contract can receive more LINK
        linkToken.transfer(address(priceConsumer), 1e18);
        assertEq(linkToken.balanceOf(address(priceConsumer)), initialBalance + 1e18);
    }

    function testPriceConstants() public {
        // Test that price constants are correctly defined
        // These are internal constants, so we test their effects
        uint256 testPrice = 100000000; // $1.00 with 8 decimals
        bytes32 requestId = keccak256(abi.encodePacked("test_request"));

        mockOracle.setResponse(requestId, testPrice);
        vm.prank(address(mockOracle));
        priceConsumer.fulfill(requestId, testPrice);

        // The decimal conversion should work correctly
        assertEq(priceConsumer.getPriceAsDecimal(), 1);
    }

    function testFulfillOnlyFromOracle() public {
        bytes32 requestId = keccak256(abi.encodePacked("unauthorized_request"));
        uint256 price = 500000000;

        // Should revert when called from unauthorized address
        vm.prank(unauthorized);
        vm.expectRevert();
        priceConsumer.fulfill(requestId, price);

        // Should work when called from oracle
        vm.prank(address(mockOracle));
        priceConsumer.fulfill(requestId, price);
        assertEq(priceConsumer.price(), price);
    }

    function testMaxPrice() public {
        uint256 maxPrice = type(uint256).max;
        bytes32 requestId = keccak256(abi.encodePacked("max_price_request"));

        mockOracle.setResponse(requestId, maxPrice);
        vm.prank(address(mockOracle));
        priceConsumer.fulfill(requestId, maxPrice);

        assertEq(priceConsumer.price(), maxPrice);
        // Decimal conversion should handle large numbers
        assertEq(priceConsumer.getPriceAsDecimal(), maxPrice / (10 ** 8));
    }

    function testZeroPrice() public {
        uint256 zeroPrice = 0;
        bytes32 requestId = keccak256(abi.encodePacked("zero_price_request"));

        mockOracle.setResponse(requestId, zeroPrice);
        vm.prank(address(mockOracle));
        priceConsumer.fulfill(requestId, zeroPrice);

        assertEq(priceConsumer.price(), 0);
        assertEq(priceConsumer.getPriceAsDecimal(), 0);
    }

    function testMockPriceConsumerSetPrice() public {
        uint256[] memory testPrices = new uint256[](5);
        testPrices[0] = 0;
        testPrices[1] = 100000000; // $1.00
        testPrices[2] = 450000000; // $4.50
        testPrices[3] = 1000000000; // $10.00
        testPrices[4] = type(uint256).max;

        for (uint256 i = 0; i < testPrices.length; i++) {
            mockPriceConsumer.setPrice(testPrices[i]);
            assertEq(mockPriceConsumer.price(), testPrices[i]);
            assertEq(mockPriceConsumer.getPriceAsDecimal(), testPrices[i] / (10 ** 8));
        }
    }

    function testRequestIdGeneration() public {
        // Test that multiple requests generate different IDs
        bytes32 requestId1 = priceConsumer.requestCopperPrice();

        // Simulate some time passing or state change
        vm.warp(block.timestamp + 1);

        bytes32 requestId2 = priceConsumer.requestCopperPrice();

        // Request IDs should be different
        assertTrue(requestId1 != requestId2);
    }

    function testChainlinkRequestParameters() public {
        // This test verifies that the Chainlink request is built with correct parameters
        // Since the request building is internal, we test the external behavior

        bytes32 requestId = priceConsumer.requestCopperPrice();

        // Verify request was created (non-zero ID)
        assertTrue(requestId != bytes32(0));

        // Verify that the request can be fulfilled
        uint256 testPrice = 425000000; // $4.25
        mockOracle.setResponse(requestId, testPrice);
        vm.prank(address(mockOracle));
        priceConsumer.fulfill(requestId, testPrice);

        assertEq(priceConsumer.price(), testPrice);
    }

    function testPriceDecimalPrecision() public {
        // Test various price points to ensure decimal conversion is accurate
        uint256[6] memory rawPrices = [uint256(0), 99999999, 100000000, 199999999, 450000000, 999999999];
        uint256[6] memory expectedDecimals = [uint256(0), 0, 1, 1, 4, 9];

        for (uint256 i = 0; i < rawPrices.length; i++) {
            bytes32 requestId = keccak256(abi.encodePacked("precision_test", i));
            mockOracle.setResponse(requestId, rawPrices[i]);

            vm.prank(address(mockOracle));
            priceConsumer.fulfill(requestId, rawPrices[i]);

            assertEq(priceConsumer.price(), rawPrices[i]);
            assertEq(priceConsumer.getPriceAsDecimal(), expectedDecimals[i]);
        }
    }
}
