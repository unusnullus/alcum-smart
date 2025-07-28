// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";

import {IUniswapV2Router02} from "@uniswap/v2-periphery/contracts/interfaces/IUniswapV2Router02.sol";

contract Zapper is Ownable, Pausable {
    using SafeERC20 for IERC20;

    IERC20 private _cup;

    IERC4626 private _vault;

    IUniswapV2Router02 private _router;

    mapping(address user => uint256) private _deposits;

    constructor(address cup, address vault, address router) Ownable(_msgSender()) {
        require(cup != address(0), "Invalid CUP address");
        require(vault != address(0), "Invalid Vault address");
        require(router != address(0), "Invalid Router address");

        _cup = IERC20(cup);
        _vault = IERC4626(vault);
        _router = IUniswapV2Router02(router);
    }

    function _tradeForToken(address tokenIn, address tokenOut, uint256 amountIn) internal {
        address[] memory path = new address[](2);
        path[0] = tokenIn;
        path[1] = tokenOut;

        _router.swapExactTokensForTokens(
            amountIn,
            0, // Minimum output (slippage tolerance could be added here)
            path,
            address(this),
            block.timestamp
        );
    }

    function _transferTokenInAndApprove(IERC20 tokenIn, uint256 amount) internal {
        tokenIn.safeTransferFrom(_msgSender(), address(this), amount);

        if (tokenIn.allowance(address(this), router()) < amount) {
            tokenIn.forceApprove(router(), amount);
        }
    }

    function _zapIn(IERC20 tokenIn, uint256 amount) internal {
        if (msg.value == 0) {
            _transferTokenInAndApprove(tokenIn, amount);
        } else {
            require(msg.value == amount, "Incorrect ETH amount");
        }

        _tradeForToken(address(tokenIn), _vault.asset(), amount);
    }

    function zapAndDeposit(IERC20 tokenIn, uint256 amount) external payable whenNotPaused returns (uint256 shares) {
        require(address(tokenIn) != address(0), "Invalid input token address");
        require(amount != 0, "Invalid amount");

        uint256 initialTokenOutBalance = IERC20(_vault.asset()).balanceOf(address(this));

        // Zap
        _zapIn(tokenIn, amount);

        // Deposit
        shares = _vault.deposit(IERC20(_vault.asset()).balanceOf(address(this)) - initialTokenOutBalance, _msgSender());
    }

    /**
     * @dev The `pause` function is used to pause the `VaultZapper` contract.
     */
    function pause() external onlyOwner {
        _pause();
    }

    /**
     * @dev The `unpause` function is used to unpause the `VaultZapper`
     * contract.
     */
    function unpause() external onlyOwner {
        _unpause();
    }

    function router() public view returns (address) {
        return address(_router);
    }
}
