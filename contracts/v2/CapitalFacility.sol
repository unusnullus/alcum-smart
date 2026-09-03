// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {ReentrancyGuardUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {ICapitalFacility} from "./interfaces/ICapitalFacility.sol";
import {ICommittedLiquidityRouter} from "./interfaces/ICommittedLiquidityRouter.sol";

/**
 * @title CapitalFacility
 * @notice Per-vault stablecoin liquidity buffer with optional yield deployment.
 *
 * @dev Holds USDC (or another stablecoin) and grants unlimited spending approval to a
 *      designated authorised spender (typically OpenLiquidityRouter). This ensures that
 *      redemption payouts can always be pulled without an extra approval transaction.
 *
 *      FACILITY_OPERATOR_ROLE holders may deploy idle stablecoin into whitelisted
 *      external protocols (e.g. Morpho, Aave, Euler) to earn yield between settlement
 *      events. Before approving any redemption payout, operators must recall sufficient
 *      capital so that idleBalance() covers the obligation.
 *
 *      Capital recall:
 *        - recallCapital() pulls via transferFrom and reverts unless idle balance
 *          increases by the recalled amount.
 *        - acknowledgeCapitalRecall() updates accounting when a push-based protocol
 *          has already returned tokens to this contract (operator must fund idle first).
 *
 *      Role layout:
 *        DEFAULT_ADMIN_ROLE      — vault issuer admin (also initial `owner`)
 *        FACILITY_OPERATOR_ROLE  — may deploy and recall capital (whitelisted targets only)
 *        owner                   — protocol whitelist, authorizedSpender rotation, UUPS upgrade
 *
 *      `owner` (Ownable) and DEFAULT_ADMIN_ROLE can diverge after role grants.
 *      Keep them on the same address unless a split-admin setup is intentional.
 *
 *      `authorizedSpender` (typically OpenLiquidityRouter) holds unlimited allowance to
 *      pull idle tokens for approved redemption payouts.
 */
contract CapitalFacility is
    Initializable,
    OwnableUpgradeable,
    AccessControlUpgradeable,
    ReentrancyGuardUpgradeable,
    UUPSUpgradeable,
    ICapitalFacility
{
    using SafeERC20 for IERC20;

    // ─────────────────────────── ROLES ──────────────────────────────────────

    /// @notice May deploy / recall capital and manage the protocol whitelist.
    bytes32 public constant FACILITY_OPERATOR_ROLE = keccak256("FACILITY_OPERATOR_ROLE");

    // ─────────────────────────── STATE ──────────────────────────────────────

    IERC20 public token;
    address public authorizedSpender;
    uint256 public vaultId;

    /// @dev protocol address → stablecoin amount currently deployed there.
    mapping(address => uint256) private _deployed;

    uint256 public totalDeployed;

    mapping(address => bool) public isWhitelisted;

    /// @dev Ordered list of protocols with active deployments, used by recallAll().
    address[] private _activeProtocols;

    /// @notice Maximum calldata length accepted by {deployCapital}.
    uint256 public constant MAX_DEPLOY_CALLDATA = 4096;

    // ─────────────────────────── ERRORS ─────────────────────────────────────

    error ZeroAddress();
    error ZeroAmount();
    error ProtocolNotWhitelisted(address protocol);
    error InsufficientIdleBalance(uint256 available, uint256 requested);
    error InsufficientUncommittedIdle(uint256 available, uint256 requested);
    error DeploymentFailed();
    error RecallFailed();
    error CalldataTooLong();
    error ZeroDeploymentInProtocol(address protocol);
    error VaultIdAlreadySet();

    // ─────────────────────────── EVENTS ─────────────────────────────────────

    /// @notice Emitted when the unlimited spender is rotated.
    event AuthorizedSpenderUpdated(address indexed previous, address indexed current);

    // ─────────────────────────── INIT ───────────────────────────────────────

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /**
     * @notice Initialize the facility proxy. Can be called only once.
     * @param token_             Stablecoin this facility holds (e.g. USDC).
     * @param authorizedSpender_ Address that receives unlimited spending approval
     *                           (typically OpenLiquidityRouter).
     * @param admin_             Initial owner, DEFAULT_ADMIN_ROLE and FACILITY_OPERATOR_ROLE.
     */
    function initialize(address token_, address authorizedSpender_, address admin_) public initializer {
        if (token_ == address(0)) revert ZeroAddress();
        if (authorizedSpender_ == address(0)) revert ZeroAddress();
        if (admin_ == address(0)) revert ZeroAddress();

        __Ownable_init(admin_);
        __AccessControl_init();
        __ReentrancyGuard_init();
        __UUPSUpgradeable_init();

        _grantRole(DEFAULT_ADMIN_ROLE, admin_);
        _grantRole(FACILITY_OPERATOR_ROLE, admin_);

        token = IERC20(token_);
        authorizedSpender = authorizedSpender_;

        token.forceApprove(authorizedSpender_, type(uint256).max);
    }

    /**
     * @notice Bind this facility to its registry vault id.
     * @dev Called once by VaultFactory immediately after registerVault. Factory is the initial owner.
     */
    function setVaultId(uint256 vaultId_) external onlyOwner {
        if (vaultId != 0) revert VaultIdAlreadySet();
        vaultId = vaultId_;
    }

    // ─────────────────────────── ICapitalFacility ───────────────────────────

    /// @inheritdoc ICapitalFacility
    function idleBalance() public view override returns (uint256) {
        return token.balanceOf(address(this));
    }

    /// @inheritdoc ICapitalFacility
    function totalBalance() public view override returns (uint256) {
        return idleBalance() + totalDeployed;
    }

    /// @inheritdoc ICapitalFacility
    function deployedIn(address protocol) external view override returns (uint256) {
        return _deployed[protocol];
    }

    /**
     * @inheritdoc ICapitalFacility
     * @dev `data` is forwarded as a raw call to `protocol` after the token transfer,
     *      enabling support for protocols that require an explicit deposit invocation
     *      (e.g. Morpho supply, Aave deposit). Pass `data = ""` for simple ERC-20 custody.
     *      IMPORTANT: the caller must encode `data` correctly for the target protocol.
     */
    function deployCapital(
        address protocol,
        uint256 amount,
        bytes calldata data
    ) external override onlyRole(FACILITY_OPERATOR_ROLE) nonReentrant {
        if (protocol == address(0)) revert ZeroAddress();
        if (amount == 0) revert ZeroAmount();
        if (!isWhitelisted[protocol]) revert ProtocolNotWhitelisted(protocol);
        if (data.length > MAX_DEPLOY_CALLDATA) revert CalldataTooLong();

        uint256 idle = idleBalance();
        if (idle < amount) revert InsufficientIdleBalance(idle, amount);

        uint256 committed = vaultId == 0
            ? 0
            : ICommittedLiquidityRouter(authorizedSpender).getCommittedLiability(vaultId);
        uint256 available = idle > committed ? idle - committed : 0;
        if (available < amount) revert InsufficientUncommittedIdle(available, amount);

        token.safeTransfer(protocol, amount);

        if (data.length > 0) {
            (bool ok, ) = protocol.call(data);
            if (!ok) revert DeploymentFailed();
        }

        if (_deployed[protocol] == 0) {
            _activeProtocols.push(protocol);
        }
        _deployed[protocol] += amount;
        totalDeployed += amount;

        emit CapitalDeployed(protocol, amount);
    }

    /// @inheritdoc ICapitalFacility
    function recallCapital(
        address protocol,
        uint256 amount
    ) external override onlyRole(FACILITY_OPERATOR_ROLE) nonReentrant {
        _recallFrom(protocol, amount);
    }

    /// @inheritdoc ICapitalFacility
    function recallAll() external override onlyRole(FACILITY_OPERATOR_ROLE) nonReentrant {
        address[] memory protocols = _activeProtocols;
        for (uint256 i; i < protocols.length; i++) {
            uint256 dep = _deployed[protocols[i]];
            if (dep > 0) {
                _recallFrom(protocols[i], dep);
            }
        }
    }

    /**
     * @notice Sync accounting after a push-based protocol returned tokens to idle balance.
     * @dev Use when the protocol sends stablecoin back directly (no transferFrom approval).
     *      Requires `idleBalance() >= amount` so redemption liquidity is actually present.
     * @param protocol Whitelisted protocol whose deployed balance is being reduced.
     * @param amount   Amount to deduct from `_deployed[protocol]`.
     */
    function acknowledgeCapitalRecall(
        address protocol,
        uint256 amount
    ) external onlyRole(FACILITY_OPERATOR_ROLE) nonReentrant {
        if (amount == 0) revert ZeroAmount();
        if (_deployed[protocol] == 0) revert ZeroDeploymentInProtocol(protocol);

        uint256 toAck = amount > _deployed[protocol] ? _deployed[protocol] : amount;
        if (idleBalance() < toAck) revert InsufficientIdleBalance(idleBalance(), toAck);

        _deployed[protocol] -= toAck;
        totalDeployed -= toAck;

        if (_deployed[protocol] == 0) {
            _removeActiveProtocol(protocol);
        }

        emit CapitalRecalled(protocol, toAck);
    }

    // ─────────────────────────── ADMIN ──────────────────────────────────────

    /**
     * @notice Allow or revoke a yield protocol as a deployCapital target.
     * @dev Whitelisting does not move funds. Only whitelisted protocols may receive
     *      {deployCapital} transfers. Revoking a protocol does not auto-recall existing deployments.
     * @param protocol Target protocol address.
     * @param active   True to whitelist, false to revoke.
     */
    function setProtocolWhitelisted(address protocol, bool active) external onlyOwner {
        if (protocol == address(0)) revert ZeroAddress();
        isWhitelisted[protocol] = active;
        emit ProtocolWhitelisted(protocol, active);
    }

    /**
     * @notice Replace the authorised spender and refresh the unlimited approval.
     * @dev Previous spender allowance is reset to 0 before the new unlimited approve.
     */
    function setAuthorizedSpender(address newSpender) external onlyOwner nonReentrant {
        if (newSpender == address(0)) revert ZeroAddress();
        address previous = authorizedSpender;
        token.forceApprove(previous, 0);
        authorizedSpender = newSpender;
        token.forceApprove(newSpender, type(uint256).max);
        emit AuthorizedSpenderUpdated(previous, newSpender);
    }

    /// @notice Protocols that currently have a non-zero `_deployed` balance.
    function getActiveProtocols() external view returns (address[] memory) {
        return _activeProtocols;
    }

    // ─────────────────────────── INTERNAL ───────────────────────────────────

    /**
     * @dev Pulls tokens from `protocol` via transferFrom, then updates accounting.
     *      Reverts with {RecallFailed} unless idle balance increases by `toRecall`.
     *      For push-based withdrawals use {acknowledgeCapitalRecall} instead.
     */
    function _recallFrom(address protocol, uint256 amount) internal {
        if (_deployed[protocol] == 0) revert ZeroDeploymentInProtocol(protocol);

        uint256 toRecall = amount > _deployed[protocol] ? _deployed[protocol] : amount;
        uint256 balBefore = idleBalance();

        try token.transferFrom(protocol, address(this), toRecall) {} catch {}
        if (idleBalance() - balBefore < toRecall) revert RecallFailed();

        _deployed[protocol] -= toRecall;
        totalDeployed -= toRecall;

        if (_deployed[protocol] == 0) {
            _removeActiveProtocol(protocol);
        }

        emit CapitalRecalled(protocol, toRecall);
    }

    /// @dev Swap-and-pop from `_activeProtocols`. No-op if `protocol` is not listed.
    function _removeActiveProtocol(address protocol) internal {
        address[] storage arr = _activeProtocols;
        for (uint256 i; i < arr.length; i++) {
            if (arr[i] == protocol) {
                arr[i] = arr[arr.length - 1];
                arr.pop();
                return;
            }
        }
    }

    /// @dev Only the owner (vault issuer admin) may authorize an implementation upgrade.
    function _authorizeUpgrade(address) internal override onlyOwner {}

    /**
     * @dev Storage gap for future variable additions. Reduce this size by the number
     *      of slots added in subsequent upgrades.
     */
    uint256[44] private __gap;
}
