// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {ChainlinkClient} from "@chainlink/contracts/src/v0.8/ChainlinkClient.sol";
import {Chainlink} from "@chainlink/contracts/src/v0.8/Chainlink.sol";

import {ICopperPriceConsumer} from "../interfaces/ICopperPriceConsumer.sol";

contract CopperPriceConsumerMock is ChainlinkClient, ICopperPriceConsumer {
    using Chainlink for Chainlink.Request;

    uint256 public price;
    address private oracle;
    bytes32 private jobId;
    uint256 private fee; // Check fee inside job

    constructor() {
        price = 500000000;
    }

    function requestCopperPrice() public returns (bytes32 requestId) {
        Chainlink.Request memory req = _buildChainlinkRequest(jobId, address(this), this.fulfill.selector);
        req._add("base", "COPPER");
        req._add("quote", "USD");
        return _sendChainlinkRequestTo(oracle, req, fee);
    }

    function fulfill(bytes32 _requestId, uint256 _price) public recordChainlinkFulfillment(_requestId) {
        price = _price;
    }

    function getPriceAsDecimal() public view returns (uint256) {
        return price;
    }
}
