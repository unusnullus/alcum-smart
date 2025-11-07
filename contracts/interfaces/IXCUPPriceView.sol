// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

interface IXCUPPriceView {
    function getXcupPriceInToken(address token, uint256 xcupAmount) external view returns (uint256 price);
    function getTokenToXcupExchangeRate(address token, uint256 tokenAmount) external view returns (uint256 xcupAmount);
}
