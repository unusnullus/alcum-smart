// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test, console} from "forge-std/Test.sol";
import {EpochManager} from "../contracts/EpochManager.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

contract EpochManagerTest is Test {
    EpochManager public epochManager;
    address public owner;
    address public admin;

    function setUp() public {
        owner = address(this);
        admin = makeAddr("admin");

        // Deploy implementation
        EpochManager implementation = new EpochManager();

        // Deploy proxy
        bytes memory initData = abi.encodeWithSelector(EpochManager.initialize.selector, 7 days);
        ERC1967Proxy proxy = new ERC1967Proxy(address(implementation), initData);

        epochManager = EpochManager(address(proxy));
    }

    function testInitialization() public {
        assertEq(epochManager.epochDuration(), 7 days);
        assertEq(epochManager.currentEpochId(), 0);
        assertTrue(epochManager.hasRole(epochManager.DEFAULT_ADMIN_ROLE(), owner));
    }

    function testNextEpoch() public {
        // Need to wait for epoch to finish
        vm.warp(7 days + 1);
        uint256 currentEpoch = epochManager.currentEpochId();
        epochManager.nextEpoch();
        assertEq(epochManager.currentEpochId(), currentEpoch + 1);
    }

    function testTimeLeftInEpoch() public {
        uint256 timeLeft = epochManager.timeLeftInEpoch();
        assertTrue(timeLeft <= 7 days);
        assertTrue(timeLeft > 0);
    }

    function testEpochStart() public {
        uint256 start = epochManager.epochStart();
        assertTrue(start <= block.timestamp);
    }

    function testSetEpochDuration() public {
        uint256 newDuration = 14 days;
        epochManager.setEpochDuration(newDuration);
        assertEq(epochManager.epochDuration(), newDuration);
    }

    function testSetEpochDurationWithoutRole() public {
        vm.prank(admin);
        vm.expectRevert();
        epochManager.setEpochDuration(14 days);
    }

    function testPause() public {
        epochManager.pause();
        assertTrue(epochManager.paused());
    }

    function testUnpause() public {
        epochManager.pause();
        epochManager.unpause();
        assertFalse(epochManager.paused());
    }

    function testPauseWithoutRole() public {
        vm.prank(admin);
        vm.expectRevert();
        epochManager.pause();
    }

    function testSetEpochDurationInvalid() public {
        vm.expectRevert(EpochManager.InvalidEpochDuration.selector);
        epochManager.setEpochDuration(0);
    }

    function testNextEpochMultiple() public {
        // Test multiple epoch advances - need to wait for epoch to finish
        vm.warp(block.timestamp + 7 days + 1);
        uint256 initialEpoch = epochManager.currentEpochId();

        epochManager.nextEpoch();
        assertEq(epochManager.currentEpochId(), initialEpoch + 1);

        vm.warp(block.timestamp + 7 days + 1);
        epochManager.nextEpoch();
        assertEq(epochManager.currentEpochId(), initialEpoch + 2);
    }

    function testTimeLeftInEpochAfterAdvance() public {
        // Advance epoch and check time left - need to wait for epoch to finish
        vm.warp(block.timestamp + 7 days + 1);
        epochManager.nextEpoch();
        uint256 timeLeft = epochManager.timeLeftInEpoch();
        assertTrue(timeLeft <= 7 days);
    }

    function testEpochStartAfterAdvanceSecond() public {
        uint256 initialStart = epochManager.epochStart();
        vm.warp(block.timestamp + 7 days + 1);
        epochManager.nextEpoch();
        uint256 newStart = epochManager.epochStart();
        assertTrue(newStart > initialStart);
    }

    function testSetEpochDurationWithMaxDurationType() public {
        uint256 maxDuration = type(uint256).max;
        vm.expectRevert(EpochManager.EpochDurationTooLong.selector);
        epochManager.setEpochDuration(maxDuration);
    }

    function testSetEpochDurationWithOneSecond() public {
        uint256 oneSecond = 1;
        epochManager.setEpochDuration(oneSecond);
        assertEq(epochManager.epochDuration(), oneSecond);
    }

    function testSetEpochDurationWithOneDay() public {
        uint256 oneDay = 1 days;
        epochManager.setEpochDuration(oneDay);
        assertEq(epochManager.epochDuration(), oneDay);
    }

    function testSetEpochDurationWithOneYear() public {
        uint256 oneYear = 365 days;
        epochManager.setEpochDuration(oneYear);
        assertEq(epochManager.epochDuration(), oneYear);
    }

    function testTimeLeftInEpochAtStart() public {
        uint256 timeLeft = epochManager.timeLeftInEpoch();
        assertTrue(timeLeft <= 7 days);
        assertTrue(timeLeft > 0);
    }

    function testTimeLeftInEpochAfterHalfEpoch() public {
        vm.warp(block.timestamp + 3.5 days);
        uint256 timeLeft = epochManager.timeLeftInEpoch();
        assertTrue(timeLeft <= 3.5 days);
        assertTrue(timeLeft > 0);
    }

    function testTimeLeftInEpochAtEnd() public {
        vm.warp(block.timestamp + 7 days);
        uint256 timeLeft = epochManager.timeLeftInEpoch();
        assertTrue(timeLeft <= 7 days);
    }

    function testCurrentEpochIdInitial() public {
        uint256 initialEpoch = epochManager.currentEpochId();
        assertTrue(initialEpoch >= 0);
    }

    function testCurrentEpochIdAfterAdvance() public {
        uint256 initialEpoch = epochManager.currentEpochId();
        vm.warp(block.timestamp + 7 days + 1);
        epochManager.nextEpoch();
        uint256 newEpoch = epochManager.currentEpochId();
        assertEq(newEpoch, initialEpoch + 1);
    }

    function testEpochStartInitial() public {
        uint256 start = epochManager.epochStart();
        assertTrue(start >= 0);
    }

    function testEpochStartAfterAdvance() public {
        uint256 initialStart = epochManager.epochStart();
        vm.warp(block.timestamp + 7 days + 1);
        epochManager.nextEpoch();
        uint256 newStart = epochManager.epochStart();
        assertTrue(newStart > initialStart);
    }

    // Test error cases for better branch coverage
    function testNextEpochBeforeFinished() public {
        // Try to advance epoch before it's finished
        vm.expectRevert(EpochManager.EpochNotFinished.selector);
        epochManager.nextEpoch();
    }

    function testSetEpochDurationWithSameDuration() public {
        uint256 currentDuration = epochManager.epochDuration();
        vm.expectRevert(EpochManager.SameDuration.selector);
        epochManager.setEpochDuration(currentDuration);
    }

    function testSetEpochDurationWithInvalidFee() public {
        vm.expectRevert(EpochManager.InvalidEpochDuration.selector);
        epochManager.setEpochDuration(0);
    }

    function testSetEpochDurationWithMaxDuration() public {
        uint256 maxDuration = 366 days; // More than 365 days
        vm.expectRevert(EpochManager.EpochDurationTooLong.selector);
        epochManager.setEpochDuration(maxDuration);
    }

    // Test initialization error cases for better branch coverage
    function testInitializeWithZeroDuration() public {
        EpochManager implementation = new EpochManager();
        bytes memory initData = abi.encodeWithSelector(EpochManager.initialize.selector, 0);

        vm.expectRevert(EpochManager.InvalidEpochDuration.selector);
        new ERC1967Proxy(address(implementation), initData);
    }

    function testInitializeWithTooLongDuration() public {
        EpochManager implementation = new EpochManager();
        bytes memory initData = abi.encodeWithSelector(EpochManager.initialize.selector, 366 days);

        vm.expectRevert(EpochManager.EpochDurationTooLong.selector);
        new ERC1967Proxy(address(implementation), initData);
    }
}
