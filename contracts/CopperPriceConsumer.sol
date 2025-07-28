// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import "@chainlink/contracts/src/v0.8/ChainlinkClient.sol";

contract CopperPriceConsumer is ChainlinkClient {
    using Chainlink for Chainlink.Request;

    uint256 public price;
    address private oracle;
    bytes32 private jobId;
    uint256 private fee; // Check fee inside job

    constructor(address _oracle, bytes32 _jobId, uint256 _fee, address _link) {
        _setChainlinkToken(_link);
        oracle = _oracle;
        jobId = _jobId;
        fee = _fee; // e.g., 0.1 * 10 ** 18 (0.1 LINK)
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
}
