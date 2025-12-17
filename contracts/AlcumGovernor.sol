// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {GovernorUpgradeable} from "@openzeppelin/contracts-upgradeable/governance/GovernorUpgradeable.sol";
import {
    GovernorSettingsUpgradeable
} from "@openzeppelin/contracts-upgradeable/governance/extensions/GovernorSettingsUpgradeable.sol";
import {
    GovernorCountingSimpleUpgradeable
} from "@openzeppelin/contracts-upgradeable/governance/extensions/GovernorCountingSimpleUpgradeable.sol";
import {
    GovernorVotesUpgradeable
} from "@openzeppelin/contracts-upgradeable/governance/extensions/GovernorVotesUpgradeable.sol";
import {
    GovernorVotesQuorumFractionUpgradeable
} from "@openzeppelin/contracts-upgradeable/governance/extensions/GovernorVotesQuorumFractionUpgradeable.sol";
import {
    GovernorTimelockControlUpgradeable
} from "@openzeppelin/contracts-upgradeable/governance/extensions/GovernorTimelockControlUpgradeable.sol";
import {
    TimelockControllerUpgradeable
} from "@openzeppelin/contracts-upgradeable/governance/TimelockControllerUpgradeable.sol";
import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";
import {IVotes} from "@openzeppelin/contracts/governance/utils/IVotes.sol";
import {IGovernor} from "@openzeppelin/contracts/governance/IGovernor.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";

/**
 * @title AlcumGovernor
 * @notice Upgradeable OpenZeppelin Governor implementation for DAO governance
 * @dev This contract implements a complete governance system with:
 *      - Voting delay and period configuration
 *      - Proposal threshold
 *      - Simple majority voting
 *      - Quorum requirements
 *      - Timelock for proposal execution
 *      - UUPS upgradeable pattern
 *
 *      Standard configuration:
 *      - Voting delay: 1 block (proposals can be voted on immediately)
 *      - Voting period: 50400 blocks (~1 week at 12s/block)
 *      - Proposal threshold: 0.5% of total supply
 *      - Quorum: 4% of total supply
 *      - Timelock delay: 1 day (86400 seconds)
 */
contract AlcumGovernor is
    Initializable,
    OwnableUpgradeable,
    UUPSUpgradeable,
    GovernorUpgradeable,
    GovernorSettingsUpgradeable,
    GovernorCountingSimpleUpgradeable,
    GovernorVotesUpgradeable,
    GovernorVotesQuorumFractionUpgradeable,
    GovernorTimelockControlUpgradeable
{
    /// @notice Structure for proposal information
    struct ProposalInfo {
        uint256 id;
        address proposer;
        uint256 voteStart;
        uint256 voteEnd;
        uint256 eta;
        ProposalState state;
    }

    /// @notice Structure for vote receipt information
    struct VoteReceipt {
        bool hasVoted;
        uint8 support; // 0 = Against, 1 = For, 2 = Abstain
        uint256 votes;
    }

    /// @notice Array of all proposal IDs
    uint256[] private _proposalIds;

    /// @notice Mapping from proposal ID to its index in _proposalIds array
    mapping(uint256 => uint256) private _proposalIndex;

    /// @notice Mapping from proposal ID to proposer address
    mapping(uint256 => address) private _proposalProposers;

    /// @notice Mapping from proposal ID to description hash
    mapping(uint256 => bytes32) private _proposalDescriptionHashes;

    /// @notice Mapping from (proposalId, voter) to vote support (0 = Against, 1 = For, 2 = Abstain)
    mapping(uint256 => mapping(address => uint8)) private _voteSupport;

    /// @notice Reserve storage gap for future upgrades
    uint256[50] private __gap;

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        // Disable initialization in constructor
        _disableInitializers();
    }

    /**
     * @notice Initializes the AlcumGovernor contract
     * @param token_ The governance token contract (must implement IVotes)
     * @param timelock_ The TimelockController contract for delayed execution
     * @param name_ The name of the governance contract
     * @param votingDelay_ The delay in blocks before voting starts (1 block = immediate)
     * @param votingPeriod_ The duration in blocks for voting (50400 blocks ≈ 1 week)
     * @param proposalThreshold_ The minimum token amount required to create a proposal
     * @param quorumNumerator_ The quorum as a fraction of total supply (basis points, e.g., 400 = 4%)
     * @param initialOwner The address that will own the contract (can upgrade)
     */
    function initialize(
        IVotes token_,
        TimelockController timelock_,
        string memory name_,
        uint48 votingDelay_,
        uint32 votingPeriod_,
        uint256 proposalThreshold_,
        uint256 quorumNumerator_,
        address initialOwner
    ) public initializer {
        __Ownable_init(initialOwner);
        __UUPSUpgradeable_init();
        __Governor_init(name_);
        __GovernorSettings_init(votingDelay_, votingPeriod_, proposalThreshold_);
        __GovernorVotes_init(token_);
        __GovernorVotesQuorumFraction_init(quorumNumerator_);
        __GovernorTimelockControl_init(TimelockControllerUpgradeable(payable(address(timelock_))));
    }

    /**
     * @notice Authorizes an upgrade (only owner)
     * @dev Required by UUPSUpgradeable
     * @param newImplementation The address of the new implementation
     */
    function _authorizeUpgrade(address newImplementation) internal override onlyOwner {}

    /**
     * @notice The voting delay in blocks
     * @return The number of blocks before voting can start
     */
    function votingDelay() public view override(GovernorUpgradeable, GovernorSettingsUpgradeable) returns (uint256) {
        return super.votingDelay();
    }

    /**
     * @notice The voting period in blocks
     * @return The number of blocks during which voting is active
     */
    function votingPeriod() public view override(GovernorUpgradeable, GovernorSettingsUpgradeable) returns (uint256) {
        return super.votingPeriod();
    }

    /**
     * @notice The minimum token amount required to create a proposal
     * @return The proposal threshold in token units
     */
    function proposalThreshold()
        public
        view
        override(GovernorUpgradeable, GovernorSettingsUpgradeable)
        returns (uint256)
    {
        return super.proposalThreshold();
    }

    /**
     * @notice Returns the quorum required for a proposal to pass
     * @param blockNumber The block number to check quorum at
     * @return The quorum amount in token units
     */
    function quorum(
        uint256 blockNumber
    ) public view override(GovernorUpgradeable, GovernorVotesQuorumFractionUpgradeable) returns (uint256) {
        return super.quorum(blockNumber);
    }

    /**
     * @notice Returns the state of a proposal
     * @param proposalId The unique identifier of the proposal
     * @return The current state of the proposal
     */
    function state(
        uint256 proposalId
    ) public view override(GovernorUpgradeable, GovernorTimelockControlUpgradeable) returns (ProposalState) {
        return super.state(proposalId);
    }

    /**
     * @notice Creates a new proposal
     * @param targets The addresses of contracts to call
     * @param values The amounts of ETH to send with each call
     * @param calldatas The calldata for each call
     * @param description The human-readable description of the proposal
     * @return proposalId The unique identifier of the created proposal
     */
    function propose(
        address[] memory targets,
        uint256[] memory values,
        bytes[] memory calldatas,
        string memory description
    ) public override(GovernorUpgradeable) returns (uint256) {
        bytes32 descriptionHash = keccak256(bytes(description));
        uint256 proposalId = super.propose(targets, values, calldatas, description);

        // Track proposal ID and metadata
        _proposalIndex[proposalId] = _proposalIds.length;
        _proposalIds.push(proposalId);
        _proposalProposers[proposalId] = msg.sender;
        _proposalDescriptionHashes[proposalId] = descriptionHash;

        return proposalId;
    }

    /**
     * @notice Queues operations for execution through Timelock
     * @param targets The addresses of contracts to call
     * @param values The amounts of ETH to send with each call
     * @param calldatas The calldata for each call
     * @param descriptionHash The hash of the proposal description
     * @return The operation ID
     */
    function _queueOperations(
        uint256 proposalId,
        address[] memory targets,
        uint256[] memory values,
        bytes[] memory calldatas,
        bytes32 descriptionHash
    ) internal override(GovernorUpgradeable, GovernorTimelockControlUpgradeable) returns (uint48) {
        return super._queueOperations(proposalId, targets, values, calldatas, descriptionHash);
    }

    /**
     * @notice Executes operations through Timelock
     * @param targets The addresses of contracts to call
     * @param values The amounts of ETH to send with each call
     * @param calldatas The calldata for each call
     * @param descriptionHash The hash of the proposal description
     */
    function _executeOperations(
        uint256 proposalId,
        address[] memory targets,
        uint256[] memory values,
        bytes[] memory calldatas,
        bytes32 descriptionHash
    ) internal override(GovernorUpgradeable, GovernorTimelockControlUpgradeable) {
        super._executeOperations(proposalId, targets, values, calldatas, descriptionHash);
    }

    /**
     * @notice Checks if a proposal needs queuing
     * @param proposalId The unique identifier of the proposal
     * @return Whether the proposal needs queuing
     */
    function proposalNeedsQueuing(
        uint256 proposalId
    ) public view override(GovernorUpgradeable, GovernorTimelockControlUpgradeable) returns (bool) {
        return super.proposalNeedsQueuing(proposalId);
    }

    /**
     * @notice Cancels a proposal
     * @param targets The addresses of contracts to call
     * @param values The amounts of ETH to send with each call
     * @param calldatas The calldata for each call
     * @param descriptionHash The hash of the proposal description
     * @return proposalId The unique identifier of the cancelled proposal
     */
    function _cancel(
        address[] memory targets,
        uint256[] memory values,
        bytes[] memory calldatas,
        bytes32 descriptionHash
    ) internal override(GovernorUpgradeable, GovernorTimelockControlUpgradeable) returns (uint256) {
        return super._cancel(targets, values, calldatas, descriptionHash);
    }

    /**
     * @notice Returns the executor address for proposals
     * @return The address that executes proposals (TimelockController)
     */
    function _executor()
        internal
        view
        override(GovernorUpgradeable, GovernorTimelockControlUpgradeable)
        returns (address)
    {
        return super._executor();
    }

    /**
     * @notice Returns a paginated list of proposals
     * @param offset The starting index (0-based)
     * @param limit The maximum number of proposals to return
     * @return proposals Array of ProposalInfo structures
     * @return totalCount Total number of proposals
     */
    function getProposals(
        uint256 offset,
        uint256 limit
    ) external view returns (ProposalInfo[] memory proposals, uint256 totalCount) {
        totalCount = _proposalIds.length;

        if (offset >= totalCount) {
            return (new ProposalInfo[](0), totalCount);
        }

        uint256 end = offset + limit;
        if (end > totalCount) {
            end = totalCount;
        }

        uint256 length = end - offset;
        proposals = new ProposalInfo[](length);

        for (uint256 i = 0; i < length; i++) {
            uint256 proposalId = _proposalIds[offset + i];
            proposals[i] = _getProposalInfo(proposalId);
        }
    }

    /**
     * @notice Returns all proposals (use with caution for large numbers of proposals)
     * @return proposals Array of all ProposalInfo structures
     */
    function getAllProposals() external view returns (ProposalInfo[] memory proposals) {
        uint256 length = _proposalIds.length;
        proposals = new ProposalInfo[](length);

        for (uint256 i = 0; i < length; i++) {
            proposals[i] = _getProposalInfo(_proposalIds[i]);
        }
    }

    /**
     * @notice Returns vote receipt information for a specific voter on a proposal
     * @param proposalId The unique identifier of the proposal
     * @param voter The address of the voter
     * @return receipt VoteReceipt structure containing vote information
     */
    function getVoteReceipt(uint256 proposalId, address voter) external view returns (VoteReceipt memory receipt) {
        receipt.hasVoted = hasVoted(proposalId, voter);

        if (receipt.hasVoted) {
            // Get vote weight (voting power at the time of voting)
            uint256 snapshot = proposalSnapshot(proposalId);
            IVotes voteToken = token();
            receipt.votes = voteToken.getPastVotes(voter, snapshot);

            // Get vote support from our tracking mapping
            receipt.support = _voteSupport[proposalId][voter];
        } else {
            receipt.votes = 0;
            receipt.support = 0;
        }
    }

    /**
     * @notice Cast a vote on a proposal
     * @param proposalId The unique identifier of the proposal
     * @param support The vote choice (0 = Against, 1 = For, 2 = Abstain)
     * @return weight The voting weight used
     */
    function castVote(uint256 proposalId, uint8 support) public override(GovernorUpgradeable) returns (uint256) {
        uint256 weight = super.castVote(proposalId, support);

        // Track vote support for getVoteReceipt
        _voteSupport[proposalId][msg.sender] = support;

        return weight;
    }

    /**
     * @notice Cast a vote with a reason
     * @param proposalId The unique identifier of the proposal
     * @param support The vote choice (0 = Against, 1 = For, 2 = Abstain)
     * @param reason The reason for the vote
     * @return weight The voting weight used
     */
    function castVoteWithReason(
        uint256 proposalId,
        uint8 support,
        string calldata reason
    ) public override(GovernorUpgradeable) returns (uint256) {
        uint256 weight = super.castVoteWithReason(proposalId, support, reason);

        // Track vote support for getVoteReceipt
        _voteSupport[proposalId][msg.sender] = support;

        return weight;
    }

    /**
     * @notice Returns states for multiple proposals in a single call
     * @param proposalIds Array of proposal IDs to query
     * @return states Array of ProposalState corresponding to each proposal ID
     */
    function stateBatch(uint256[] calldata proposalIds) external view returns (ProposalState[] memory states) {
        states = new ProposalState[](proposalIds.length);

        for (uint256 i = 0; i < proposalIds.length; i++) {
            states[i] = state(proposalIds[i]);
        }
    }

    /**
     * @notice Internal helper to get proposal information
     * @param proposalId The unique identifier of the proposal
     * @return info ProposalInfo structure
     */
    function _getProposalInfo(uint256 proposalId) internal view returns (ProposalInfo memory info) {
        info.id = proposalId;
        info.proposer = _proposalProposers[proposalId];
        info.voteStart = proposalSnapshot(proposalId);
        info.voteEnd = proposalDeadline(proposalId);
        info.state = state(proposalId);

        // Get ETA from Timelock if proposal is queued
        if (info.state == ProposalState.Queued) {
            bytes32 descriptionHash = _proposalDescriptionHashes[proposalId];
            // Calculate timelock operation ID
            // Timelock uses a hash of proposalId and descriptionHash as the operation ID
            bytes32 timelockId = keccak256(abi.encode(proposalId, descriptionHash));
            TimelockController timelockContract = TimelockController(payable(timelock()));
            info.eta = timelockContract.getTimestamp(timelockId);
        } else {
            info.eta = 0;
        }
    }

    /**
     * @notice Returns the total number of proposals
     * @return The total count of proposals
     */
    function proposalCount() external view returns (uint256) {
        return _proposalIds.length;
    }
}
