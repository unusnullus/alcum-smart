// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";

/**
 * @title PermitLib
 * @notice External library for handling ERC20 permit operations in Zapper.
 * @dev Keeps Zapper bytecode small by moving permit logic here.
 *      Enables gasless token approvals via EIP-2612.
 */
library PermitLib {
    // ───────────────────────────── STRUCTS ─────────────────────────────

    struct PermitParams {
        uint256 value;
        uint256 deadline;
        uint8 v;
        bytes32 r;
        bytes32 s;
    }

    // ───────────────────────────── ERRORS ─────────────────────────────

    error PermitFailed();

    // ───────────────────────────── PERMIT OPERATIONS ─────────────────────────────

    /**
     * @notice Executes an ERC20 permit for gasless token approvals
     * @param token The ERC20Permit token contract
     * @param owner The token owner granting the approval
     * @param spender The address receiving the approval (typically this contract)
     * @param permitParams The permit signature components and parameters
     */
    function execPermit(IERC20 token, address owner, address spender, PermitParams calldata permitParams) external {
        ERC20Permit(address(token)).permit(
            owner,
            spender,
            permitParams.value,
            permitParams.deadline,
            permitParams.v,
            permitParams.r,
            permitParams.s
        );
        if (token.allowance(owner, spender) != permitParams.value) {
            revert PermitFailed();
        }
    }
}
