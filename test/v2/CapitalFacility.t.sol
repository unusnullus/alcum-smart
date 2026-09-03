// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {V2TestBase} from "./Helpers.sol";
import {CapitalFacility} from "../../contracts/v2/CapitalFacility.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

/// @dev A contract that always reverts on any call (used to test DeploymentFailed).
contract AlwaysRevertsProtocol {
    fallback() external {
        revert("protocol revert");
    }
}

contract CapitalFacilityTest is V2TestBase {
    CapitalFacility internal facility;
    address internal operator;
    address internal proto; // mock protocol address

    function setUp() public override {
        super.setUp();
        operator = makeAddr("operator");
        proto = makeAddr("proto");

        // Use the facility deployed by factory for vault 1
        facility = CapitalFacility(facilityAddr);

        // Cache role before prank — calling a view function would consume vm.prank
        bytes32 operatorRole = facility.FACILITY_OPERATOR_ROLE();
        vm.prank(admin);
        facility.grantRole(operatorRole, operator);
    }

    // ─── idleBalance / totalBalance ───────────────────────────────────────────

    function test_idleBalance_empty() public {
        assertEq(facility.idleBalance(), 0);
    }

    function test_totalBalance_withIdle() public {
        usdc.mint(facilityAddr, 1000e6);
        assertEq(facility.totalBalance(), 1000e6);
        assertEq(facility.idleBalance(), 1000e6);
    }

    // ─── setProtocolWhitelisted ───────────────────────────────────────────────

    function test_setProtocolWhitelisted_onlyOwner() public {
        vm.prank(admin);
        facility.setProtocolWhitelisted(proto, true);
        assertTrue(facility.isWhitelisted(proto));
    }

    function test_setProtocolWhitelisted_removeWhitelist() public {
        vm.prank(admin);
        facility.setProtocolWhitelisted(proto, true);
        vm.prank(admin);
        facility.setProtocolWhitelisted(proto, false);
        assertFalse(facility.isWhitelisted(proto));
    }

    function test_setProtocolWhitelisted_revertsZeroAddress() public {
        vm.prank(admin);
        vm.expectRevert(CapitalFacility.ZeroAddress.selector);
        facility.setProtocolWhitelisted(address(0), true);
    }

    function test_setProtocolWhitelisted_revertsUnauthorized() public {
        vm.prank(user);
        vm.expectRevert();
        facility.setProtocolWhitelisted(proto, true);
    }

    // ─── deployCapital ────────────────────────────────────────────────────────

    function _whitelistAndFund(uint256 amount) internal {
        vm.prank(admin);
        facility.setProtocolWhitelisted(proto, true);
        usdc.mint(facilityAddr, amount);
    }

    function test_deployCapital_happyPath() public {
        _whitelistAndFund(1000e6);

        vm.prank(operator);
        facility.deployCapital(proto, 1000e6, "");

        assertEq(facility.deployedIn(proto), 1000e6);
        assertEq(facility.totalDeployed(), 1000e6);
        assertEq(facility.idleBalance(), 0);
        assertEq(usdc.balanceOf(proto), 1000e6);
    }

    function test_deployCapital_appearsInActiveProtocols() public {
        _whitelistAndFund(500e6);
        vm.prank(operator);
        facility.deployCapital(proto, 500e6, "");

        address[] memory active = facility.getActiveProtocols();
        assertEq(active.length, 1);
        assertEq(active[0], proto);
    }

    function test_deployCapital_accumulatesForSameProtocol() public {
        _whitelistAndFund(2000e6);
        vm.prank(operator);
        facility.deployCapital(proto, 1000e6, "");
        vm.prank(operator);
        facility.deployCapital(proto, 500e6, "");

        assertEq(facility.deployedIn(proto), 1500e6);
        assertEq(facility.totalDeployed(), 1500e6);

        // Still only one entry in active protocols
        assertEq(facility.getActiveProtocols().length, 1);
    }

    function test_deployCapital_revertsNotWhitelisted() public {
        usdc.mint(facilityAddr, 1000e6);
        vm.prank(operator);
        vm.expectRevert(abi.encodeWithSelector(CapitalFacility.ProtocolNotWhitelisted.selector, proto));
        facility.deployCapital(proto, 1000e6, "");
    }

    function test_deployCapital_revertsInsufficientIdle() public {
        vm.prank(admin);
        facility.setProtocolWhitelisted(proto, true);
        usdc.mint(facilityAddr, 100e6);

        vm.prank(operator);
        vm.expectRevert(abi.encodeWithSelector(CapitalFacility.InsufficientIdleBalance.selector, 100e6, 200e6));
        facility.deployCapital(proto, 200e6, "");
    }

    function test_deployCapital_revertsZeroAmount() public {
        vm.prank(admin);
        facility.setProtocolWhitelisted(proto, true);
        vm.prank(operator);
        vm.expectRevert(CapitalFacility.ZeroAmount.selector);
        facility.deployCapital(proto, 0, "");
    }

    function test_deployCapital_revertsZeroProtocol() public {
        vm.prank(operator);
        vm.expectRevert(CapitalFacility.ZeroAddress.selector);
        facility.deployCapital(address(0), 100e6, "");
    }

    function test_deployCapital_revertsUnauthorized() public {
        vm.prank(user);
        vm.expectRevert();
        facility.deployCapital(proto, 100e6, "");
    }

    // ─── recallCapital ────────────────────────────────────────────────────────

    function _deployToProto(uint256 amount) internal {
        _whitelistAndFund(amount);
        vm.prank(operator);
        facility.deployCapital(proto, amount, "");
        // Pre-approve the proto to let facility pull back
        vm.prank(proto);
        usdc.approve(facilityAddr, type(uint256).max);
    }

    function test_recallCapital_updatesAccounting() public {
        _deployToProto(1000e6);

        vm.prank(operator);
        facility.recallCapital(proto, 1000e6);

        assertEq(facility.deployedIn(proto), 0);
        assertEq(facility.totalDeployed(), 0);
    }

    function test_recallCapital_removesFromActiveProtocols() public {
        _deployToProto(1000e6);

        vm.prank(operator);
        facility.recallCapital(proto, 1000e6);

        assertEq(facility.getActiveProtocols().length, 0);
    }

    function test_recallCapital_partialAmount() public {
        _deployToProto(1000e6);

        vm.prank(operator);
        facility.recallCapital(proto, 400e6);

        assertEq(facility.deployedIn(proto), 600e6);
        assertEq(facility.totalDeployed(), 600e6);
        // protocol still in active list
        assertEq(facility.getActiveProtocols().length, 1);
    }

    function test_recallCapital_revertsZeroDeployment() public {
        vm.prank(operator);
        vm.expectRevert(abi.encodeWithSelector(CapitalFacility.ZeroDeploymentInProtocol.selector, proto));
        facility.recallCapital(proto, 1000e6);
    }

    function test_recallCapital_revertsUnauthorized() public {
        vm.prank(user);
        vm.expectRevert();
        facility.recallCapital(proto, 1000e6);
    }

    function test_recallCapital_revertsWhenPullFails() public {
        _whitelistAndFund(1000e6);
        vm.prank(operator);
        facility.deployCapital(proto, 1000e6, "");

        vm.prank(operator);
        vm.expectRevert(CapitalFacility.RecallFailed.selector);
        facility.recallCapital(proto, 1000e6);
    }

    function test_acknowledgeCapitalRecall_updatesAccounting() public {
        _deployToProto(1000e6);
        vm.prank(proto);
        usdc.transfer(facilityAddr, 1000e6);

        vm.prank(operator);
        facility.acknowledgeCapitalRecall(proto, 1000e6);

        assertEq(facility.deployedIn(proto), 0);
        assertEq(facility.totalDeployed(), 0);
    }

    // ─── recallAll ────────────────────────────────────────────────────────────

    function test_recallAll_emptiesAll() public {
        address proto2 = makeAddr("proto2");

        vm.prank(admin);
        facility.setProtocolWhitelisted(proto, true);
        vm.prank(admin);
        facility.setProtocolWhitelisted(proto2, true);

        usdc.mint(facilityAddr, 2000e6);
        vm.prank(operator);
        facility.deployCapital(proto, 1000e6, "");
        vm.prank(operator);
        facility.deployCapital(proto2, 1000e6, "");

        // Pre-approve both protocols
        vm.prank(proto);
        usdc.approve(facilityAddr, type(uint256).max);
        vm.prank(proto2);
        usdc.approve(facilityAddr, type(uint256).max);

        vm.prank(operator);
        facility.recallAll();

        assertEq(facility.totalDeployed(), 0);
        assertEq(facility.deployedIn(proto), 0);
        assertEq(facility.deployedIn(proto2), 0);
        assertEq(facility.getActiveProtocols().length, 0);
    }

    // ─── setAuthorizedSpender ─────────────────────────────────────────────────

    function test_setAuthorizedSpender_updatesAndReapproves() public {
        address newSpender = makeAddr("newSpender");
        address oldSpender = facility.authorizedSpender();

        vm.prank(admin);
        facility.setAuthorizedSpender(newSpender);

        assertEq(facility.authorizedSpender(), newSpender);
        // Old spender approval revoked
        assertEq(usdc.allowance(facilityAddr, oldSpender), 0);
        // New spender has max approval
        assertEq(usdc.allowance(facilityAddr, newSpender), type(uint256).max);
    }

    function test_setAuthorizedSpender_revertsZeroAddress() public {
        vm.prank(admin);
        vm.expectRevert(CapitalFacility.ZeroAddress.selector);
        facility.setAuthorizedSpender(address(0));
    }

    function test_setAuthorizedSpender_revertsUnauthorized() public {
        vm.prank(user);
        vm.expectRevert();
        facility.setAuthorizedSpender(makeAddr("x"));
    }

    // ─── deployedIn view ─────────────────────────────────────────────────────

    function test_deployedIn_returnsZeroForUnknown() public {
        assertEq(facility.deployedIn(makeAddr("unknown")), 0);
    }

    // ─── deployCapital with calldata ─────────────────────────────────────────

    function test_deployCapital_revertsOnBadCalldata() public {
        // Deploy a contract that always reverts
        address reverter = address(new AlwaysRevertsProtocol());

        vm.prank(admin);
        facility.setProtocolWhitelisted(reverter, true);
        usdc.mint(facilityAddr, 500e6);

        // deployCapital sends tokens to the contract and then calls it with data.
        // The contract reverts, which should cause DeploymentFailed to be thrown.
        vm.prank(operator);
        vm.expectRevert(CapitalFacility.DeploymentFailed.selector);
        facility.deployCapital(reverter, 500e6, abi.encodeWithSignature("deposit(uint256)", 500e6));
    }
}
