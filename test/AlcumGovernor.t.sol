// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test, console} from "forge-std/Test.sol";
import {AlcumGovernor} from "../contracts/AlcumGovernor.sol";
import {GovernanceToken} from "../contracts/GovernanceToken.sol";
import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";
import {IGovernor} from "@openzeppelin/contracts/governance/IGovernor.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

contract AlcumGovernorTest is Test {
    AlcumGovernor public governor;
    GovernanceToken public token;
    TimelockController public timelock;
    address public proposer;
    address public executor;
    address public voter1;
    address public voter2;
    address public target;

    uint48 constant VOTING_DELAY = 1;
    uint32 constant VOTING_PERIOD = 50400; // ~1 week
    uint256 constant PROPOSAL_THRESHOLD = 5000 * 10 ** 18; // 0.5% of 1M tokens
    uint256 constant QUORUM_NUMERATOR = 4; // 4% (OpenZeppelin uses percentage with denominator 100)

    function setUp() public {
        proposer = makeAddr("proposer");
        executor = makeAddr("executor");
        voter1 = makeAddr("voter1");
        voter2 = makeAddr("voter2");
        target = makeAddr("target");

        // Deploy governance token
        token = new GovernanceToken("Governance Token", "GOV", address(this));

        // Setup timelock roles
        address[] memory proposers = new address[](1);
        proposers[0] = address(this); // Governor will be proposer
        address[] memory executors = new address[](1);
        executors[0] = address(0); // Anyone can execute

        // Deploy TimelockController
        timelock = new TimelockController(1 days, proposers, executors, address(this));

        // Deploy Governor as upgradeable proxy
        AlcumGovernor implementation = new AlcumGovernor();
        bytes memory initData = abi.encodeWithSelector(
            AlcumGovernor.initialize.selector,
            token,
            timelock,
            "Alcum Governor",
            VOTING_DELAY,
            VOTING_PERIOD,
            PROPOSAL_THRESHOLD,
            QUORUM_NUMERATOR,
            address(this) // initialOwner
        );
        ERC1967Proxy proxy = new ERC1967Proxy(address(implementation), initData);
        governor = AlcumGovernor(payable(address(proxy)));

        // Grant proposer role to governor
        timelock.grantRole(timelock.PROPOSER_ROLE(), address(governor));
        timelock.grantRole(timelock.EXECUTOR_ROLE(), address(0)); // Anyone can execute

        // Mint tokens to voters - proposer needs at least PROPOSAL_THRESHOLD
        uint256 voterAmount = 100000 * 10 ** 18; // 100k tokens each
        uint256 proposerAmount = PROPOSAL_THRESHOLD + 1000 * 10 ** 18; // Above threshold
        token.mint(voter1, voterAmount);
        token.mint(voter2, voterAmount);
        token.mint(proposer, proposerAmount);

        // Delegate votes
        vm.prank(voter1);
        token.delegate(voter1);
        vm.prank(voter2);
        token.delegate(voter2);
        vm.prank(proposer);
        token.delegate(proposer);

        // Move to next block so voting power is updated
        vm.roll(block.number + 1);
    }

    function testInitialization() public {
        assertEq(governor.name(), "Alcum Governor");
        assertEq(governor.votingDelay(), VOTING_DELAY);
        assertEq(governor.votingPeriod(), VOTING_PERIOD);
        assertEq(governor.proposalThreshold(), PROPOSAL_THRESHOLD);
        assertEq(governor.quorumNumerator(), QUORUM_NUMERATOR);
        assertEq(address(governor.token()), address(token));
        assertEq(address(governor.timelock()), address(timelock));
    }

    function testPropose() public {
        address[] memory targets = new address[](1);
        targets[0] = target;
        uint256[] memory values = new uint256[](1);
        values[0] = 0;
        bytes[] memory calldatas = new bytes[](1);
        calldatas[0] = abi.encodeWithSignature("test()");
        string memory description = "Test proposal";

        vm.prank(proposer);
        uint256 proposalId = governor.propose(targets, values, calldatas, description);

        assertGt(proposalId, 0);
        assertEq(governor.proposalCount(), 1);
    }

    function testProposeWithoutThreshold() public {
        address lowBalance = makeAddr("lowBalance");
        token.mint(lowBalance, 1000 * 10 ** 18); // Below threshold
        vm.prank(lowBalance);
        token.delegate(lowBalance);

        address[] memory targets = new address[](1);
        targets[0] = target;
        uint256[] memory values = new uint256[](1);
        values[0] = 0;
        bytes[] memory calldatas = new bytes[](1);
        calldatas[0] = abi.encodeWithSignature("test()");
        string memory description = "Test proposal";

        vm.prank(lowBalance);
        vm.expectRevert();
        governor.propose(targets, values, calldatas, description);
    }

    function testProposalState() public {
        address[] memory targets = new address[](1);
        targets[0] = target;
        uint256[] memory values = new uint256[](1);
        values[0] = 0;
        bytes[] memory calldatas = new bytes[](1);
        calldatas[0] = abi.encodeWithSignature("test()");
        string memory description = "Test proposal";

        vm.prank(proposer);
        uint256 proposalId = governor.propose(targets, values, calldatas, description);

        // Should be Pending initially
        assertEq(uint8(governor.state(proposalId)), uint8(IGovernor.ProposalState.Pending));

        // Move forward voting delay
        vm.roll(block.number + VOTING_DELAY + 1);

        // Should be Active
        assertEq(uint8(governor.state(proposalId)), uint8(IGovernor.ProposalState.Active));
    }

    function testCastVote() public {
        address[] memory targets = new address[](1);
        targets[0] = target;
        uint256[] memory values = new uint256[](1);
        values[0] = 0;
        bytes[] memory calldatas = new bytes[](1);
        calldatas[0] = abi.encodeWithSignature("test()");
        string memory description = "Test proposal";

        vm.prank(proposer);
        uint256 proposalId = governor.propose(targets, values, calldatas, description);

        vm.roll(block.number + VOTING_DELAY + 1);

        vm.prank(voter1);
        uint256 weight = governor.castVote(proposalId, 1); // Vote For

        assertGt(weight, 0);
        assertTrue(governor.hasVoted(proposalId, voter1));
    }

    function testCastVoteWithReason() public {
        address[] memory targets = new address[](1);
        targets[0] = target;
        uint256[] memory values = new uint256[](1);
        values[0] = 0;
        bytes[] memory calldatas = new bytes[](1);
        calldatas[0] = abi.encodeWithSignature("test()");
        string memory description = "Test proposal";

        vm.prank(proposer);
        uint256 proposalId = governor.propose(targets, values, calldatas, description);

        vm.roll(block.number + VOTING_DELAY + 1);

        vm.prank(voter1);
        uint256 weight = governor.castVoteWithReason(proposalId, 1, "I support this proposal");

        assertGt(weight, 0);
        assertTrue(governor.hasVoted(proposalId, voter1));
    }

    function testGetVoteReceipt() public {
        address[] memory targets = new address[](1);
        targets[0] = target;
        uint256[] memory values = new uint256[](1);
        values[0] = 0;
        bytes[] memory calldatas = new bytes[](1);
        calldatas[0] = abi.encodeWithSignature("test()");
        string memory description = "Test proposal";

        vm.prank(proposer);
        uint256 proposalId = governor.propose(targets, values, calldatas, description);

        vm.roll(block.number + VOTING_DELAY + 1);

        vm.prank(voter1);
        governor.castVote(proposalId, 1);

        AlcumGovernor.VoteReceipt memory receipt = governor.getVoteReceipt(proposalId, voter1);
        assertTrue(receipt.hasVoted);
        assertEq(receipt.support, 1);
        assertGt(receipt.votes, 0);
    }

    function testGetVoteReceiptNotVoted() public {
        address[] memory targets = new address[](1);
        targets[0] = target;
        uint256[] memory values = new uint256[](1);
        values[0] = 0;
        bytes[] memory calldatas = new bytes[](1);
        calldatas[0] = abi.encodeWithSignature("test()");
        string memory description = "Test proposal";

        vm.prank(proposer);
        uint256 proposalId = governor.propose(targets, values, calldatas, description);

        AlcumGovernor.VoteReceipt memory receipt = governor.getVoteReceipt(proposalId, voter1);
        assertFalse(receipt.hasVoted);
        assertEq(receipt.support, 0);
        assertEq(receipt.votes, 0);
    }

    function testGetProposals() public {
        address[] memory targets = new address[](1);
        targets[0] = target;
        uint256[] memory values = new uint256[](1);
        values[0] = 0;
        bytes[] memory calldatas = new bytes[](1);
        calldatas[0] = abi.encodeWithSignature("test()");
        string memory description = "Test proposal";

        vm.prank(proposer);
        uint256 proposalId1 = governor.propose(targets, values, calldatas, description);

        vm.roll(block.number + VOTING_PERIOD + 10);

        vm.prank(proposer);
        uint256 proposalId2 = governor.propose(targets, values, calldatas, "Second proposal");

        (AlcumGovernor.ProposalInfo[] memory proposals, uint256 totalCount) = governor.getProposals(0, 10);
        assertEq(totalCount, 2);
        assertEq(proposals.length, 2);
        assertEq(proposals[0].id, proposalId1);
        assertEq(proposals[1].id, proposalId2);
    }

    function testGetAllProposals() public {
        address[] memory targets = new address[](1);
        targets[0] = target;
        uint256[] memory values = new uint256[](1);
        values[0] = 0;
        bytes[] memory calldatas = new bytes[](1);
        calldatas[0] = abi.encodeWithSignature("test()");
        string memory description = "Test proposal";

        vm.prank(proposer);
        governor.propose(targets, values, calldatas, description);

        vm.prank(proposer);
        governor.propose(targets, values, calldatas, "Second proposal");

        AlcumGovernor.ProposalInfo[] memory proposals = governor.getAllProposals();
        assertEq(proposals.length, 2);
    }

    function testStateBatch() public {
        address[] memory targets = new address[](1);
        targets[0] = target;
        uint256[] memory values = new uint256[](1);
        values[0] = 0;
        bytes[] memory calldatas = new bytes[](1);
        calldatas[0] = abi.encodeWithSignature("test()");
        string memory description = "Test proposal";

        vm.prank(proposer);
        uint256 proposalId1 = governor.propose(targets, values, calldatas, description);

        vm.roll(block.number + VOTING_PERIOD + 10);

        vm.prank(proposer);
        uint256 proposalId2 = governor.propose(targets, values, calldatas, "Second proposal");

        uint256[] memory proposalIds = new uint256[](2);
        proposalIds[0] = proposalId1;
        proposalIds[1] = proposalId2;

        IGovernor.ProposalState[] memory states = governor.stateBatch(proposalIds);
        assertEq(states.length, 2);
    }

    function testQuorum() public {
        // Need to use a past block number for quorum calculation
        vm.roll(block.number + 1);
        uint256 pastBlock = block.number - 1;
        uint256 quorumAmount = governor.quorum(pastBlock);

        // Quorum should be 4% of total supply at that block
        uint256 totalSupply = token.totalSupply();
        uint256 expectedQuorum = (totalSupply * QUORUM_NUMERATOR) / 100;
        assertEq(quorumAmount, expectedQuorum);
    }

    function testProposalCount() public {
        assertEq(governor.proposalCount(), 0);

        address[] memory targets = new address[](1);
        targets[0] = target;
        uint256[] memory values = new uint256[](1);
        values[0] = 0;
        bytes[] memory calldatas = new bytes[](1);
        calldatas[0] = abi.encodeWithSignature("test()");
        string memory description = "Test proposal";

        vm.prank(proposer);
        governor.propose(targets, values, calldatas, description);

        assertEq(governor.proposalCount(), 1);
    }

    function testVotingDelay() public {
        assertEq(governor.votingDelay(), VOTING_DELAY);
    }

    function testVotingPeriod() public {
        assertEq(governor.votingPeriod(), VOTING_PERIOD);
    }

    function testProposalThreshold() public {
        assertEq(governor.proposalThreshold(), PROPOSAL_THRESHOLD);
    }

    function testMultipleVotes() public {
        address[] memory targets = new address[](1);
        targets[0] = target;
        uint256[] memory values = new uint256[](1);
        values[0] = 0;
        bytes[] memory calldatas = new bytes[](1);
        calldatas[0] = abi.encodeWithSignature("test()");
        string memory description = "Test proposal";

        vm.prank(proposer);
        uint256 proposalId = governor.propose(targets, values, calldatas, description);

        vm.roll(block.number + VOTING_DELAY + 1);

        vm.prank(voter1);
        governor.castVote(proposalId, 1); // For

        vm.prank(voter2);
        governor.castVote(proposalId, 0); // Against

        assertTrue(governor.hasVoted(proposalId, voter1));
        assertTrue(governor.hasVoted(proposalId, voter2));
    }

    function testAbstainVote() public {
        address[] memory targets = new address[](1);
        targets[0] = target;
        uint256[] memory values = new uint256[](1);
        values[0] = 0;
        bytes[] memory calldatas = new bytes[](1);
        calldatas[0] = abi.encodeWithSignature("test()");
        string memory description = "Test proposal";

        vm.prank(proposer);
        uint256 proposalId = governor.propose(targets, values, calldatas, description);

        vm.roll(block.number + VOTING_DELAY + 1);

        vm.prank(voter1);
        governor.castVote(proposalId, 2); // Abstain

        AlcumGovernor.VoteReceipt memory receipt = governor.getVoteReceipt(proposalId, voter1);
        assertTrue(receipt.hasVoted);
        assertEq(receipt.support, 2);
    }

    function testProposalNeedsQueuing() public {
        address[] memory targets = new address[](1);
        targets[0] = target;
        uint256[] memory values = new uint256[](1);
        values[0] = 0;
        bytes[] memory calldatas = new bytes[](1);
        calldatas[0] = abi.encodeWithSignature("test()");
        string memory description = "Test proposal";

        vm.prank(proposer);
        uint256 proposalId = governor.propose(targets, values, calldatas, description);

        // With TimelockControl, proposals always need queuing (returns true)
        // This is because all proposals go through timelock
        bool needsQueuing1 = governor.proposalNeedsQueuing(proposalId);
        assertTrue(needsQueuing1);

        vm.roll(block.number + VOTING_DELAY + 1);

        // Still needs queuing (active state)
        bool needsQueuing2 = governor.proposalNeedsQueuing(proposalId);
        assertTrue(needsQueuing2);
    }

    function testGetProposalsWithPagination() public {
        address[] memory targets = new address[](1);
        targets[0] = target;
        uint256[] memory values = new uint256[](1);
        values[0] = 0;
        bytes[] memory calldatas = new bytes[](1);
        calldatas[0] = abi.encodeWithSignature("test()");
        string memory description = "Test proposal";

        // Create 3 proposals
        vm.prank(proposer);
        governor.propose(targets, values, calldatas, description);

        vm.roll(block.number + VOTING_PERIOD + 10);

        vm.prank(proposer);
        governor.propose(targets, values, calldatas, "Second proposal");

        vm.roll(block.number + VOTING_PERIOD + 10);

        vm.prank(proposer);
        governor.propose(targets, values, calldatas, "Third proposal");

        // Test pagination
        (AlcumGovernor.ProposalInfo[] memory proposals1, uint256 totalCount1) = governor.getProposals(0, 2);
        assertEq(totalCount1, 3);
        assertEq(proposals1.length, 2);

        (AlcumGovernor.ProposalInfo[] memory proposals2, uint256 totalCount2) = governor.getProposals(2, 2);
        assertEq(totalCount2, 3);
        assertEq(proposals2.length, 1);

        // Test offset beyond total
        (AlcumGovernor.ProposalInfo[] memory proposals3, uint256 totalCount3) = governor.getProposals(10, 10);
        assertEq(totalCount3, 3);
        assertEq(proposals3.length, 0);
    }

    function testGetProposalsEmpty() public {
        (AlcumGovernor.ProposalInfo[] memory proposals, uint256 totalCount) = governor.getProposals(0, 10);
        assertEq(totalCount, 0);
        assertEq(proposals.length, 0);
    }
}
