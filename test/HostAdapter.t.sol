// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";

import {CUPToken} from "../contracts/CUPToken.sol";
import {xCUP} from "../contracts/xCUP.sol";
import {Zapper} from "../contracts/Zapper.sol";
import {EpochManager} from "../contracts/EpochManager.sol";
import {HostAdapter} from "../contracts/HostAdapter.sol";
import {CopperPriceConsumerMock} from "../contracts/mock/CopperPriceConsumerMock.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC20Mock} from "../contracts/mock/ERC20Mock.sol";
import {TransparentUpgradeableProxy} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";

contract DummyRouter { function WETH() external pure returns (address) { return address(0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE); } }

contract HostAdapterTest is Test {
    CUPToken private cup;
    xCUP private vault;
    Zapper private zapper;
    EpochManager private epochs;
    HostAdapter private adapter;
    CopperPriceConsumerMock private price;
    DummyRouter private router;
    ERC20Mock private usdc;

    address private owner;
    address private host;
    address private curator;
    address private beneficiary;
    bytes32 private tag;

    function setUp() public {
        owner = address(this);
        host = address(0x1001);
        curator = address(0x1002);
        beneficiary = address(0xBEEF);
        tag = keccak256("ORDER-TEST-1");

        // Core token
        cup = new CUPToken();

        // USDC mock for Silo approvals
        usdc = new ERC20Mock("USDC", "USDC", 6);

        // Deploy implementations
        xCUP vaultImpl = new xCUP();
        EpochManager epochsImpl = new EpochManager();
        Zapper zapperImpl = new Zapper();
        HostAdapter adapterImpl = new HostAdapter();

        // Deploy proxies without init; then call initialize via proxy iface
        vault = xCUP(address(new TransparentUpgradeableProxy(address(vaultImpl), owner, "")));
        epochs = EpochManager(address(new TransparentUpgradeableProxy(address(epochsImpl), owner, "")));
        price = new CopperPriceConsumerMock();

        // Router dummy
        router = new DummyRouter();

        zapper = Zapper(address(new TransparentUpgradeableProxy(address(zapperImpl), owner, "")));

        adapter = HostAdapter(address(new TransparentUpgradeableProxy(address(adapterImpl), owner, "")));

        // Initialize via proxies
        vault.initialize(IERC20(address(cup)), "xCUP", "xCUP");
        epochs.initialize(7 days);
        zapper.initialize(address(cup), address(usdc), address(vault), address(router), address(price), address(epochs));
        adapter.initialize(address(zapper));

        // Wire roles
        // Grant adapter the Zapper integration role
        vm.prank(zapper.owner());
        zapper.grantRole(zapper.HOST_INTEGRATION_ROLE(), address(adapter));
        // Allow adapter to act as curator when forwarding approvals
        vm.prank(zapper.owner());
        zapper.grantRole(zapper.VAULT_CURATOR_ROLE(), address(adapter));

        // Grant operator roles on adapter
        vm.prank(adapter.owner());
        adapter.grantRole(adapter.HOST_OPERATOR_ROLE(), host);
        vm.prank(adapter.owner());
        adapter.grantRole(adapter.CURATOR_OPERATOR_ROLE(), curator);

        // Fund Zapper with CUP for claims
        // Grant MINTER to this test and mint to zapper
        cup.grantRole(cup.MINTER_ROLE(), address(this));
        cup.mint(address(zapper), 1_000_000e6);

        // Start an active epoch: warp beyond duration then start
        vm.warp(block.timestamp + 8 days);
        epochs.nextEpoch();
    }

    function test_registerApproveClaimExternal_byBeneficiary() public {
        uint256 usdcAmount = 1_000e6;
        uint256 priceSnap = 500; // assume CUP per USDC scaling in protocol

        // Host registers external deposit
        vm.prank(host);
        bytes32 depositId = adapter.registerExternalDepositFor(beneficiary, usdcAmount, tag);
        assertTrue(depositId != bytes32(0), "depositId");

        // Curator approves with price snapshot
        vm.prank(curator);
        adapter.approveExternalDepositWithPrice(depositId, usdcAmount, priceSnap);

        // Beneficiary claims
        vm.prank(beneficiary);
        uint256 shares = zapper.claimDeposit(depositId);
        assertGt(shares, 0, "shares");
        assertEq(vault.balanceOf(beneficiary), shares, "vault bal");
    }

    function test_revert_register_without_role() public {
        // Use an address without HOST_OPERATOR_ROLE
        address outsider = address(0xDEAD);
        vm.prank(outsider);
        vm.expectRevert();
        adapter.registerExternalDepositFor(beneficiary, 1_000e6, tag);
    }

    function test_update_beneficiary_before_approval_then_revert_after() public {
        uint256 usdcAmount = 2_000e6;
        vm.prank(host);
        bytes32 depositId = adapter.registerExternalDepositFor(beneficiary, usdcAmount, tag);

        address newBeneficiary = address(0xCAFE);
        vm.prank(host);
        adapter.setDepositBeneficiary(depositId, newBeneficiary);

        vm.prank(curator);
        adapter.approveExternalDepositWithPrice(depositId, usdcAmount, 400);

        // After approval, changing beneficiary should revert
        vm.prank(host);
        vm.expectRevert();
        adapter.setDepositBeneficiary(depositId, address(0xDEAD));

        // Claim to ensure success with updated beneficiary
        vm.prank(newBeneficiary);
        uint256 shares = zapper.claimDeposit(depositId);
        assertGt(shares, 0);
        assertEq(vault.balanceOf(newBeneficiary), shares);
    }

    function test_revert_approve_without_curator_role() public {
        vm.prank(host);
        bytes32 depositId = adapter.registerExternalDepositFor(beneficiary, 500e6, tag);

        // outsider does not have CURATOR_OPERATOR_ROLE on adapter
        address outsider = address(0x1234);
        vm.prank(outsider);
        vm.expectRevert();
        adapter.approveExternalDepositWithPrice(depositId, 500e6, 300);
    }

    function test_revert_claim_by_unauthorized() public {
        vm.prank(host);
        bytes32 depositId = adapter.registerExternalDepositFor(beneficiary, 500e6, tag);
        vm.prank(curator);
        adapter.approveExternalDepositWithPrice(depositId, 500e6, 300);

        // Some other EOA tries to claim
        vm.prank(address(0x9999));
        vm.expectRevert("Not authorized to claim");
        zapper.claimDeposit(depositId);
    }

    function test_revert_claim_when_no_cup_available() public {
        vm.prank(host);
        bytes32 depositId = adapter.registerExternalDepositFor(beneficiary, 100_000e6, tag);
        vm.prank(curator);
        adapter.approveExternalDepositWithPrice(depositId, 100_000e6, 1000);

        // Drain CUP from Zapper
        uint256 zapperCup = cup.balanceOf(address(zapper));
        cup.grantRole(cup.BURNER_ROLE(), address(this));
        cup.burn(address(zapper), zapperCup);

        vm.prank(beneficiary);
        vm.expectRevert("Insufficient CUP balance");
        zapper.claimDeposit(depositId);
    }
}


