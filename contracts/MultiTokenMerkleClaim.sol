// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/cryptography/MerkleProof.sol";

/// @title AlcumMultiTokenMerkleClaim
/// @dev This contract allows users to claim ERC20 tokens based on a Merkle proof. It supports multiple
/// Merkle roots for the same token, enabling periodic claim events. Users can claim
/// their allocated tokens for each Merkle root by providing a valid proof.
contract AlcumMultiTokenMerkleClaim is Initializable, OwnableUpgradeable, AccessControlUpgradeable, UUPSUpgradeable {
    using SafeERC20 for IERC20;

    bytes32 public constant PUBLISHER_ROLE = keccak256("PUBLISHER_ROLE");

    event MerkleRootAdded(address indexed token, bytes32 indexed root);
    event TokensClaimed(address indexed user, address indexed token, uint256 amount, bytes32 indexed merkleRoot);

    mapping(address => bytes32[]) public merkleRoots;
    mapping(address => mapping(bytes32 => bool)) public isKnownRoot;
    address[] public tokenList;

    /// @dev Mapping to track claimed amount by user, token and merkle root.
    mapping(address => mapping(address => mapping(bytes32 => uint256))) public claimed;

    function initialize() public initializer {
        __Ownable_init(msg.sender);
        __AccessControl_init();
        __UUPSUpgradeable_init();
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(PUBLISHER_ROLE, msg.sender);
    }

    function _authorizeUpgrade(address newImplementation) internal override onlyOwner {}

    function addMerkleRoot(address token, bytes32 root) external onlyRole(PUBLISHER_ROLE) {
        require(token != address(0), "Token is zero address.");
        require(root != bytes32(0), "Root is zero.");
        if (merkleRoots[token].length == 0) {
            tokenList.push(token);
        }
        require(!isKnownRoot[token][root], "Root already exists.");
        merkleRoots[token].push(root);
        isKnownRoot[token][root] = true;
        emit MerkleRootAdded(token, root);
    }

    function getMerkleRoots(address token) external view returns (bytes32[] memory) {
        return merkleRoots[token];
    }

    /// @dev Claim by scanning all roots for a valid proof (convenience overload).
    function claim(address token, uint256 totalAmount, bytes32[] calldata proof) external returns (uint256) {
        bytes32 leaf = keccak256(abi.encodePacked(msg.sender, totalAmount));

        bool valid = false;
        bytes32 usedRoot;
        for (uint256 i = 0; i < merkleRoots[token].length; i++) {
            if (MerkleProof.verify(proof, merkleRoots[token][i], leaf)) {
                usedRoot = merkleRoots[token][i];
                valid = true;
                break;
            }
        }
        require(valid, "Invalid proof.");
        return _claimForRoot(token, usedRoot, totalAmount);
    }

    /// @dev Claim against a specific merkle root (preferred — skips iteration).
    function claim(
        address token,
        bytes32 merkleRoot,
        uint256 totalAmount,
        bytes32[] calldata proof
    ) external returns (uint256) {
        require(isKnownRoot[token][merkleRoot], "Unknown merkle root.");
        bytes32 leaf = keccak256(abi.encodePacked(msg.sender, totalAmount));
        require(MerkleProof.verify(proof, merkleRoot, leaf), "Invalid proof.");
        return _claimForRoot(token, merkleRoot, totalAmount);
    }

    function _claimForRoot(address token, bytes32 usedRoot, uint256 totalAmount) internal returns (uint256) {
        uint256 claimedAmount = claimed[msg.sender][token][usedRoot];
        require(claimedAmount < totalAmount, "All tokens already claimed for this Merkle root.");

        uint256 amountToClaim = totalAmount - claimedAmount;
        claimed[msg.sender][token][usedRoot] += amountToClaim;

        IERC20(token).safeTransfer(msg.sender, amountToClaim);
        emit TokensClaimed(msg.sender, token, amountToClaim, usedRoot);
        return amountToClaim;
    }

    /// @dev Returns the total amount claimed by a user for a specific token across all Merkle roots.
    function getTotalClaimedForToken(address user, address token) external view returns (uint256) {
        uint256 totalClaimedAmount = 0;
        for (uint256 i = 0; i < merkleRoots[token].length; i++) {
            totalClaimedAmount += claimed[user][token][merkleRoots[token][i]];
        }
        return totalClaimedAmount;
    }

    function getTotalClaimedForAllTokens(address user) external view returns (uint256) {
        uint256 total = 0;
        for (uint256 i = 0; i < tokenList.length; i++) {
            address token = tokenList[i];
            for (uint256 j = 0; j < merkleRoots[token].length; j++) {
                total += claimed[user][token][merkleRoots[token][j]];
            }
        }
        return total;
    }

    function getClaimedForTokenAndRoot(
        address user,
        address token,
        bytes32 merkleRoot
    ) external view returns (uint256) {
        return claimed[user][token][merkleRoot];
    }

    function withdraw(address token, address recipient) external onlyOwner {
        uint256 balance = IERC20(token).balanceOf(address(this));
        IERC20(token).safeTransfer(recipient, balance);
    }
}
