// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {CUPToken} from "../../contracts/CUPToken.sol";
import {EpochManager} from "../../contracts/EpochManager.sol";
import {IEpochManager} from "../../contracts/v2/interfaces/IEpochManager.sol";

import {IAssetOracle} from "../../contracts/v2/interfaces/IAssetOracle.sol";

import {RWAVault} from "../../contracts/v2/RWAVault.sol";
import {CapitalFacility} from "../../contracts/v2/CapitalFacility.sol";
import {RFQEngine} from "../../contracts/v2/RFQEngine.sol";
import {VaultRegistry} from "../../contracts/v2/VaultRegistry.sol";
import {VaultFactory} from "../../contracts/v2/VaultFactory.sol";
import {OpenLiquidityRouter} from "../../contracts/v2/OpenLiquidityRouter.sol";
import {SharedSettlementEngine} from "../../contracts/v2/SharedSettlementEngine.sol";

// ─── MOCKS ────────────────────────────────────────────────────────────────────

/// @dev Minimal ERC-20 with mint() — used as both USDC and asset tokens.
contract MockERC20 {
    string public name;
    string public symbol;
    uint8 public decimals;

    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    uint256 public totalSupply;

    constructor(string memory n, string memory s, uint8 d) {
        name = n;
        symbol = s;
        decimals = d;
    }

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
        totalSupply += amount;
    }

    function burn(address from, uint256 amount) external {
        require(allowance[from][msg.sender] >= amount || from == msg.sender, "ERC20: burn allowance");
        if (from != msg.sender) allowance[from][msg.sender] -= amount;
        balanceOf[from] -= amount;
        totalSupply -= amount;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        if (allowance[from][msg.sender] != type(uint256).max) {
            require(allowance[from][msg.sender] >= amount, "ERC20: allowance");
            allowance[from][msg.sender] -= amount;
        }
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function forceApprove(address spender, uint256 amount) external {
        allowance[msg.sender][spender] = amount;
    }
}

/// @dev Generic price oracle mock — implements IAssetOracle.
contract MockAssetOracle is IAssetOracle {
    uint256 public price; // 8 dec (e.g. 450_000_000 = $4.50)
    string private _desc;

    constructor(uint256 initialPrice, string memory desc) {
        price = initialPrice;
        _desc = desc;
    }

    function decimals() external pure override returns (uint8) {
        return 8;
    }
    function description() external view override returns (string memory) {
        return _desc;
    }
    function updatedAt() external view override returns (uint256) {
        return block.timestamp;
    }

    function setPrice(uint256 p) external {
        price = p;
    }
}

/// @dev Uniswap V2 router mock — 1:1 swap rate.
contract MockUniswapRouter {
    address public immutable WETH_;
    constructor(address weth) {
        WETH_ = weth;
    }
    function WETH() external view returns (address) {
        return WETH_;
    }

    function getAmountsOut(uint256 amountIn, address[] calldata) external pure returns (uint256[] memory amounts) {
        amounts = new uint256[](2);
        amounts[0] = amountIn;
        amounts[1] = amountIn;
    }

    function swapExactTokensForTokens(
        uint256 amountIn,
        uint256,
        address[] calldata,
        address to,
        uint256
    ) external returns (uint256[] memory amounts) {
        amounts = new uint256[](2);
        amounts[0] = amountIn;
        amounts[1] = amountIn;
        // Caller pre-funds the `to` address with MockERC20.mint in tests
    }

    function swapExactETHForTokens(
        uint256,
        address[] calldata,
        address,
        uint256
    ) external payable returns (uint256[] memory amounts) {
        amounts = new uint256[](2);
        amounts[0] = msg.value;
        amounts[1] = msg.value;
    }
}

// ─── BASE TEST ────────────────────────────────────────────────────────────────

contract V2TestBase is Test {
    address internal admin = makeAddr("admin");
    address internal curator = makeAddr("curator");
    address internal user = makeAddr("user");
    address internal user2 = makeAddr("user2");
    address internal treasury = makeAddr("treasury");
    address internal weth = makeAddr("weth");
    address internal marketMaker = makeAddr("marketMaker");

    // ── Mocks ──────────────────────────────────────────────────────────────
    MockERC20 internal usdc;
    MockERC20 internal assetToken; // generic RWA token (was CUP)
    MockAssetOracle internal assetOracle;
    MockUniswapRouter internal uniswapRouter;

    // ── Existing v1 contracts (reused) ────────────────────────────────────
    CUPToken internal cup; // kept for copper-specific tests
    EpochManager internal epochManagerImpl; // v1 EpochManager used as proxy implementation

    // ── v2 contracts ──────────────────────────────────────────────────────
    VaultRegistry internal registry;
    VaultFactory internal factory;
    OpenLiquidityRouter internal router;
    RFQEngine internal rfqEngine;
    SharedSettlementEngine internal settlement;

    RWAVault internal rwavaultImpl;
    CapitalFacility internal capitalFacilityImpl;

    uint256 internal vaultId;
    address internal vaultAddr;
    address internal facilityAddr;
    address internal epochManagerAddr; // per-vault EpochManager deployed by factory

    function setUp() public virtual {
        vm.startPrank(admin);

        // ── External mocks ──────────────────────────────────────────────────
        usdc = new MockERC20("USD Coin", "USDC", 6);
        assetToken = new MockERC20("Generic RWA Token", "GRWA", 6);
        assetOracle = new MockAssetOracle(450_000_000, "GRWA / USD"); // $4.50
        uniswapRouter = new MockUniswapRouter(weth);

        // ── (Optional) CUPToken from v1 ─────────────────────────────────────
        cup = CUPToken(
            address(new ERC1967Proxy(address(new CUPToken()), abi.encodeWithSelector(CUPToken.initialize.selector)))
        );

        // ── EpochManager implementation (shared by all per-vault proxies) ───
        epochManagerImpl = new EpochManager();

        // ── VaultRegistry ──────────────────────────────────────────────────
        registry = VaultRegistry(
            address(
                new ERC1967Proxy(
                    address(new VaultRegistry()),
                    abi.encodeWithSelector(VaultRegistry.initialize.selector, admin)
                )
            )
        );

        // ── OpenLiquidityRouter ────────────────────────────────────────────
        router = OpenLiquidityRouter(
            address(
                new ERC1967Proxy(
                    address(new OpenLiquidityRouter()),
                    abi.encodeWithSelector(OpenLiquidityRouter.initialize.selector, address(registry), admin)
                )
            )
        );
        router.grantRole(router.VAULT_CURATOR_ROLE(), curator);
        router.grantRole(router.HOST_INTEGRATION_ROLE(), admin);

        // ── RFQEngine ──────────────────────────────────────────────────────
        rfqEngine = RFQEngine(
            address(
                new ERC1967Proxy(
                    address(new RFQEngine()),
                    abi.encodeWithSelector(RFQEngine.initialize.selector, address(registry), admin)
                )
            )
        );
        rfqEngine.registerMarketMaker(marketMaker, true);

        // ── SharedSettlementEngine ─────────────────────────────────────────
        // Deploy before VaultFactory so we can pass its address to the factory initializer.
        settlement = SharedSettlementEngine(
            address(
                new ERC1967Proxy(
                    address(new SharedSettlementEngine()),
                    abi.encodeWithSelector(
                        SharedSettlementEngine.initialize.selector,
                        address(registry),
                        uint256(600), // 6%
                        admin
                    )
                )
            )
        );

        // ── VaultFactory ───────────────────────────────────────────────────
        rwavaultImpl = new RWAVault();
        capitalFacilityImpl = new CapitalFacility();

        factory = VaultFactory(
            address(
                new ERC1967Proxy(
                    address(new VaultFactory()),
                    abi.encodeWithSelector(
                        VaultFactory.initialize.selector,
                        address(registry),
                        address(rwavaultImpl),
                        address(capitalFacilityImpl),
                        address(epochManagerImpl),
                        address(router),
                        address(rfqEngine),
                        address(settlement)
                    )
                )
            )
        );

        // Grant factory FACTORY_ROLE in registry
        registry.grantRole(registry.FACTORY_ROLE(), address(factory));

        // ── Create first vault (generic RWA, not copper-specific) ──────────
        // Factory auto-deploys a per-vault EpochManager proxy.
        (vaultId, vaultAddr, facilityAddr, epochManagerAddr) = factory.createVault(
            VaultFactory.CreateVaultParams({
                assetToken: address(assetToken),
                settlementToken: address(usdc),
                assetOracle: address(assetOracle),
                uniswapRouter: address(uniswapRouter),
                useEpochs: true,
                epochDuration: 600,
                wethToken: weth,
                vaultName: "xGRWA Vault",
                vaultSymbol: "xGRWA",
                operator: address(0),
                treasury: treasury,
                reportedInventoryOnly: false
            })
        );

        // Grant settlement + router MINTER_ROLE on assetToken
        assetToken.mint(address(settlement), 0); // just to confirm it works
        // In real usage, assetToken.MINTER_ROLE() is granted to settlement + router
        // Here we use the unrestricted MockERC20.mint directly in tests

        // Wire EpochManager: grant EPOCH_MANAGER_ROLE to admin and settlement so tests can advance epochs.
        // The factory relinquishes EPOCH_MANAGER_ROLE after createVault; admin holds DEFAULT_ADMIN_ROLE.
        EpochManager em = EpochManager(epochManagerAddr);
        bytes32 epochManagerRole = em.EPOCH_MANAGER_ROLE();
        em.grantRole(epochManagerRole, admin);
        em.grantRole(epochManagerRole, address(settlement));

        // Advance past the initial epoch (epoch 0 → epoch 1) so tests can record revenue
        // for epoch 1 (epoch 0 is rejected as ZeroEpochId).
        vm.warp(block.timestamp + 601);
        em.nextEpoch(); // currentEpochId is now 1

        vm.stopPrank();
    }

    // ─── Helpers ──────────────────────────────────────────────────────────

    function _mintUsdc(address to, uint256 amount) internal {
        usdc.mint(to, amount);
    }

    function _fundFacility(uint256 amount) internal {
        usdc.mint(facilityAddr, amount);
    }

    function _endCurrentEpoch() internal {
        EpochManager em = EpochManager(epochManagerAddr);
        uint256 left = em.timeLeftInEpoch();
        if (left > 0) {
            vm.warp(block.timestamp + left + 1);
        }
    }

    function _mintAsset(address to, uint256 amount) internal {
        assetToken.mint(to, amount);
    }
}
