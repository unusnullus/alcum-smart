// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";

import {IERC20} from "@openzeppelin/contracts/interfaces/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/interfaces/IERC20Metadata.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

import {ERC4626} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";

contract xCUP is ERC4626, Ownable, Pausable {
    using SafeERC20 for IERC20;

    IERC20 private _asset;
    
    // Revenue distribution tracking
    mapping(uint256 => uint256) public epochRevenuePerShare;
    mapping(address => uint256) public lastClaimedEpoch;
    uint256 public currentEpochId;
    
    address public settlementEngine;
    
    event RevenueDistributed(uint256 indexed epochId, uint256 revenuePerShare);
    event RevenueClaimed(address indexed user, uint256 epochId, uint256 amount);

    constructor(
        IERC20 underlying_,
        string memory name_,
        string memory symbol_
    ) ERC20(name_, symbol_) ERC4626(underlying_) Ownable(_msgSender()) {
        currentEpochId = 1;
    }

    modifier onlySettlementEngine() {
        require(msg.sender == settlementEngine, "Only settlement engine");
        _;
    }

    function setSettlementEngine(address _settlementEngine) external onlyOwner {
        require(_settlementEngine != address(0), "Invalid address");
        settlementEngine = _settlementEngine;
    }

    function distributeRevenue(uint256 epochId, uint256 totalRevenue) external onlySettlementEngine {
        require(epochId > 0, "Invalid epoch ID");
        require(totalRevenue > 0, "No revenue to distribute");
        
        uint256 totalSupply = totalSupply();
        require(totalSupply > 0, "No shares to distribute to");
        
        uint256 revenuePerShare = totalRevenue / totalSupply;
        epochRevenuePerShare[epochId] = revenuePerShare;
        
        currentEpochId = epochId;
        
        emit RevenueDistributed(epochId, revenuePerShare);
    }

    function claimRevenue(uint256 epochId) external returns (uint256 claimedAmount) {
        require(epochId <= currentEpochId, "Epoch not yet settled");
        require(epochRevenuePerShare[epochId] > 0, "No revenue for this epoch");
        
        uint256 userShares = balanceOf(msg.sender);
        require(userShares > 0, "No shares to claim revenue for");
        
        uint256 lastClaimed = lastClaimedEpoch[msg.sender];
        require(epochId > lastClaimed, "Revenue already claimed for this epoch");
        
        claimedAmount = userShares * epochRevenuePerShare[epochId];
        lastClaimedEpoch[msg.sender] = epochId;
        
        // Transfer the claimed revenue in underlying asset (CUP)
        if (claimedAmount > 0) {
            _asset.safeTransfer(msg.sender, claimedAmount);
        }
        
        emit RevenueClaimed(msg.sender, epochId, claimedAmount);
    }

    function getClaimableRevenue(address user, uint256 epochId) external view returns (uint256) {
        if (epochId > currentEpochId || epochRevenuePerShare[epochId] == 0) {
            return 0;
        }
        
        uint256 lastClaimed = lastClaimedEpoch[user];
        if (epochId <= lastClaimed) {
            return 0;
        }
        
        uint256 userShares = balanceOf(user);
        return userShares * epochRevenuePerShare[epochId];
    }

    function getTotalClaimableRevenue(address user) external view returns (uint256 totalClaimable) {
        for (uint256 epochId = lastClaimedEpoch[user] + 1; epochId <= currentEpochId; epochId++) {
            if (epochRevenuePerShare[epochId] > 0) {
                totalClaimable += balanceOf(user) * epochRevenuePerShare[epochId];
            }
        }
    }

    function pause() public onlyOwner {
        _pause();
    }

    function unpause() public onlyOwner {
        _unpause();
    }

    function decimals() public view override returns (uint8) {
        return 6;
    }
}
