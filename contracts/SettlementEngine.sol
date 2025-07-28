// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";

contract SettlementEngine is Ownable {
    struct NAVComponents {
        uint256 cupInWarehouse;
        uint256 copperSpotPrice;
        uint256 cupInTransit;
        uint256 retainedEarnings;
        uint256 stablecoinBalance;
        uint256 liabilities;
    }

    NAVComponents public _nav;

    address public _treasury;

    IERC4626 public _vault;

    event NAVUpdated(uint256 totalNAV, uint256 pricePerShare);

    constructor(address vault, address treasury) Ownable(_msgSender()) {
        require(vault != address(0), "Invalid Vault address");
        require(treasury != address(0), "Invalid Treasury address");

        _vault = IERC4626(vault);
        _treasury = treasury;
    }

    function updateNAV(NAVComponents calldata newNav) external onlyOwner {
        _nav = newNav;
        uint256 totalAssets = (_nav.cupInWarehouse * _nav.copperSpotPrice) +
            _nav.cupInTransit +
            _nav.retainedEarnings +
            _nav.stablecoinBalance;
        uint256 netAssets = totalAssets - _nav.liabilities;
        uint256 supply = _vault.totalSupply();
        uint256 pricePerShare = supply == 0 ? 0 : netAssets / supply;

        emit NAVUpdated(netAssets, pricePerShare);
    }

    function getNAVSummary() external view returns (uint256 totalAssets, uint256 netAssets, uint256 pricePerShare) {
        totalAssets =
            (_nav.cupInWarehouse * _nav.copperSpotPrice) +
            _nav.cupInTransit +
            _nav.retainedEarnings +
            _nav.stablecoinBalance;
        netAssets = totalAssets - _nav.liabilities;
        uint256 supply = _vault.totalSupply();
        pricePerShare = supply == 0 ? 0 : netAssets / supply;
    }
}
