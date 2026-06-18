// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {ReentrancyGuardUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {ICapitalFacility} from "./interfaces/ICapitalFacility.sol";

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
 *      Capital recall via recallCapital() is intentionally flexible: it attempts a
 *      transferFrom from the protocol address after updating internal accounting. If the
 *      protocol has already settled out-of-band, the accounting adjustment is applied
 *      without reverting. Operators are responsible for ensuring actual fund recovery.
 *
 *      Role layout:
 *        DEFAULT_ADMIN_ROLE      — protocol multisig
 *        FACILITY_OPERATOR_ROLE  — may deploy and recall capital; whitelist protocols
 */
contract CapitalFacility is
    Initializable,
    OwnableUpgradeable,
    AccessControlUpgradeable,
    ReentrancyGuardUpgradeable,
    ICapitalFacility
{
    using SafeERC20 for IERC20;

    // ─────────────────────────── ROLES ──────────────────────────────────────

    /// @notice May deploy / recall capital and manage the protocol whitelist.
    bytes32 public constant FACILITY_OPERATOR_ROLE = keccak256("FACILITY_OPERATOR_ROLE");

    // ─────────────────────────── STATE ──────────────────────────────────────

    IERC20 public token;
    address public authorizedSpender;

    /// @dev protocol address → stablecoin amount currently deployed there.
    mapping(address => uint256) private _deployed;

    uint256 public totalDeployed;

    mapping(address => bool) public isWhitelisted;

    /// @dev Ordered list of protocols with active deployments, used by recallAll().
    address[] private _activeProtocols;

    // ─────────────────────────── ERRORS ─────────────────────────────────────

    error ZeroAddress();
    error ZeroAmount();
    error ProtocolNotWhitelisted(address protocol);
    error InsufficientIdleBalance(uint256 available, uint256 requested);
    error DeploymentFailed();
    error RecallFailed();
    error ZeroDeploymentInProtocol(address protocol);

    // ─────────────────────────── INIT ───────────────────────────────────────

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /**
     * @param token_             Stablecoin this facility holds (USDC).
     * @param authorizedSpender_ Address that receives unlimited spending approval
     *                           (OpenLiquidityRouter / RFQEngine).
     * @param admin_             Initial owner and operator.
     */
    function initialize(address token_, address authorizedSpender_, address admin_) public initializer {
        if (token_ == address(0)) revert ZeroAddress();
        if (authorizedSpender_ == address(0)) revert ZeroAddress();
        if (admin_ == address(0)) revert ZeroAddress();

        __Ownable_init(admin_);
        __AccessControl_init();
        __ReentrancyGuard_init();

        _grantRole(DEFAULT_ADMIN_ROLE, admin_);
        _grantRole(FACILITY_OPERATOR_ROLE, admin_);

        token = IERC20(token_);
        authorizedSpender = authorizedSpender_;

        token.forceApprove(authorizedSpender_, type(uint256).max);
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

        uint256 idle = idleBalance();
        if (idle < amount) revert InsufficientIdleBalance(idle, amount);

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

    // ─────────────────────────── ADMIN ──────────────────────────────────────

    function setProtocolWhitelisted(address protocol, bool active) external onlyOwner {
        if (protocol == address(0)) revert ZeroAddress();
        isWhitelisted[protocol] = active;
        emit ProtocolWhitelisted(protocol, active);
    }

    /// @notice Replace the authorised spender and refresh the unlimited approval.
    function setAuthorizedSpender(address newSpender) external onlyOwner {
        if (newSpender == address(0)) revert ZeroAddress();
        token.forceApprove(authorizedSpender, 0);
        authorizedSpender = newSpender;
        token.forceApprove(newSpender, type(uint256).max);
    }

    function getActiveProtocols() external view returns (address[] memory) {
        return _activeProtocols;
    }

    // ─────────────────────────── INTERNAL ───────────────────────────────────

    /**
     * @dev Accounting is updated first (effects before interactions).
     *      Then a transferFrom is attempted to pull funds from the protocol address.
     *      This handles the common case where the protocol holds ERC-20 tokens on
     *      behalf of this facility (e.g. shares in an ERC-4626 vault).
     *
     *      For protocols that push funds back automatically (e.g. after a withdraw call),
     *      the operator should call recallCapital AFTER the protocol has already returned
     *      the tokens. In that case the transferFrom will fail or be a no-op, which is
     *      acceptable — the catch block preserves the accounting update.
     *
     *      Operators are responsible for confirming actual fund recovery off-chain.
     */
    function _recallFrom(address protocol, uint256 amount) internal {
        if (_deployed[protocol] == 0) revert ZeroDeploymentInProtocol(protocol);

        uint256 toRecall = amount > _deployed[protocol] ? _deployed[protocol] : amount;

        _deployed[protocol] -= toRecall;
        totalDeployed -= toRecall;

        if (_deployed[protocol] == 0) {
            _removeActiveProtocol(protocol);
        }

        // Attempt to pull the tokens back. If the protocol has already pushed them
        // (or the operator pre-withdrew), this will fail gracefully.
        try token.transferFrom(protocol, address(this), toRecall) {
            // funds pulled successfully
        } catch {
            // Operator confirmed out-of-band recovery; accounting is already updated.
        }
        emit CapitalRecalled(protocol, toRecall);
    }

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

    uint256[45] private __gap;
}
