// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {V2TestBase, MockAssetOracle, MockAccessControlMintable, MockERC20} from "./Helpers.sol";
import {OpenLiquidityRouter} from "../../contracts/v2/OpenLiquidityRouter.sol";
import {VaultFactory} from "../../contracts/v2/VaultFactory.sol";
import {VaultLib} from "../../contracts/v2/libraries/VaultLib.sol";
import {OracleLib} from "../../contracts/v2/libraries/OracleLib.sol";
import {RWAVault} from "../../contracts/v2/RWAVault.sol";
import {SharedSettlementEngine} from "../../contracts/v2/SharedSettlementEngine.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract OpenLiquidityRouterTest is V2TestBase {
    uint256 constant USDC_AMOUNT = 4500e6;
    uint256 constant ASSET_PRICE = 450_000_000;
    bytes32 constant DEPOSIT_ID = keccak256("deposit-1");

    function _zapUsdc(address who, bytes32 did, uint256 amount) internal {
        usdc.mint(who, amount);
        vm.startPrank(who);
        usdc.approve(address(router), amount);
        router.zapAndDeposit(vaultId, IERC20(address(usdc)), amount, did, 100, 0);
        vm.stopPrank();
    }

    function test_zapAndDeposit_directSettlementTokenPath() public {
        bytes32 did = keccak256("direct-usdc-zap");
        uint256 amount = 123e6;
        _zapUsdc(user, did, amount);

        VaultLib.Deposit memory d = router.getDeposit(vaultId, did);
        assertEq(d.user, user);
        assertEq(d.amount, amount);
        assertEq(usdc.balanceOf(facilityAddr), amount);
    }

    function test_zapAndDeposit_revertsZeroAmount() public {
        vm.prank(user);
        vm.expectRevert(OpenLiquidityRouter.ZeroAmount.selector);
        router.zapAndDeposit(vaultId, IERC20(address(usdc)), 0, keccak256("z0"), 100, 0);
    }

    function test_zapAndDeposit_revertsInvalidSlippage() public {
        vm.prank(user);
        vm.expectRevert(OpenLiquidityRouter.InvalidSlippage.selector);
        router.zapAndDeposit(vaultId, IERC20(address(usdc)), 1, keccak256("z1"), 1001, 0);
    }

    function test_zapAndDeposit_revertsTokenNotAllowlisted() public {
        MockERC20 alt = new MockERC20("ALT", "ALT", 6);
        alt.mint(user, 1_000e6);
        vm.startPrank(user);
        alt.approve(address(router), 1_000e6);
        vm.expectRevert(
            abi.encodeWithSelector(OpenLiquidityRouter.TokenNotAllowlisted.selector, address(alt))
        );
        router.zapAndDeposit(vaultId, IERC20(address(alt)), 1_000e6, DEPOSIT_ID, 100, 0);
        vm.stopPrank();
    }

    function test_find015_directSettlementCreditsMeasuredBalance() public {
        MockFeeOnTransferERC20 fot = new MockFeeOnTransferERC20("FoT USD", "FOT", 6, 100);
        MockAssetOracle fotOracle = new MockAssetOracle(1e8, "ASSET / FOT");

        vm.startPrank(admin);
        (uint256 fotVaultId,, address fotFacility,) = factory.createVault(
            VaultFactory.CreateVaultParams({
                assetToken: address(assetToken),
                settlementToken: address(fot),
                assetOracle: address(fotOracle),
                uniswapRouter: address(uniswapRouter),
                useEpochs: true,
                epochDuration: 600,
                wethToken: weth,
                vaultName: "FoT Vault",
                vaultSymbol: "xFOT",
                operator: address(0),
                treasury: treasury,
                reportedInventoryOnly: false
            })
        );
        registry.authorizeVaultMint(fotVaultId);
        vm.stopPrank();

        bytes32 did = keccak256("fot-direct");
        uint256 amount = 100e6;
        uint256 expectedReceived = amount - (amount * 100) / 10_000;

        fot.mint(user, amount);
        vm.startPrank(user);
        fot.approve(address(router), amount);
        router.zapAndDeposit(fotVaultId, IERC20(address(fot)), amount, did, 100, 0);
        vm.stopPrank();

        VaultLib.Deposit memory d = router.getDeposit(fotVaultId, did);
        assertEq(d.amount, expectedReceived);
        assertEq(fot.balanceOf(fotFacility), expectedReceived);
        assertEq(router.getCommittedLiability(fotVaultId), expectedReceived);
    }

    function test_find020_revertsTooManyPendingDeposits() public {
        uint256 maxPending = router.MAX_PENDING_DEPOSITS_PER_USER();
        uint256 amount = 1e6;
        usdc.mint(user, amount * (maxPending + 1));

        vm.startPrank(user);
        usdc.approve(address(router), amount * (maxPending + 1));

        for (uint256 i; i < maxPending; i++) {
            router.zapAndDeposit(
                vaultId,
                IERC20(address(usdc)),
                amount,
                keccak256(abi.encode("spam", i)),
                100,
                0
            );
        }
        assertEq(router.getOpenPendingDeposits(vaultId, user), maxPending);

        vm.expectRevert(
            abi.encodeWithSelector(
                OpenLiquidityRouter.TooManyPendingDeposits.selector,
                user,
                maxPending,
                maxPending
            )
        );
        router.zapAndDeposit(
            vaultId,
            IERC20(address(usdc)),
            amount,
            keccak256("spam-overflow"),
            100,
            0
        );
        vm.stopPrank();
    }

    function test_approveDeposit_settlesShares() public {
        _zapUsdc(user, DEPOSIT_ID, USDC_AMOUNT);

        vm.prank(curator);
        router.approveDeposit(vaultId, DEPOSIT_ID, USDC_AMOUNT, ASSET_PRICE);

        VaultLib.Deposit memory d = router.getDeposit(vaultId, DEPOSIT_ID);
        assertTrue(d.approved);
        assertGt(d.approvedShares, 0);
    }

    function test_claimDeposit_transfersShares() public {
        _zapUsdc(user, DEPOSIT_ID, USDC_AMOUNT);
        vm.prank(curator);
        router.approveDeposit(vaultId, DEPOSIT_ID, USDC_AMOUNT, ASSET_PRICE);

        uint256 shares = router.getDeposit(vaultId, DEPOSIT_ID).approvedShares;
        vm.prank(user);
        router.claimDeposit(vaultId, DEPOSIT_ID);

        assertEq(RWAVault(vaultAddr).balanceOf(user), shares);
    }

    function test_find029_approveDeposit_revertsStaleOracle() public {
        _zapUsdc(user, DEPOSIT_ID, USDC_AMOUNT);

        // Keep warp inside the 600s epoch window: use a short max age.
        uint256 maxAge = 60;
        MockStaleOracle stale = new MockStaleOracle(ASSET_PRICE, block.timestamp);
        uint256 updatedAt = stale.updatedAt();
        vm.startPrank(admin);
        registry.setVaultOracle(vaultId, address(stale));
        registry.setVaultMaxOracleAge(vaultId, maxAge, false);
        vm.stopPrank();

        vm.warp(block.timestamp + maxAge + 1);

        vm.expectRevert(
            abi.encodeWithSelector(
                OracleLib.StaleOracle.selector,
                address(stale),
                updatedAt,
                maxAge,
                block.timestamp
            )
        );
        vm.prank(curator);
        router.approveDeposit(vaultId, DEPOSIT_ID, USDC_AMOUNT, ASSET_PRICE);
    }

    function test_find029_bypass_raiseMaxOracleAge() public {
        _zapUsdc(user, DEPOSIT_ID, USDC_AMOUNT);

        uint256 maxAge = 60;
        MockStaleOracle stale = new MockStaleOracle(ASSET_PRICE, block.timestamp);
        vm.startPrank(admin);
        registry.setVaultOracle(vaultId, address(stale));
        registry.setVaultMaxOracleAge(vaultId, maxAge, false);
        vm.stopPrank();

        vm.warp(block.timestamp + maxAge + 1);

        // Bypass A: raise per-vault max age so the same feed is accepted again.
        vm.prank(admin);
        registry.setVaultMaxOracleAge(vaultId, 30 days, false);

        vm.prank(curator);
        router.approveDeposit(vaultId, DEPOSIT_ID, USDC_AMOUNT, ASSET_PRICE);
        assertGt(router.getDeposit(vaultId, DEPOSIT_ID).approvedShares, 0);
    }

    function test_reportedInventory_totalAssets_zeroUntilNavInitialized() public {
        vm.startPrank(admin);
        (uint256 vid, address vAddr,,) = factory.createVault(
            VaultFactory.CreateVaultParams({
                assetToken: address(assetToken),
                settlementToken: address(usdc),
                assetOracle: address(assetOracle),
                uniswapRouter: address(uniswapRouter),
                useEpochs: true,
                epochDuration: 600,
                wethToken: weth,
                vaultName: "Reported",
                vaultSymbol: "xREP",
                operator: address(0),
                treasury: treasury,
                reportedInventoryOnly: true
            })
        );
        registry.authorizeVaultMint(vid);
        vm.stopPrank();

        RWAVault v = RWAVault(vAddr);
        assertTrue(v.reportedInventoryOnly());
        assertEq(v.totalAssets(), 0);
        assertFalse(settlement.navInitialized(vid));

        vm.prank(admin);
        settlement.updateNAV(
            vid,
            SharedSettlementEngine.NAVComponents({
                assetInInventory: 1_000e6,
                assetSpotPrice: ASSET_PRICE,
                assetInTransit: 0,
                retainedEarnings: 0,
                stablecoinBalance: 0,
                liabilities: 0
            })
        );

        assertTrue(settlement.navInitialized(vid));
        assertEq(v.totalAssets(), 1_000e6);
    }
}

contract MockStaleOracle {
    uint256 public price;
    uint256 private _updatedAt;

    constructor(uint256 price_, uint256 updatedAt_) {
        price = price_;
        _updatedAt = updatedAt_;
    }

    function decimals() external pure returns (uint8) {
        return 8;
    }

    function description() external pure returns (string memory) {
        return "STALE";
    }

    function updatedAt() external view returns (uint256) {
        return _updatedAt;
    }
}

/// @dev ERC-20 that skims `feeBps` of each transfer (FIND-015 fixture).
contract MockFeeOnTransferERC20 {
    string public name;
    string public symbol;
    uint8 public immutable decimals;
    uint256 public immutable feeBps;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    constructor(string memory name_, string memory symbol_, uint8 decimals_, uint256 feeBps_) {
        name = name_;
        symbol = symbol_;
        decimals = decimals_;
        feeBps = feeBps_;
    }

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
        totalSupply += amount;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        return _transfer(msg.sender, to, amount);
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        uint256 allowed = allowance[from][msg.sender];
        if (allowed != type(uint256).max) {
            allowance[from][msg.sender] = allowed - amount;
        }
        return _transfer(from, to, amount);
    }

    function _transfer(address from, address to, uint256 amount) internal returns (bool) {
        uint256 fee = (amount * feeBps) / 10_000;
        uint256 sendAmount = amount - fee;
        balanceOf[from] -= amount;
        balanceOf[to] += sendAmount;
        // Fee is burned (removed from circulation) to mimic FoT skim.
        totalSupply -= fee;
        return true;
    }
}
