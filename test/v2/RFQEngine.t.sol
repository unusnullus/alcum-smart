// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {V2TestBase, MockERC20} from "./Helpers.sol";
import {RFQEngine} from "../../contracts/v2/RFQEngine.sol";
import {IRFQEngine} from "../../contracts/v2/interfaces/IRFQEngine.sol";
import {VaultFactory} from "../../contracts/v2/VaultFactory.sol";
import {MockAssetOracle} from "./Helpers.sol";

contract RFQEngineTest is V2TestBase {

    uint256 constant SHARES = 1000e6;
    uint256 constant USDC   = 4000e6;
    uint256 constant EXPIRY = 1 days;

    // ─── Helpers ──────────────────────────────────────────────────────────

    /// Give `user` shares and approve rfqEngine.
    function _giveUserShares(uint256 amount) internal {
        vm.startPrank(admin);
        assetToken.mint(vaultAddr, amount);
        vm.stopPrank();
        // Shares held by the vault's totalAssets; simulate direct share credit
        // by minting USDC to facility and giving shares via deposit path.
        // For unit tests: just deal shares directly.
        deal(vaultAddr, user, amount);
        vm.prank(user);
        // Approve rfqEngine to pull shares
        (bool ok,) = vaultAddr.call(
            abi.encodeWithSignature("approve(address,uint256)", address(rfqEngine), amount)
        );
        require(ok);
    }

    function _createRFQ() internal returns (bytes32 rfqId) {
        _giveUserShares(SHARES);
        vm.prank(user);
        rfqId = rfqEngine.createRFQ(vaultId, SHARES, USDC, block.timestamp + EXPIRY);
    }

    // ─── createRFQ ────────────────────────────────────────────────────────

    function test_createRFQ_storesRequest() public {
        bytes32 rfqId = _createRFQ();
        IRFQEngine.RFQRequest memory r = rfqEngine.getRFQ(rfqId);

        assertEq(r.requester,  user);
        assertEq(r.vaultId,    vaultId);
        assertEq(r.shares,     SHARES);
        assertEq(r.minSettlementToken, USDC);
        assertFalse(r.filled);
        assertFalse(r.cancelled);
    }

    function test_createRFQ_locksShares() public {
        bytes32 rfqId = _createRFQ();
        // Shares locked in contract
        (bool ok, bytes memory data) = vaultAddr.staticcall(
            abi.encodeWithSignature("balanceOf(address)", address(rfqEngine))
        );
        require(ok);
        uint256 bal = abi.decode(data, (uint256));
        assertEq(bal, SHARES);
    }

    function test_createRFQ_appearsInActiveList() public {
        bytes32 rfqId = _createRFQ();
        assertEq(rfqEngine.getActiveRFQCount(), 1);
        bytes32[] memory page = rfqEngine.getActiveRFQsPaginated(0, 10);
        assertEq(page[0], rfqId);
    }

    function test_createRFQ_revertsZeroShares() public {
        vm.prank(user);
        vm.expectRevert(RFQEngine.ZeroShares.selector);
        rfqEngine.createRFQ(vaultId, 0, USDC, block.timestamp + EXPIRY);
    }

    function test_createRFQ_revertsExpiredDeadline() public {
        vm.prank(user);
        vm.expectRevert(RFQEngine.InvalidExpiry.selector);
        rfqEngine.createRFQ(vaultId, SHARES, USDC, block.timestamp - 1);
    }

    function test_createRFQ_revertsInactiveVault() public {
        vm.prank(admin);
        registry.setVaultActive(vaultId, false);

        _giveUserShares(SHARES);
        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(RFQEngine.VaultNotActive.selector, vaultId));
        rfqEngine.createRFQ(vaultId, SHARES, USDC, block.timestamp + EXPIRY);
    }

    // ─── cancelRFQ ────────────────────────────────────────────────────────

    function test_cancelRFQ_returnsShares() public {
        bytes32 rfqId = _createRFQ();

        (bool ok, bytes memory data) = vaultAddr.staticcall(
            abi.encodeWithSignature("balanceOf(address)", user)
        );
        require(ok);
        uint256 before = abi.decode(data, (uint256));

        vm.prank(user);
        rfqEngine.cancelRFQ(rfqId);

        (ok, data) = vaultAddr.staticcall(
            abi.encodeWithSignature("balanceOf(address)", user)
        );
        require(ok);
        uint256 after_ = abi.decode(data, (uint256));
        assertEq(after_ - before, SHARES);
    }

    function test_cancelRFQ_marksAsCancelled() public {
        bytes32 rfqId = _createRFQ();
        vm.prank(user);
        rfqEngine.cancelRFQ(rfqId);

        IRFQEngine.RFQRequest memory r = rfqEngine.getRFQ(rfqId);
        assertTrue(r.cancelled);
    }

    function test_cancelRFQ_removedFromActiveList() public {
        bytes32 rfqId = _createRFQ();
        vm.prank(user);
        rfqEngine.cancelRFQ(rfqId);
        assertEq(rfqEngine.getActiveRFQCount(), 0);
    }

    function test_cancelRFQ_revertsIfNotOwner() public {
        bytes32 rfqId = _createRFQ();
        vm.prank(user2);
        vm.expectRevert(RFQEngine.NotRFQOwner.selector);
        rfqEngine.cancelRFQ(rfqId);
    }

    function test_cancelRFQ_revertsDoubleCancellation() public {
        bytes32 rfqId = _createRFQ();
        vm.prank(user);
        rfqEngine.cancelRFQ(rfqId);

        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(RFQEngine.RFQAlreadyCancelled.selector, rfqId));
        rfqEngine.cancelRFQ(rfqId);
    }

    // ─── fillRFQ ──────────────────────────────────────────────────────────

    function test_fillRFQ_atomicSwap() public {
        bytes32 rfqId = _createRFQ();

        // Fund MM with USDC
        usdc.mint(marketMaker, USDC);
        vm.prank(marketMaker);
        usdc.approve(address(rfqEngine), USDC);

        (bool ok, bytes memory data) = vaultAddr.staticcall(
            abi.encodeWithSignature("balanceOf(address)", user)
        );
        require(ok);
        uint256 sharesBefore = abi.decode(data, (uint256));

        uint256 usdcBefore = usdc.balanceOf(user);

        vm.prank(marketMaker);
        rfqEngine.fillRFQ(rfqId, USDC);

        // User received USDC
        assertEq(usdc.balanceOf(user) - usdcBefore, USDC);

        // MM received shares
        (ok, data) = vaultAddr.staticcall(
            abi.encodeWithSignature("balanceOf(address)", marketMaker)
        );
        require(ok);
        uint256 mmShares = abi.decode(data, (uint256));
        assertEq(mmShares, SHARES);
    }

    function test_fillRFQ_marksFilled() public {
        bytes32 rfqId = _createRFQ();
        usdc.mint(marketMaker, USDC);
        vm.prank(marketMaker);
        usdc.approve(address(rfqEngine), USDC);

        vm.prank(marketMaker);
        rfqEngine.fillRFQ(rfqId, USDC);

        IRFQEngine.RFQRequest memory r = rfqEngine.getRFQ(rfqId);
        assertTrue(r.filled);
        assertEq(r.filledBy, marketMaker);
        assertEq(r.tokenReceived, USDC);
    }

    function test_fillRFQ_removedFromActiveList() public {
        bytes32 rfqId = _createRFQ();
        usdc.mint(marketMaker, USDC);
        vm.prank(marketMaker);
        usdc.approve(address(rfqEngine), USDC);

        vm.prank(marketMaker);
        rfqEngine.fillRFQ(rfqId, USDC);

        assertEq(rfqEngine.getActiveRFQCount(), 0);
    }

    function test_fillRFQ_revertsBelowMinUSDC() public {
        bytes32 rfqId = _createRFQ();
        uint256 lowUSDC = USDC - 1;
        usdc.mint(marketMaker, lowUSDC);
        vm.prank(marketMaker);
        usdc.approve(address(rfqEngine), lowUSDC);

        vm.prank(marketMaker);
        vm.expectRevert(abi.encodeWithSelector(RFQEngine.BelowMinSettlementToken.selector, lowUSDC, USDC));
        rfqEngine.fillRFQ(rfqId, lowUSDC);
    }

    function test_fillRFQ_revertsExpired() public {
        bytes32 rfqId = _createRFQ();
        vm.warp(block.timestamp + EXPIRY + 1);

        usdc.mint(marketMaker, USDC);
        vm.prank(marketMaker);
        usdc.approve(address(rfqEngine), USDC);

        vm.prank(marketMaker);
        vm.expectRevert(abi.encodeWithSelector(RFQEngine.RFQExpired.selector, rfqId));
        rfqEngine.fillRFQ(rfqId, USDC);
    }

    function test_fillRFQ_revertsAlreadyFilled() public {
        bytes32 rfqId = _createRFQ();
        usdc.mint(marketMaker, USDC * 2);
        vm.startPrank(marketMaker);
        usdc.approve(address(rfqEngine), USDC * 2);
        rfqEngine.fillRFQ(rfqId, USDC);

        vm.expectRevert(abi.encodeWithSelector(RFQEngine.RFQAlreadyFilled.selector, rfqId));
        rfqEngine.fillRFQ(rfqId, USDC);
        vm.stopPrank();
    }

    function test_fillRFQ_revertsNonRegisteredMM() public {
        bytes32 rfqId = _createRFQ();
        usdc.mint(user2, USDC);
        vm.prank(user2);
        usdc.approve(address(rfqEngine), USDC);

        vm.prank(user2);
        vm.expectRevert();  // AccessControl: missing MARKET_MAKER_ROLE
        rfqEngine.fillRFQ(rfqId, USDC);
    }

    // ─── Multi-vault isolation ─────────────────────────────────────────────

    function test_rfq_multiVaultIsolation() public {
        // Create vault 2 with a different asset
        vm.startPrank(admin);
        MockERC20 goldToken = new MockERC20("Gold", "GOLD", 6);
        (uint256 vid2, address v2addr,,) = factory.createVault(VaultFactory.CreateVaultParams({
            assetToken:     address(goldToken),
            settlementToken: address(usdc),
            assetOracle:    address(assetOracle),
            uniswapRouter:  address(uniswapRouter),
            useEpochs:      true,
            epochDuration:  600,
            wethToken:      weth,
            vaultName:      "xGOLD Vault",
            vaultSymbol:    "xGOLD",
            operator:       address(0),
            treasury:       treasury,
            reportedInventoryOnly: false
        }));
        vm.stopPrank();

        // Give user shares in vault2
        deal(v2addr, user, SHARES);
        vm.prank(user);
        (bool ok,) = v2addr.call(
            abi.encodeWithSignature("approve(address,uint256)", address(rfqEngine), SHARES)
        );
        require(ok);

        vm.prank(user);
        bytes32 rfqId2 = rfqEngine.createRFQ(vid2, SHARES, USDC, block.timestamp + EXPIRY);

        // Vault 1 has no RFQs
        assertEq(rfqEngine.getActiveRFQCount(), 1);
        assertEq(rfqEngine.getRFQ(rfqId2).vaultId, vid2);
    }

    // ─── Admin ────────────────────────────────────────────────────────────

    function test_registerMarketMaker_addsAndRemoves() public {
        address newMM = makeAddr("newMM");
        assertFalse(rfqEngine.isRegisteredMM(newMM));

        vm.prank(admin);
        rfqEngine.registerMarketMaker(newMM, true);
        assertTrue(rfqEngine.isRegisteredMM(newMM));

        vm.prank(admin);
        rfqEngine.registerMarketMaker(newMM, false);
        assertFalse(rfqEngine.isRegisteredMM(newMM));
    }

    function test_pause_preventsCreateRFQ() public {
        vm.prank(admin);
        rfqEngine.pause();

        _giveUserShares(SHARES);
        vm.prank(user);
        vm.expectRevert();
        rfqEngine.createRFQ(vaultId, SHARES, USDC, block.timestamp + EXPIRY);
    }
}
