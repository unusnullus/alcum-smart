// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/**
 * @title INavReader
 * @notice Minimal Settlement view surface for reported-inventory ERC-4626 accounting (§05).
 */
interface INavReader {
    struct NAVComponents {
        uint256 assetInInventory;
        uint256 assetSpotPrice;
        uint256 assetInTransit;
        uint256 retainedEarnings;
        uint256 stablecoinBalance;
        uint256 liabilities;
    }

    function navInitialized(uint256 vaultId) external view returns (bool);

    function getNav(uint256 vaultId) external view returns (NAVComponents memory);
}
