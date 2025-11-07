// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

interface IXCUPRatePool {
    function getReserves() external view returns (uint256 reserveXCUP, uint256 reserveUSDC);
    function swapFee() external view returns (uint16);
    function swapExactXCUPToUSDC(uint256 xcupAmountIn, uint256 minUSDCOut) external;
    function swapExactUSDCToXCUP(uint256 usdcAmountIn, uint256 minXCUPOut) external;
}
