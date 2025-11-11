// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test, console} from "forge-std/Test.sol";
import {PermitLib} from "../contracts/libraries/PermitLib.sol";
import {ERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

// Mock ERC20Permit token for testing
contract MockERC20Permit is ERC20Permit {
    constructor() ERC20("TestToken", "TEST") ERC20Permit("TestToken") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

// Mock ERC20Permit token that sets wrong allowance after permit (for testing PermitFailed)
contract MockERC20PermitWrongAllowance is ERC20Permit {
    constructor() ERC20("TestToken2", "TEST2") ERC20Permit("TestToken2") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    // Override permit to set wrong allowance
    function permit(
        address owner,
        address spender,
        uint256 value,
        uint256 deadline,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) public override {
        super.permit(owner, spender, value, deadline, v, r, s);
        // Intentionally set wrong allowance to trigger PermitFailed
        _approve(owner, spender, value - 1);
    }
}

/**
 * @title TestContract
 * @notice Test contract that uses PermitLib to test library functions
 */
contract TestContract {
    function execPermit(
        IERC20 token,
        address owner,
        address spender,
        PermitLib.PermitParams calldata permitParams
    ) external {
        PermitLib.execPermit(token, owner, spender, permitParams);
    }
}

contract PermitLibTest is Test {
    TestContract public testContract;
    MockERC20Permit public token;
    address public owner;
    address public spender;

    function setUp() public {
        testContract = new TestContract();
        token = new MockERC20Permit();
        owner = makeAddr("owner");
        spender = makeAddr("spender");

        // Mint tokens to owner
        token.mint(owner, 1000 * 10 ** 18);
    }

    // ───────────────────────────── EXEC PERMIT TESTS ─────────────────────────────

    function testExecPermit() public {
        uint256 amount = 100 * 10 ** 18;
        uint256 deadline = block.timestamp + 1 days;

        // Use vm.sign to create a proper signature
        uint256 privateKey = 0x1234567890123456789012345678901234567890123456789012345678901234;
        address signer = vm.addr(privateKey);

        // Mint tokens to signer instead
        token.mint(signer, amount);

        // Create permit signature using vm.sign
        bytes32 structHash = keccak256(
            abi.encode(
                keccak256("Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)"),
                signer,
                address(testContract),
                amount,
                token.nonces(signer),
                deadline
            )
        );

        bytes32 hash = keccak256(abi.encodePacked("\x19\x01", token.DOMAIN_SEPARATOR(), structHash));

        (uint8 v, bytes32 r, bytes32 s) = vm.sign(privateKey, hash);

        PermitLib.PermitParams memory permitParams = PermitLib.PermitParams({
            value: amount,
            deadline: deadline,
            v: v,
            r: r,
            s: s
        });

        // Execute permit
        testContract.execPermit(token, signer, address(testContract), permitParams);

        // Check that allowance was set
        assertEq(token.allowance(signer, address(testContract)), amount);
    }

    function testExecPermitInvalidSignature() public {
        uint256 amount = 100 * 10 ** 18;
        uint256 deadline = block.timestamp + 1 days;

        PermitLib.PermitParams memory permitParams = PermitLib.PermitParams({
            value: amount,
            deadline: deadline,
            v: 27,
            r: bytes32(uint256(1)),
            s: bytes32(uint256(2))
        });

        // Should revert due to invalid signature
        vm.expectRevert();
        testContract.execPermit(token, owner, address(testContract), permitParams);
    }

    function testExecPermitExpiredDeadline() public {
        uint256 amount = 100 * 10 ** 18;
        uint256 deadline = block.timestamp - 1; // Expired

        uint256 privateKey = 0x1234567890123456789012345678901234567890123456789012345678901234;
        address signer = vm.addr(privateKey);

        token.mint(signer, amount);

        // Create permit signature
        bytes32 structHash = keccak256(
            abi.encode(
                keccak256("Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)"),
                signer,
                address(testContract),
                amount,
                token.nonces(signer),
                deadline
            )
        );

        bytes32 hash = keccak256(abi.encodePacked("\x19\x01", token.DOMAIN_SEPARATOR(), structHash));

        (uint8 v, bytes32 r, bytes32 s) = vm.sign(privateKey, hash);

        PermitLib.PermitParams memory permitParams = PermitLib.PermitParams({
            value: amount,
            deadline: deadline,
            v: v,
            r: r,
            s: s
        });

        // Should revert due to expired deadline
        vm.expectRevert();
        testContract.execPermit(token, signer, address(testContract), permitParams);
    }

    function testExecPermitWrongAmount() public {
        uint256 permitAmount = 100 * 10 ** 18;
        uint256 actualAmount = 200 * 10 ** 18; // Different amount
        uint256 deadline = block.timestamp + 1 days;

        uint256 privateKey = 0x1234567890123456789012345678901234567890123456789012345678901234;
        address signer = vm.addr(privateKey);

        token.mint(signer, actualAmount);

        // Create permit signature for permitAmount
        bytes32 structHash = keccak256(
            abi.encode(
                keccak256("Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)"),
                signer,
                address(testContract),
                permitAmount, // Signature is for permitAmount
                token.nonces(signer),
                deadline
            )
        );

        bytes32 hash = keccak256(abi.encodePacked("\x19\x01", token.DOMAIN_SEPARATOR(), structHash));

        (uint8 v, bytes32 r, bytes32 s) = vm.sign(privateKey, hash);

        PermitLib.PermitParams memory permitParams = PermitLib.PermitParams({
            value: actualAmount, // Wrong amount - different from permitAmount
            deadline: deadline,
            v: v,
            r: r,
            s: s
        });

        // Should revert because permit was for different amount
        vm.expectRevert();
        testContract.execPermit(token, signer, address(testContract), permitParams);
    }

    function testExecPermitFailed() public {
        // Test PermitFailed error when allowance doesn't match after permit
        MockERC20PermitWrongAllowance wrongToken = new MockERC20PermitWrongAllowance();
        uint256 amount = 100 * 10 ** 18;
        uint256 deadline = block.timestamp + 1 days;

        uint256 privateKey = 0x1234567890123456789012345678901234567890123456789012345678901234;
        address signer = vm.addr(privateKey);

        wrongToken.mint(signer, amount);

        // Create permit signature
        bytes32 structHash = keccak256(
            abi.encode(
                keccak256("Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)"),
                signer,
                address(testContract),
                amount,
                wrongToken.nonces(signer),
                deadline
            )
        );

        bytes32 hash = keccak256(abi.encodePacked("\x19\x01", wrongToken.DOMAIN_SEPARATOR(), structHash));

        (uint8 v, bytes32 r, bytes32 s) = vm.sign(privateKey, hash);

        PermitLib.PermitParams memory permitParams = PermitLib.PermitParams({
            value: amount,
            deadline: deadline,
            v: v,
            r: r,
            s: s
        });

        // Should revert with PermitFailed because allowance will be wrong after permit
        vm.expectRevert(PermitLib.PermitFailed.selector);
        testContract.execPermit(wrongToken, signer, address(testContract), permitParams);
    }
}
