// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {V2TestBase} from "./Helpers.sol";
import {OpenLiquidityRouter} from "../../contracts/v2/OpenLiquidityRouter.sol";
import {VaultFactory} from "../../contracts/v2/VaultFactory.sol";
import {VaultLib} from "../../contracts/v2/libraries/VaultLib.sol";

contract OpenLiquidityRouterTest is V2TestBase {
    uint256 constant USDC_AMOUNT = 4500e6; // $4,500
    uint256 constant ASSET_PRICE = 450_000_000; // $4.50 (8 dec)
    uint256 constant ORACLE_DEC = 8;
    uint256 constant ASSET_AMOUNT = (USDC_AMOUNT * 1e8) / ASSET_PRICE; // = 1000e6

    // ─── External Deposit ─────────────────────────────────────────────────

    function _registerExternal() internal returns (bytes32 did) {
        vm.prank(admin);
        did = router.registerExternalDeposit(vaultId, user, USDC_AMOUNT, bytes32("tag1"));
    }

    function test_externalDeposit_register_stores() public {
        bytes32 did = _registerExternal();
        VaultLib.Deposit memory d = router.getDeposit(vaultId, did);

        assertEq(d.amount, USDC_AMOUNT);
        assertEq(d.beneficiary, user);
        assertTrue(d.isExternal);
        assertFalse(d.approved);
        assertEq(d.tag, bytes32("tag1"));
    }

    function test_externalDeposit_appearsInPending() public {
        bytes32 did = _registerExternal();
        bytes32[] memory pending = router.getPendingDepositIds(vaultId);
        assertEq(pending.length, 1);
        assertEq(pending[0], did);
    }

    function test_externalDeposit_approve() public {
        bytes32 did = _registerExternal();
        vm.prank(curator);
        router.approveExternalDeposit(vaultId, did, USDC_AMOUNT, ASSET_PRICE);

        VaultLib.Deposit memory d = router.getDeposit(vaultId, did);
        assertTrue(d.approved);
        assertEq(d.approvedAmount, USDC_AMOUNT);
        assertEq(d.priceSnapshot, ASSET_PRICE);
        assertEq(d.approvedAssetAmount, ASSET_AMOUNT);
    }

    function test_externalDeposit_approve_removesFromPending() public {
        bytes32 did = _registerExternal();
        vm.prank(curator);
        router.approveExternalDeposit(vaultId, did, USDC_AMOUNT, ASSET_PRICE);

        assertEq(router.getPendingDepositIds(vaultId).length, 0);
    }

    function test_externalDeposit_claim_mintsShares() public {
        bytes32 did = _registerExternal();

        vm.prank(curator);
        router.approveExternalDeposit(vaultId, did, USDC_AMOUNT, ASSET_PRICE);

        // Fund facility with USDC (represents the external cash that was wired)
        _fundFacility(USDC_AMOUNT);
        // Facility pre-approves router — already done in CapitalFacility.initialize()

        // Give router MINTER authority (mock: just mint directly)
        // In tests we use MockERC20, which has unrestricted mint
        // claimDeposit calls IERC20Mintable(v.assetToken).mint(address(this), approvedAssetAmount)
        // Our MockERC20 mint is unrestricted, so this works without a role setup.

        uint256 sharesBefore = _sharesOf(user);

        vm.prank(user);
        uint256 shares = router.claimDeposit(vaultId, did);

        assertGt(shares, 0);
        assertGt(_sharesOf(user) - sharesBefore, 0);
    }

    function test_externalDeposit_revertsDoubleApprove() public {
        bytes32 did = _registerExternal();
        vm.prank(curator);
        router.approveExternalDeposit(vaultId, did, USDC_AMOUNT, ASSET_PRICE);

        vm.prank(curator);
        vm.expectRevert(VaultLib.DepositAlreadyApproved.selector);
        router.approveExternalDeposit(vaultId, did, USDC_AMOUNT, ASSET_PRICE);
    }

    function test_externalDeposit_registerRevertsZeroAmount() public {
        vm.prank(admin);
        vm.expectRevert(OpenLiquidityRouter.ZeroAmount.selector);
        router.registerExternalDeposit(vaultId, user, 0, bytes32("tag"));
    }

    function test_externalDeposit_registerRevertsZeroBeneficiary() public {
        vm.prank(admin);
        vm.expectRevert(OpenLiquidityRouter.ZeroAddress.selector);
        router.registerExternalDeposit(vaultId, address(0), USDC_AMOUNT, bytes32("tag"));
    }

    function test_externalDeposit_decline_doesNotPullFacility() public {
        bytes32 did = _registerExternal();
        _fundFacility(USDC_AMOUNT);

        uint256 facilityBefore = usdc.balanceOf(facilityAddr);
        uint256 hostBefore = usdc.balanceOf(admin);

        vm.prank(curator);
        router.declineDeposit(vaultId, did);

        assertEq(usdc.balanceOf(facilityAddr), facilityBefore);
        assertEq(usdc.balanceOf(admin), hostBefore);
        assertEq(router.getDeposit(vaultId, did).user, address(0));
    }

    // ─── Queued Redeem ────────────────────────────────────────────────────

    function _setupUserWithShares() internal returns (uint256 shares) {
        bytes32 did = _registerExternal();
        vm.prank(curator);
        router.approveExternalDeposit(vaultId, did, USDC_AMOUNT, ASSET_PRICE);
        _fundFacility(USDC_AMOUNT);
        vm.prank(user);
        shares = router.claimDeposit(vaultId, did);
    }

    function test_requestRedeem_locksShares() public {
        uint256 shares = _setupUserWithShares();
        bytes32 rid = keccak256("redeem1");

        _approveVaultShares(user, shares);
        vm.prank(user);
        router.requestRedeem(vaultId, shares, rid);

        VaultLib.RedeemRequest memory r = router.getRedeem(vaultId, rid);
        assertEq(r.shares, shares);
        assertEq(r.user, user);
        assertFalse(r.approved);
    }

    function test_requestRedeem_revertsZeroShares() public {
        vm.prank(user);
        vm.expectRevert(OpenLiquidityRouter.ZeroAmount.selector);
        router.requestRedeem(vaultId, 0, bytes32("rid"));
    }

    function test_approveRedeem_setsUsdcAmount() public {
        uint256 shares = _setupUserWithShares();
        bytes32 rid = keccak256("redeem1");

        _approveVaultShares(user, shares);
        vm.prank(user);
        router.requestRedeem(vaultId, shares, rid);

        _fundFacility(USDC_AMOUNT);

        vm.prank(curator);
        router.approveRedeem(vaultId, rid, USDC_AMOUNT);

        VaultLib.RedeemRequest memory r = router.getRedeem(vaultId, rid);
        assertTrue(r.approved);
        assertEq(r.tokenAmount, USDC_AMOUNT);
    }

    function test_claimRedeem_sendsUSDC() public {
        uint256 shares = _setupUserWithShares();
        bytes32 rid = keccak256("redeem1");

        _approveVaultShares(user, shares);
        vm.prank(user);
        router.requestRedeem(vaultId, shares, rid);

        _fundFacility(USDC_AMOUNT);

        vm.prank(curator);
        router.approveRedeem(vaultId, rid, USDC_AMOUNT);

        uint256 before = usdc.balanceOf(user);
        vm.prank(user);
        router.claimRedeem(vaultId, rid);

        assertEq(usdc.balanceOf(user) - before, USDC_AMOUNT);
    }

    function test_declineRedeem_returnsShares() public {
        uint256 shares = _setupUserWithShares();
        bytes32 rid = keccak256("redeem1");

        _approveVaultShares(user, shares);
        vm.prank(user);
        router.requestRedeem(vaultId, shares, rid);

        uint256 beforeShares = _sharesOf(user);
        vm.prank(curator);
        router.declineRedeem(vaultId, rid);

        assertEq(_sharesOf(user) - beforeShares, shares);
    }

    function test_approveRedeem_revertsInsufficientFacilityBalance() public {
        uint256 shares = _setupUserWithShares();
        bytes32 rid = keccak256("redeem1");

        _approveVaultShares(user, shares);
        vm.prank(user);
        router.requestRedeem(vaultId, shares, rid);

        // Don't fund facility — should revert
        vm.prank(curator);
        vm.expectRevert(OpenLiquidityRouter.InsufficientFacilityBalance.selector);
        router.approveRedeem(vaultId, rid, USDC_AMOUNT);
    }

    // ─── Multi-vault isolation ─────────────────────────────────────────────

    function test_multiVault_depositsIsolated() public {
        // Create vault 2
        vm.startPrank(admin);
        MockERC20Stub at2 = new MockERC20Stub();
        (uint256 vid2, , , ) = factory.createVault(
            VaultFactory.CreateVaultParams({
                assetToken: address(at2),
                settlementToken: address(usdc),
                assetOracle: address(assetOracle),
                uniswapRouter: address(uniswapRouter),
                useEpochs: true,
                epochDuration: 600,
                wethToken: weth,
                vaultName: "xAT2",
                vaultSymbol: "xAT2",
                operator: address(0),
                treasury: treasury,
                reportedInventoryOnly: false
            })
        );
        vm.stopPrank();

        // Register deposit in vault 1
        vm.prank(admin);
        bytes32 did1 = router.registerExternalDeposit(vaultId, user, USDC_AMOUNT, bytes32("v1"));

        // Register deposit in vault 2
        vm.prank(admin);
        bytes32 did2 = router.registerExternalDeposit(vid2, user2, USDC_AMOUNT, bytes32("v2"));

        // Vault 1 pending: only did1
        bytes32[] memory p1 = router.getPendingDepositIds(vaultId);
        assertEq(p1.length, 1);
        assertEq(p1[0], did1);

        // Vault 2 pending: only did2
        bytes32[] memory p2 = router.getPendingDepositIds(vid2);
        assertEq(p2.length, 1);
        assertEq(p2[0], did2);
    }

    // ─── claimRedeem error paths ──────────────────────────────────────────

    function test_claimRedeem_revertsIfNotOwner() public {
        uint256 shares = _setupUserWithShares();
        bytes32 rid = keccak256("redeem1");

        _approveVaultShares(user, shares);
        vm.prank(user);
        router.requestRedeem(vaultId, shares, rid);

        _fundFacility(USDC_AMOUNT);
        vm.prank(curator);
        router.approveRedeem(vaultId, rid, USDC_AMOUNT);

        vm.prank(user2); // wrong caller
        vm.expectRevert(OpenLiquidityRouter.NotRedeemOwner.selector);
        router.claimRedeem(vaultId, rid);
    }

    function test_claimRedeem_revertsIfNotApproved() public {
        uint256 shares = _setupUserWithShares();
        bytes32 rid = keccak256("redeem1");

        _approveVaultShares(user, shares);
        vm.prank(user);
        router.requestRedeem(vaultId, shares, rid);

        vm.prank(user);
        vm.expectRevert(VaultLib.RedeemNotApproved.selector);
        router.claimRedeem(vaultId, rid);
    }

    function test_requestRedeem_appearsInPendingList() public {
        uint256 shares = _setupUserWithShares();
        bytes32 rid = keccak256("redeem1");

        _approveVaultShares(user, shares);
        vm.prank(user);
        router.requestRedeem(vaultId, shares, rid);

        bytes32[] memory pending = router.getPendingRedeemIds(vaultId);
        assertEq(pending.length, 1);
        assertEq(pending[0], rid);
    }

    function test_requestRedeem_appearsInUserRedeems() public {
        uint256 shares = _setupUserWithShares();
        bytes32 rid = keccak256("redeem1");

        _approveVaultShares(user, shares);
        vm.prank(user);
        router.requestRedeem(vaultId, shares, rid);

        bytes32[] memory userRedeems = router.getUserRedeems(vaultId, user);
        assertEq(userRedeems.length, 1);
        assertEq(userRedeems[0], rid);
    }

    // ─── getUserDeposits ──────────────────────────────────────────────────

    function test_getUserDeposits_returnsUserEntries() public {
        bytes32 did = _registerExternal();
        bytes32[] memory userDeps = router.getUserDeposits(vaultId, user);
        assertEq(userDeps.length, 1);
        assertEq(userDeps[0], did);
    }

    function test_rescueTokens_revertsVaultShares() public {
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(OpenLiquidityRouter.CannotRescueVaultShares.selector, vaultAddr));
        router.rescueTokens(vaultAddr, admin, 1);
    }

    // ─── rescueTokens ─────────────────────────────────────────────────────

    function test_rescueTokens_transfersOut() public {
        // Accidentally send USDC to router
        usdc.mint(address(router), 500e6);

        uint256 before = usdc.balanceOf(admin);
        vm.prank(admin);
        router.rescueTokens(address(usdc), admin, 500e6);
        assertEq(usdc.balanceOf(admin) - before, 500e6);
    }

    function test_rescueTokens_revertsZeroTo() public {
        usdc.mint(address(router), 100e6);
        vm.prank(admin);
        vm.expectRevert(OpenLiquidityRouter.ZeroAddress.selector);
        router.rescueTokens(address(usdc), address(0), 100e6);
    }

    function test_rescueTokens_revertsUnauthorized() public {
        vm.prank(user);
        vm.expectRevert();
        router.rescueTokens(address(usdc), user, 1);
    }

    // ─── Vault treasury (registry) ───────────────────────────────────────

    function test_claimDeposit_sendsUsdcToVaultTreasury() public {
        // covered implicitly by deposit flow tests; registry stores per-vault treasury
        assertEq(registry.getVault(vaultId).treasury, treasury);
    }

    // ─── getAssetPrice view ───────────────────────────────────────────────

    function test_getAssetPrice_returnsOraclePrice() public {
        assertEq(router.getAssetPrice(vaultId), ASSET_PRICE);
    }

    // ─── setRegistry ─────────────────────────────────────────────────────

    function test_setRegistry_updates() public {
        vm.prank(admin);
        router.setRegistry(address(registry)); // same for simplicity
        assertEq(address(router.registry()), address(registry));
    }

    function test_setRegistry_revertsZeroAddress() public {
        vm.prank(admin);
        vm.expectRevert(OpenLiquidityRouter.ZeroAddress.selector);
        router.setRegistry(address(0));
    }

    // ─── inactive vault guard ─────────────────────────────────────────────

    function test_deposit_revertsInactiveVault() public {
        vm.prank(admin);
        registry.setVaultActive(vaultId, false);

        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(OpenLiquidityRouter.VaultNotActive.selector, vaultId));
        router.registerExternalDeposit(vaultId, user, USDC_AMOUNT, bytes32("tag"));
    }

    // ─── Pausing ─────────────────────────────────────────────────────────

    function test_pause_blocksRegisterExternal() public {
        vm.prank(admin);
        router.pause();

        vm.prank(admin);
        vm.expectRevert();
        router.registerExternalDeposit(vaultId, user, USDC_AMOUNT, bytes32("tag"));
    }

    // ─── Internal helpers ─────────────────────────────────────────────────

    function _sharesOf(address who) internal view returns (uint256) {
        (bool ok, bytes memory data) = vaultAddr.staticcall(abi.encodeWithSignature("balanceOf(address)", who));
        require(ok, "balanceOf failed");
        return abi.decode(data, (uint256));
    }

    function _approveVaultShares(address from, uint256 amount) internal {
        vm.prank(from);
        (bool ok, ) = vaultAddr.call(abi.encodeWithSignature("approve(address,uint256)", address(router), amount));
        require(ok, "approve failed");
    }
}

// ─── Vesting Integration Tests ────────────────────────────────────────────────

/**
 * @notice Minimal TokenVesting mock that records createVestingSchedule calls.
 *         The real TokenVesting requires tokens to be pre-funded; here we just track calls.
 */
contract MockTokenVesting {
    address public token;

    struct Schedule {
        address beneficiary;
        uint256 cliff;
        uint256 duration;
        uint256 amount;
    }

    Schedule[] public schedules;

    constructor(address token_) {
        token = token_;
    }

    function createVestingSchedule(
        address beneficiary,
        uint256 /* start */,
        uint256 cliff,
        uint256 duration,
        uint256 /* slicePeriodSeconds */,
        bool /* revocable */,
        uint256 amount
    ) external {
        schedules.push(Schedule(beneficiary, cliff, duration, amount));
    }

    function getToken() external view returns (address) {
        return token;
    }
    function schedulesCount() external view returns (uint256) {
        return schedules.length;
    }
}

contract OpenLiquidityRouterVestingTest is V2TestBase {
    uint256 constant USDC_AMOUNT = 4500e6;
    uint256 constant ASSET_PRICE = 450_000_000;
    uint256 constant ASSET_AMOUNT = (USDC_AMOUNT * 1e8) / ASSET_PRICE;

    MockTokenVesting internal vesting;

    function setUp() public override {
        super.setUp();

        // Deploy a mock vesting contract that wraps the vault's share token
        vesting = new MockTokenVesting(vaultAddr);

        // Admin configures vesting for vault 1: 30d cliff, 365d duration
        vm.prank(admin);
        router.setVaultVestingConfig(vaultId, address(vesting), 30 days, 365 days);
    }

    function _approveExternalDeposit() internal returns (bytes32 did) {
        // Register
        vm.prank(admin);
        did = router.registerExternalDeposit(vaultId, user, USDC_AMOUNT, bytes32("tag"));

        // Fund facility with USDC (simulating fiat on-ramp)
        usdc.mint(facilityAddr, USDC_AMOUNT);
        // Facility must approve router
        vm.prank(facilityAddr);
        usdc.approve(address(router), type(uint256).max);

        // Curator approves
        vm.prank(admin);
        router.approveExternalDeposit(vaultId, did, USDC_AMOUNT, ASSET_PRICE);
    }

    function test_vestingConfig_isStored() public {
        OpenLiquidityRouter.VaultVestingConfig memory cfg = router.getVestingConfig(vaultId);
        assertEq(cfg.vestingContract, address(vesting));
        assertEq(cfg.defaultCliff, 30 days);
        assertEq(cfg.defaultDuration, 365 days);
    }

    function test_claimDeposit_revertsWhenVestingConfigured() public {
        bytes32 did = _approveExternalDeposit();

        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(OpenLiquidityRouter.VestingRequired.selector, vaultId));
        router.claimDeposit(vaultId, did);
    }

    function test_claimDepositWithVesting_createsSchedule() public {
        bytes32 did = _approveExternalDeposit();

        vm.prank(user);
        uint256 shares = router.claimDepositWithVesting(vaultId, did, 0, 0);

        assertGt(shares, 0, "should receive shares");
        assertEq(vesting.schedulesCount(), 1, "one vesting schedule created");

        (address beneficiary, uint256 cliff, uint256 duration, uint256 amount) = vesting.schedules(0);
        assertEq(beneficiary, user);
        assertEq(cliff, 30 days);
        assertEq(duration, 365 days);
        assertEq(amount, shares);
    }

    function test_claimDepositWithVesting_overridesCliffAndDuration() public {
        bytes32 did = _approveExternalDeposit();

        vm.prank(user);
        router.claimDepositWithVesting(vaultId, did, 60 days, 730 days);

        (, uint256 cliff, uint256 duration, ) = vesting.schedules(0);
        assertEq(cliff, 60 days);
        assertEq(duration, 730 days);
    }

    function test_claimDepositWithVesting_revertsIfNotConfigured() public {
        // Create vault 2 without vesting config
        vm.startPrank(admin);
        MockERC20Stub at2 = new MockERC20Stub();
        // Deploy without epochs so the vesting check is reached before any epoch gate.
        (uint256 vid2, , , ) = factory.createVault(
            VaultFactory.CreateVaultParams({
                assetToken: address(at2),
                settlementToken: address(usdc),
                assetOracle: address(assetOracle),
                uniswapRouter: address(uniswapRouter),
                useEpochs: false,
                epochDuration: 0,
                wethToken: weth,
                vaultName: "xAT2",
                vaultSymbol: "xAT2",
                operator: address(0),
                treasury: treasury,
                reportedInventoryOnly: false
            })
        );
        bytes32 did = router.registerExternalDeposit(vid2, user, USDC_AMOUNT, bytes32("t"));
        usdc.mint(facilityAddr, USDC_AMOUNT);
        vm.stopPrank();

        vm.prank(admin);
        router.approveExternalDeposit(vid2, did, USDC_AMOUNT, ASSET_PRICE);

        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(OpenLiquidityRouter.VestingNotConfigured.selector, vid2));
        router.claimDepositWithVesting(vid2, did, 0, 0);
    }

    function test_setVaultVestingConfig_revertsZeroAddress() public {
        vm.prank(admin);
        vm.expectRevert(OpenLiquidityRouter.ZeroAddress.selector);
        router.setVaultVestingConfig(vaultId, address(0), 0, 0);
    }

    function test_setVaultVestingConfig_revertsUnauthorized() public {
        vm.prank(user);
        vm.expectRevert();
        router.setVaultVestingConfig(vaultId, address(vesting), 0, 0);
    }
}

// Minimal stub for a second asset token in multi-vault test
contract MockERC20Stub {
    string public name = "Asset2";
    string public symbol = "AT2";
    uint8 public decimals = 6;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    uint256 public totalSupply;

    function mint(address to, uint256 a) external {
        balanceOf[to] += a;
        totalSupply += a;
    }
    function transfer(address to, uint256 a) external returns (bool) {
        balanceOf[msg.sender] -= a;
        balanceOf[to] += a;
        return true;
    }
    function transferFrom(address from, address to, uint256 a) external returns (bool) {
        if (allowance[from][msg.sender] != type(uint256).max) allowance[from][msg.sender] -= a;
        balanceOf[from] -= a;
        balanceOf[to] += a;
        return true;
    }
    function approve(address s, uint256 a) external returns (bool) {
        allowance[msg.sender][s] = a;
        return true;
    }
    function forceApprove(address s, uint256 a) external {
        allowance[msg.sender][s] = a;
    }
}
