// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

interface ICopperPriceConsumer {
    function requestCopperPrice() external returns (bytes32 requestId);

    function fulfill(bytes32 _requestId, uint256 _price) external;

    function getPriceAsDecimal() external view returns (uint256);

    function price() external view returns (uint256);
}
