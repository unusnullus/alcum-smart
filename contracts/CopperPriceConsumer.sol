// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

import {ChainlinkClient} from "@chainlink/contracts/src/v0.8/ChainlinkClient.sol";
import {Chainlink} from "@chainlink/contracts/src/v0.8/Chainlink.sol";

import {ICopperPriceConsumer} from "./interfaces/ICopperPriceConsumer.sol";
import {console} from "hardhat/console.sol";

contract CopperPriceConsumer is ChainlinkClient, ICopperPriceConsumer, Ownable {
    using Chainlink for Chainlink.Request;

    // Decimal precision for price storage (8 decimals)
    uint256 private constant PRICE_DECIMALS = 8;
    uint256 private constant PRICE_MULTIPLIER = 10 ** PRICE_DECIMALS;

    uint256 public price;
    address private oracle;
    bytes32 private jobId;
    uint256 private fee;

    constructor(address _oracle, bytes32 _jobId, uint256 _fee, address _link) Ownable(msg.sender) {
        _setChainlinkToken(_link);

        oracle = _oracle;
        jobId = _jobId;
        fee = _fee;
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

    function setJobId(bytes32 _jobId) public onlyOwner {
        jobId = _jobId;
    }

    function setFee(uint256 _fee) public onlyOwner {
        fee = _fee;
    }

    function getPriceAsDecimal() public view returns (uint256) {
        return price / PRICE_MULTIPLIER;
    }
}
