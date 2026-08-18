// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {CopperAssetOracle} from "../../contracts/v2/oracles/CopperAssetOracle.sol";
import {ICopperPriceConsumer} from "../../contracts/interfaces/ICopperPriceConsumer.sol";

/// @dev Minimal mock for the underlying Chainlink-backed price consumer.
contract MockCopperConsumer is ICopperPriceConsumer {
    uint256 public price;

    constructor(uint256 initialPrice) {
        price = initialPrice;
    }

    function setPrice(uint256 p) external {
        price = p;
    }

    // Unused interface methods
    function requestCopperPrice() external pure returns (bytes32) {
        return bytes32(0);
    }
    function fulfill(bytes32, uint256) external pure {}
    function getPriceAsDecimal() external view returns (uint256) {
        return price / 1e8;
    }
    function updatePrice(uint256 p) external {
        price = p;
    }
}

contract CopperAssetOracleTest is Test {
    CopperAssetOracle internal oracle;
    MockCopperConsumer internal consumer;

    address internal admin = makeAddr("admin");
    address internal operator = makeAddr("operator");
    address internal stranger = makeAddr("stranger");

    uint256 constant LIVE_PRICE = 450_000_000; // $4.50 (8 dec)
    uint256 constant FALLBACK_PRICE = 400_000_000; // $4.00 fallback

    function setUp() public {
        consumer = new MockCopperConsumer(LIVE_PRICE);
        oracle = new CopperAssetOracle(address(consumer), admin);

        // Cache role constant BEFORE vm.prank — view calls consume the prank slot.
        bytes32 oracleAdminRole = oracle.ORACLE_ADMIN_ROLE();
        vm.prank(admin);
        oracle.grantRole(oracleAdminRole, operator);
    }

    // ─── constructor guards ───────────────────────────────────────────────────

    function test_constructor_revertsZeroUnderlying() public {
        vm.expectRevert(CopperAssetOracle.ZeroAddress.selector);
        new CopperAssetOracle(address(0), admin);
    }

    function test_constructor_revertsZeroAdmin() public {
        vm.expectRevert(CopperAssetOracle.ZeroAddress.selector);
        new CopperAssetOracle(address(consumer), address(0));
    }

    // ─── IAssetOracle interface ───────────────────────────────────────────────

    function test_decimals_is8() public {
        assertEq(oracle.decimals(), 8);
    }

    function test_description_isCopper() public {
        assertEq(oracle.description(), "Copper / USD");
    }

    function test_price_returnsLive() public {
        assertEq(oracle.price(), LIVE_PRICE);
    }

    function test_price_fallsBackWhenUnderlyingZero() public {
        // Set fallback price first
        vm.prank(operator);
        oracle.setFallbackPrice(FALLBACK_PRICE);

        // Make underlying return 0
        consumer.setPrice(0);

        assertEq(oracle.price(), FALLBACK_PRICE);
    }

    function test_price_usesFallbackWhenFlagSet() public {
        vm.prank(operator);
        oracle.setFallbackPrice(FALLBACK_PRICE);
        vm.prank(operator);
        oracle.setUseFallback(true);

        // underlying still has a live price, but flag overrides it
        assertEq(oracle.price(), FALLBACK_PRICE);
    }

    function test_price_returnsLiveAfterFallbackDisabled() public {
        vm.prank(operator);
        oracle.setFallbackPrice(FALLBACK_PRICE);
        vm.prank(operator);
        oracle.setUseFallback(true);
        vm.prank(operator);
        oracle.setUseFallback(false);

        assertEq(oracle.price(), LIVE_PRICE);
    }

    // ─── updatedAt ────────────────────────────────────────────────────────────

    function test_updatedAt_returnsBlockTimestampWhenNoFallback() public {
        uint256 ts = oracle.updatedAt();
        assertEq(ts, block.timestamp);
    }

    function test_updatedAt_returnsFallbackTimestampWhenSet() public {
        vm.warp(1_700_000_000);
        vm.prank(operator);
        oracle.setFallbackPrice(FALLBACK_PRICE);

        assertEq(oracle.updatedAt(), 1_700_000_000);
    }

    function test_updatedAt_returnsFallbackTimestampWhenFlagSet() public {
        vm.warp(1_700_000_000);
        vm.prank(operator);
        oracle.setFallbackPrice(FALLBACK_PRICE);
        vm.prank(operator);
        oracle.setUseFallback(true);

        assertEq(oracle.updatedAt(), 1_700_000_000);
    }

    // ─── setFallbackPrice ─────────────────────────────────────────────────────

    function test_setFallbackPrice_stores() public {
        vm.prank(operator);
        oracle.setFallbackPrice(FALLBACK_PRICE);
        assertEq(oracle.fallbackPrice(), FALLBACK_PRICE);
    }

    function test_setFallbackPrice_updatesTimestamp() public {
        vm.warp(1_700_000_000);
        vm.prank(operator);
        oracle.setFallbackPrice(FALLBACK_PRICE);
        assertEq(oracle.fallbackUpdatedAt(), 1_700_000_000);
    }

    function test_setFallbackPrice_emitsEvent() public {
        vm.prank(operator);
        vm.expectEmit(false, false, true, true);
        emit CopperAssetOracle.FallbackPriceSet(0, FALLBACK_PRICE, operator);
        oracle.setFallbackPrice(FALLBACK_PRICE);
    }

    function test_setFallbackPrice_revertsZero() public {
        vm.prank(operator);
        vm.expectRevert(CopperAssetOracle.ZeroPrice.selector);
        oracle.setFallbackPrice(0);
    }

    function test_setFallbackPrice_revertsUnauthorized() public {
        vm.prank(stranger);
        vm.expectRevert();
        oracle.setFallbackPrice(FALLBACK_PRICE);
    }

    // ─── setUseFallback ───────────────────────────────────────────────────────

    function test_setUseFallback_setsFlag() public {
        vm.prank(operator);
        oracle.setUseFallback(true);
        assertTrue(oracle.useFallback());

        vm.prank(operator);
        oracle.setUseFallback(false);
        assertFalse(oracle.useFallback());
    }

    function test_setUseFallback_emitsEvent() public {
        vm.prank(operator);
        vm.expectEmit(false, false, false, true);
        emit CopperAssetOracle.UseFallbackToggled(true);
        oracle.setUseFallback(true);
    }

    function test_setUseFallback_revertsUnauthorized() public {
        vm.prank(stranger);
        vm.expectRevert();
        oracle.setUseFallback(true);
    }

    // ─── setUnderlying ────────────────────────────────────────────────────────

    function test_setUnderlying_replacesConsumer() public {
        MockCopperConsumer newConsumer = new MockCopperConsumer(999_000_000);
        vm.prank(operator);
        oracle.setUnderlying(address(newConsumer));
        assertEq(address(oracle.underlying()), address(newConsumer));
        assertEq(oracle.price(), 999_000_000);
    }

    function test_setUnderlying_emitsEvent() public {
        MockCopperConsumer newConsumer = new MockCopperConsumer(100);
        vm.prank(operator);
        vm.expectEmit(true, true, false, false);
        emit CopperAssetOracle.UnderlyingUpdated(address(consumer), address(newConsumer));
        oracle.setUnderlying(address(newConsumer));
    }

    function test_setUnderlying_revertsZeroAddress() public {
        vm.prank(operator);
        vm.expectRevert(CopperAssetOracle.ZeroAddress.selector);
        oracle.setUnderlying(address(0));
    }

    function test_setUnderlying_revertsUnauthorized() public {
        vm.prank(stranger);
        vm.expectRevert();
        oracle.setUnderlying(address(consumer));
    }

    // ─── role management ─────────────────────────────────────────────────────

    function test_adminCanGrantOracleAdminRole() public {
        bytes32 oracleAdminRole = oracle.ORACLE_ADMIN_ROLE();
        vm.prank(admin);
        oracle.grantRole(oracleAdminRole, stranger);

        vm.prank(stranger);
        oracle.setFallbackPrice(FALLBACK_PRICE); // should not revert
    }

    function test_adminCanRevokeOracleAdminRole() public {
        bytes32 oracleAdminRole = oracle.ORACLE_ADMIN_ROLE();
        vm.prank(admin);
        oracle.revokeRole(oracleAdminRole, operator);

        vm.prank(operator);
        vm.expectRevert();
        oracle.setFallbackPrice(FALLBACK_PRICE);
    }
}
