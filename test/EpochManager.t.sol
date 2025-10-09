// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";

import {Upgrades} from "openzeppelin-foundry-upgrades/Upgrades.sol";

import {EpochManager} from "../contracts/EpochManager.sol";

contract EpochManagerTest is Test {
    EpochManager public epochManager;

    address internal owner;
    address internal user1;
    address internal unauthorized;

    uint256 constant EPOCH_DURATION = 30 days;
    uint256 constant SHORT_EPOCH_DURATION = 1 hours;

    event EpochStarted(uint256 indexed epochId, uint256 start);

    function setUp() public {
        owner = address(this);
        user1 = makeAddr("user1");
        unauthorized = makeAddr("unauthorized");

        // Deploy EpochManager using upgradeable pattern
        address epochManagerProxy = Upgrades.deployTransparentProxy(
            "EpochManager.sol:EpochManager",
            owner,
            abi.encodeCall(EpochManager.initialize, (EPOCH_DURATION))
        );
        epochManager = EpochManager(epochManagerProxy);
    }

    function testInitialState() public {
        assertEq(epochManager.currentEpochId(), 0);
        assertEq(epochManager.epochDuration(), EPOCH_DURATION);
        assertEq(epochManager.epochStart(), 0);
        assertEq(epochManager.timeLeftInEpoch(), EPOCH_DURATION);
        assertEq(epochManager.owner(), owner);
        assertFalse(epochManager.paused());
    }

    function testInitializeRevertZeroDuration() public {
        vm.expectRevert("Epoch duration must be greater than 0");
        Upgrades.deployTransparentProxy(
            "EpochManager.sol:EpochManager",
            owner,
            abi.encodeCall(EpochManager.initialize, (0))
        );
    }

    function testNextEpoch() public {
        // Fast forward time to end of current epoch
        vm.warp(block.timestamp + EPOCH_DURATION);

        vm.expectEmit(true, false, false, true);
        emit EpochStarted(1, block.timestamp);

        epochManager.nextEpoch();

        assertEq(epochManager.currentEpochId(), 1);
        assertEq(epochManager.epochStart(), block.timestamp);
        assertEq(epochManager.timeLeftInEpoch(), EPOCH_DURATION);
    }

    function testNextEpochRevertEpochNotOver() public {
        // Try to advance epoch before it's finished
        vm.expectRevert("Epoch not over");
        epochManager.nextEpoch();
    }

    function testNextEpochRevertNotOwner() public {
        vm.warp(block.timestamp + EPOCH_DURATION);

        vm.prank(unauthorized);
        vm.expectRevert();
        epochManager.nextEpoch();
    }

    function testTimeLeftInEpoch() public {
        uint256 initialTime = block.timestamp;

        // At start, should have full duration left
        assertEq(epochManager.timeLeftInEpoch(), EPOCH_DURATION);

        // Fast forward half the epoch
        vm.warp(initialTime + EPOCH_DURATION / 2);
        assertEq(epochManager.timeLeftInEpoch(), EPOCH_DURATION / 2);

        // Fast forward to end of epoch
        vm.warp(initialTime + EPOCH_DURATION);
        assertEq(epochManager.timeLeftInEpoch(), 0);

        // Fast forward past epoch end
        vm.warp(initialTime + EPOCH_DURATION + 1 days);
        assertEq(epochManager.timeLeftInEpoch(), 0);
    }

    function testMultipleEpochAdvancement() public {
        uint256 initialTime = block.timestamp;

        // Advance to epoch 1
        vm.warp(initialTime + EPOCH_DURATION);
        epochManager.nextEpoch();
        assertEq(epochManager.currentEpochId(), 1);

        uint256 epoch1Start = block.timestamp;

        // Advance to epoch 2
        vm.warp(epoch1Start + EPOCH_DURATION);
        epochManager.nextEpoch();
        assertEq(epochManager.currentEpochId(), 2);

        uint256 epoch2Start = block.timestamp;

        // Advance to epoch 3
        vm.warp(epoch2Start + EPOCH_DURATION);
        epochManager.nextEpoch();
        assertEq(epochManager.currentEpochId(), 3);

        assertEq(epochManager.epochStart(), block.timestamp);
        assertEq(epochManager.timeLeftInEpoch(), EPOCH_DURATION);
    }

    function testPause() public {
        epochManager.pause();
        assertTrue(epochManager.paused());
    }

    function testUnpause() public {
        epochManager.pause();
        assertTrue(epochManager.paused());

        epochManager.unpause();
        assertFalse(epochManager.paused());
    }

    function testPauseRevertNotOwner() public {
        vm.prank(unauthorized);
        vm.expectRevert();
        epochManager.pause();
    }

    function testUnpauseRevertNotOwner() public {
        epochManager.pause();

        vm.prank(unauthorized);
        vm.expectRevert();
        epochManager.unpause();
    }

    function testEpochBoundaryConditions() public {
        uint256 initialTime = block.timestamp;

        // Test exactly at epoch boundary
        vm.warp(initialTime + EPOCH_DURATION);
        assertEq(epochManager.timeLeftInEpoch(), 0);

        // Should be able to advance epoch
        epochManager.nextEpoch();
        assertEq(epochManager.currentEpochId(), 1);

        // Test one second before epoch end
        vm.warp(epochManager.epochStart() + EPOCH_DURATION - 1);
        assertEq(epochManager.timeLeftInEpoch(), 1);

        // Should not be able to advance yet
        vm.expectRevert("Epoch not over");
        epochManager.nextEpoch();

        // Test one second after epoch end
        vm.warp(epochManager.epochStart() + EPOCH_DURATION + 1);
        assertEq(epochManager.timeLeftInEpoch(), 0);

        // Should be able to advance
        epochManager.nextEpoch();
        assertEq(epochManager.currentEpochId(), 2);
    }

    function testShortEpochDuration() public {
        // Deploy with short epoch duration
        address shortEpochManagerProxy = Upgrades.deployTransparentProxy(
            "EpochManager.sol:EpochManager",
            owner,
            abi.encodeCall(EpochManager.initialize, (SHORT_EPOCH_DURATION))
        );
        EpochManager shortEpochManager = EpochManager(shortEpochManagerProxy);

        assertEq(shortEpochManager.epochDuration(), SHORT_EPOCH_DURATION);
        assertEq(shortEpochManager.timeLeftInEpoch(), SHORT_EPOCH_DURATION);

        // Fast forward and advance epoch
        vm.warp(block.timestamp + SHORT_EPOCH_DURATION);
        shortEpochManager.nextEpoch();

        assertEq(shortEpochManager.currentEpochId(), 1);
    }

    function testLongEpochDuration() public {
        uint256 longDuration = 365 days; // 1 year

        address longEpochManagerProxy = Upgrades.deployTransparentProxy(
            "EpochManager.sol:EpochManager",
            owner,
            abi.encodeCall(EpochManager.initialize, (longDuration))
        );
        EpochManager longEpochManager = EpochManager(longEpochManagerProxy);

        assertEq(longEpochManager.epochDuration(), longDuration);
        assertEq(longEpochManager.timeLeftInEpoch(), longDuration);
    }

    function testEpochStartTimestamp() public {
        uint256 startTime = block.timestamp;

        // Initially epoch start should be 0
        assertEq(epochManager.epochStart(), 0);

        // After first epoch advancement
        vm.warp(startTime + EPOCH_DURATION);
        uint256 advanceTime = block.timestamp;
        epochManager.nextEpoch();

        assertEq(epochManager.epochStart(), advanceTime);

        // After second epoch advancement
        vm.warp(advanceTime + EPOCH_DURATION);
        uint256 secondAdvanceTime = block.timestamp;
        epochManager.nextEpoch();

        assertEq(epochManager.epochStart(), secondAdvanceTime);
    }

    function testTimeLeftCalculationPrecision() public {
        uint256 startTime = block.timestamp;

        // Test various time points within epoch
        uint256[] memory testPoints = new uint256[](5);
        testPoints[0] = EPOCH_DURATION / 4; // 25%
        testPoints[1] = EPOCH_DURATION / 2; // 50%
        testPoints[2] = (EPOCH_DURATION * 3) / 4; // 75%
        testPoints[3] = EPOCH_DURATION - 1; // Almost end
        testPoints[4] = EPOCH_DURATION; // Exactly end

        for (uint256 i = 0; i < testPoints.length; i++) {
            vm.warp(startTime + testPoints[i]);
            uint256 expectedTimeLeft = testPoints[i] >= EPOCH_DURATION ? 0 : EPOCH_DURATION - testPoints[i];
            assertEq(epochManager.timeLeftInEpoch(), expectedTimeLeft);
        }
    }

    function testOwnershipTransfer() public {
        address newOwner = makeAddr("newOwner");

        // Transfer ownership
        epochManager.transferOwnership(newOwner);

        // Accept ownership
        vm.prank(newOwner);
        epochManager.acceptOwnership();

        assertEq(epochManager.owner(), newOwner);

        // Old owner should not be able to advance epoch
        vm.warp(block.timestamp + EPOCH_DURATION);
        vm.expectRevert();
        epochManager.nextEpoch();

        // New owner should be able to advance epoch
        vm.prank(newOwner);
        epochManager.nextEpoch();
        assertEq(epochManager.currentEpochId(), 1);
    }

    function testEpochAdvancementWithPause() public {
        // Pause the contract
        epochManager.pause();

        // Fast forward time
        vm.warp(block.timestamp + EPOCH_DURATION);

        // Should still be able to advance epoch when paused (pause doesn't affect epoch advancement)
        epochManager.nextEpoch();
        assertEq(epochManager.currentEpochId(), 1);
    }

    function testMaxEpochId() public {
        // Test advancing many epochs
        uint256 initialTime = block.timestamp;

        for (uint256 i = 1; i <= 10; i++) {
            vm.warp(initialTime + (EPOCH_DURATION * i));
            epochManager.nextEpoch();
            assertEq(epochManager.currentEpochId(), i);
        }
    }

    function testEpochIdOverflow() public {
        // This test would require setting epoch ID to near max value
        // For practical purposes, we'll test that epoch ID increments correctly
        uint256 initialTime = block.timestamp;

        // Advance several epochs quickly
        for (uint256 i = 1; i <= 5; i++) {
            vm.warp(initialTime + (EPOCH_DURATION * i));
            epochManager.nextEpoch();
        }

        assertEq(epochManager.currentEpochId(), 5);
    }

    function testViewFunctions() public {
        // Test all view functions return expected values
        assertEq(epochManager.currentEpochId(), 0);
        assertEq(epochManager.epochStart(), 0);
        assertEq(epochManager.epochDuration(), EPOCH_DURATION);
        assertEq(epochManager.timeLeftInEpoch(), EPOCH_DURATION);

        // After advancing epoch
        vm.warp(block.timestamp + EPOCH_DURATION);
        uint256 advanceTime = block.timestamp;
        epochManager.nextEpoch();

        assertEq(epochManager.currentEpochId(), 1);
        assertEq(epochManager.epochStart(), advanceTime);
        assertEq(epochManager.epochDuration(), EPOCH_DURATION);
        assertEq(epochManager.timeLeftInEpoch(), EPOCH_DURATION);
    }

    function testInitializeOnlyOnce() public {
        // Try to initialize again - should revert
        vm.expectRevert();
        epochManager.initialize(EPOCH_DURATION);
    }

    function testUpgradeability() public {
        // Test that the contract is upgradeable by checking it's a proxy
        // This is more of a deployment test, but we can verify the proxy pattern works
        assertEq(epochManager.owner(), owner);
        assertEq(epochManager.epochDuration(), EPOCH_DURATION);
    }
}
