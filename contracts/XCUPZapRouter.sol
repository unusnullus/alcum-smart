// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {ReentrancyGuardUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {IERC20} from "@openzeppelin/contracts/interfaces/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IUniswapRouterV2} from "./interfaces/IUniswapRouterV2.sol";
import {IXCUPRatePool} from "./interfaces/IXCUPRatePool.sol";
import {IWETH} from "./interfaces/IWETH.sol";

/**
 * @title XCUP Zap Router
 * @notice Classic zap for swapping XCUP to any token and vice versa via Uniswap
 * @dev Uses two-step process:
 *      - XCUP -> Token: XCUP -> USDC (via XCUPOraclePool) -> Target Token (via Uniswap)
 *      - Token -> XCUP: Token -> USDC (via Uniswap) -> XCUP (via XCUPOraclePool)
 */
contract XCUPZapRouter is Initializable, OwnableUpgradeable, ReentrancyGuardUpgradeable {
    using SafeERC20 for IERC20;

    // --- Constants ---
    uint256 private constant SLIPPAGE_MULTIPLIER = 10000; // slippageTolerance in 1/10000 units
    uint256 private constant MAX_SLIPPAGE = 1000; // Maximum 10%

    // --- State ---
    IUniswapRouterV2 public uniswapRouter;
    IXCUPRatePool public xcupPool;
    IERC20 public xcup;
    IERC20 public usdc;
    uint256 public slippageTolerance; // in 1/10000 units (50 = 0.5%)

    // --- Events ---
    event ZapExecuted(
        address indexed user,
        address indexed tokenIn,
        address indexed tokenOut,
        uint256 amountIn,
        uint256 amountOut
    );
    event ConfigUpdated(address indexed uniswapRouter, address indexed xcupPool, address indexed xcup, address usdc);
    event SlippageToleranceUpdated(uint256 oldTolerance, uint256 newTolerance);

    // --- Errors ---
    error InvalidAddress();
    error InvalidAmount();
    error SwapFailed();
    error InsufficientOutput();
    error SlippageTooHigh();
    error InvalidPath();

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(address _uniswapRouter, address _xcupPool, address _xcup, address _usdc) public initializer {
        if (_uniswapRouter == address(0) || _xcupPool == address(0) || _xcup == address(0) || _usdc == address(0)) {
            revert InvalidAddress();
        }

        __Ownable_init(msg.sender);
        __ReentrancyGuard_init();

        uniswapRouter = IUniswapRouterV2(_uniswapRouter);
        xcupPool = IXCUPRatePool(_xcupPool);
        xcup = IERC20(_xcup);
        usdc = IERC20(_usdc);
        slippageTolerance = 50; // 0.5% default

        emit ConfigUpdated(_uniswapRouter, _xcupPool, _xcup, _usdc);
    }

    // --- Admin Functions ---

    function setConfig(address _uniswapRouter, address _xcupPool, address _xcup, address _usdc) external onlyOwner {
        if (_uniswapRouter == address(0) || _xcupPool == address(0) || _xcup == address(0) || _usdc == address(0)) {
            revert InvalidAddress();
        }

        uniswapRouter = IUniswapRouterV2(_uniswapRouter);
        xcupPool = IXCUPRatePool(_xcupPool);
        xcup = IERC20(_xcup);
        usdc = IERC20(_usdc);

        emit ConfigUpdated(_uniswapRouter, _xcupPool, _xcup, _usdc);
    }

    function setSlippageTolerance(uint256 newTolerance) external onlyOwner {
        if (newTolerance > MAX_SLIPPAGE) revert SlippageTooHigh();
        uint256 old = slippageTolerance;
        slippageTolerance = newTolerance;
        emit SlippageToleranceUpdated(old, newTolerance);
    }

    // --- Zap Functions ---

    /**
     * @notice Classic zap: swap XCUP to any token (including ETH via address(0), or USDC directly)
     * @param amountIn Amount of XCUP to swap
     * @param tokenOut Address of the target token (use address(0) for ETH, or address(usdc) for direct USDC swap)
     * @param minAmountOut Minimum amount of tokens to receive
     * @param deadline Transaction deadline
     * @return amountOut Amount of tokens received (ETH if tokenOut is address(0), USDC if tokenOut is address(usdc))
     */
    function zapXCUPToToken(
        uint256 amountIn,
        address tokenOut,
        uint256 minAmountOut,
        uint256 deadline
    ) external nonReentrant returns (uint256 amountOut) {
        if (amountIn == 0) revert InvalidAmount();

        // Special case: XCUP -> USDC (direct swap via pool, skip Uniswap)
        if (tokenOut == address(usdc)) {
            // Step 1: Transfer XCUP from user
            xcup.safeTransferFrom(msg.sender, address(this), amountIn);

            // Step 2: Swap XCUP -> USDC via XCUPOraclePool
            amountOut = _swapXCUPToUSDC(amountIn);

            // Check minimum output
            if (amountOut < minAmountOut) revert InsufficientOutput();

            // Step 3: Transfer USDC to user
            usdc.safeTransfer(msg.sender, amountOut);

            emit ZapExecuted(msg.sender, address(xcup), address(usdc), amountIn, amountOut);
            return amountOut;
        }

        bool isETH = tokenOut == address(0);
        address actualTokenOut = isETH ? uniswapRouter.WETH() : tokenOut;

        // Step 1: Transfer XCUP from user
        xcup.safeTransferFrom(msg.sender, address(this), amountIn);

        // Step 2: Swap XCUP -> USDC via XCUPOraclePool
        uint256 usdcAmount = _swapXCUPToUSDC(amountIn);

        // Step 3: Swap USDC -> TokenOut via Uniswap (path built automatically)
        amountOut = _swapUSDCToToken(usdcAmount, actualTokenOut, minAmountOut, deadline);

        // Step 4: Transfer tokens to user (or unwrap WETH to ETH)
        if (isETH) {
            // Unwrap WETH to ETH and send to user
            IWETH weth = IWETH(actualTokenOut);
            weth.withdraw(amountOut);
            (bool success, ) = payable(msg.sender).call{value: amountOut}("");
            if (!success) revert SwapFailed();
        } else {
            // Transfer ERC20 token to user
            IERC20(tokenOut).safeTransfer(msg.sender, amountOut);
        }

        emit ZapExecuted(msg.sender, address(xcup), isETH ? address(0) : tokenOut, amountIn, amountOut);
    }

    /**
     * @notice Classic zap: swap any token to XCUP (including ETH via address(0), or USDC directly)
     * @param tokenIn Address of the input token (use address(0) for ETH, or address(usdc) for direct USDC swap)
     * @param amountIn Amount of tokens to swap
     * @param minAmountOut Minimum amount of XCUP to receive
     * @param deadline Transaction deadline
     * @return amountOut Amount of XCUP received
     */
    function zapTokenToXCUP(
        address tokenIn,
        uint256 amountIn,
        uint256 minAmountOut,
        uint256 deadline
    ) external payable nonReentrant returns (uint256 amountOut) {
        // Special case: USDC -> XCUP (direct swap via pool, skip Uniswap)
        if (tokenIn == address(usdc)) {
            if (amountIn == 0) revert InvalidAmount();

            // Step 1: Transfer USDC from user
            usdc.safeTransferFrom(msg.sender, address(this), amountIn);

            // Step 2: Swap USDC -> XCUP via XCUPOraclePool
            amountOut = _swapUSDCToXCUP(amountIn);

            // Check minimum output
            if (amountOut < minAmountOut) revert InsufficientOutput();

            // Step 3: Transfer XCUP to user
            xcup.safeTransfer(msg.sender, amountOut);

            emit ZapExecuted(msg.sender, address(usdc), address(xcup), amountIn, amountOut);
            return amountOut;
        }

        if (tokenIn == address(0)) {
            // ETH case: wrap to WETH first
            if (msg.value != amountIn) revert InvalidAmount();
            tokenIn = uniswapRouter.WETH();
            // Wrap ETH to WETH using low-level call to deposit() function
            (bool success, ) = tokenIn.call{value: amountIn}("");
            if (!success) revert SwapFailed();
        } else {
            if (amountIn == 0) revert InvalidAmount();
            // Step 1: Transfer tokenIn from user
            IERC20(tokenIn).safeTransferFrom(msg.sender, address(this), amountIn);
        }

        // Step 2: Swap TokenIn -> USDC via Uniswap (path built automatically)
        uint256 usdcAmount = _swapTokenToUSDC(tokenIn, amountIn, deadline);

        // Step 3: Swap USDC -> XCUP via XCUPOraclePool
        amountOut = _swapUSDCToXCUP(usdcAmount);

        // Check minimum output
        if (amountOut < minAmountOut) revert InsufficientOutput();

        // Step 4: Transfer XCUP to user
        xcup.safeTransfer(msg.sender, amountOut);

        address actualTokenIn = tokenIn == uniswapRouter.WETH() && msg.value > 0 ? address(0) : tokenIn;
        emit ZapExecuted(msg.sender, actualTokenIn, address(xcup), amountIn, amountOut);
    }

    // --- View Functions ---

    /**
     * @notice Get expected amount of tokens to receive when swapping XCUP
     * @param amountIn Amount of XCUP to swap
     * @param tokenOut Address of the target token (use address(0) for ETH, or address(usdc) for direct USDC swap)
     * @return usdcAmount Amount of USDC after first swap (or final amount if tokenOut is USDC)
     * @return tokenAmount Expected amount of tokens to receive (ETH amount if tokenOut is address(0))
     */
    function getAmountsOut(
        uint256 amountIn,
        address tokenOut
    ) external view returns (uint256 usdcAmount, uint256 tokenAmount) {
        // Special case: XCUP -> USDC (direct swap via pool, skip Uniswap)
        if (tokenOut == address(usdc)) {
            // Calculate USDC after XCUP -> USDC swap
            (uint256 reserveXCUP, uint256 reserveUSDC) = xcupPool.getReserves();
            if (reserveXCUP == 0 || reserveUSDC == 0) {
                return (0, 0);
            }

            uint16 poolFeeBps = xcupPool.swapFee();
            uint256 xcupAmountWithFee = (amountIn * (10000 - poolFeeBps)) / 10000;
            // Conservative estimate based on reserves
            usdcAmount = (xcupAmountWithFee * reserveUSDC) / (reserveXCUP + xcupAmountWithFee);
            tokenAmount = usdcAmount; // For USDC output, tokenAmount = usdcAmount
            return (usdcAmount, tokenAmount);
        }

        if (tokenOut == address(0)) {
            // ETH case: use WETH
            tokenOut = uniswapRouter.WETH();
        }

        // Calculate USDC after XCUP -> USDC swap
        // For oracle-based pool, use conservative estimate
        (uint256 rX, uint256 rU) = xcupPool.getReserves();
        if (rX == 0 || rU == 0) {
            return (0, 0);
        }

        uint16 feeBps = xcupPool.swapFee();
        uint256 amountInWithFee = (amountIn * (10000 - feeBps)) / 10000;
        // Conservative estimate based on reserves
        usdcAmount = (amountInWithFee * rU) / (rX + amountInWithFee);

        // Build path automatically: USDC -> TokenOut
        address[] memory path = new address[](2);
        path[0] = address(usdc);
        path[1] = tokenOut;

        // Calculate output via Uniswap
        if (usdcAmount > 0) {
            uint256[] memory amounts = uniswapRouter.getAmountsOut(usdcAmount, path);
            tokenAmount = amounts[amounts.length - 1];
        }
    }

    /**
     * @notice Get required amount of tokens to swap to receive XCUP
     * @param amountOut Desired amount of XCUP to receive
     * @param tokenIn Address of the input token (use address(0) for ETH)
     * @return tokenAmount Required amount of input tokens
     * @return usdcAmount Required amount of USDC after first swap
     */
    function getAmountsIn(
        uint256 amountOut,
        address tokenIn
    ) external view returns (uint256 tokenAmount, uint256 usdcAmount) {
        if (tokenIn == address(0)) {
            // ETH case: use WETH
            tokenIn = uniswapRouter.WETH();
        }

        // Calculate required USDC to get desired XCUP
        // For oracle-based pool, use conservative estimate
        (uint256 rX, uint256 rU) = xcupPool.getReserves();
        if (rX == 0 || rU == 0) {
            return (0, 0);
        }

        uint16 feeBps = xcupPool.swapFee();
        // Reverse calculation: XCUP -> USDC
        // Conservative estimate: usdcAmount = (amountOut * rU) / (rX - amountOut)
        // But we need to account for fee, so: usdcAmount = (amountOut * rU) / ((rX - amountOut) * (10000 - feeBps) / 10000)
        uint256 amountOutWithFee = (amountOut * 10000) / (10000 - feeBps);
        usdcAmount = (amountOutWithFee * rU) / (rX > amountOutWithFee ? rX - amountOutWithFee : 1);
        if (rX <= amountOutWithFee) {
            return (0, 0);
        }

        // Build path automatically: TokenIn -> USDC
        address[] memory path = new address[](2);
        path[0] = tokenIn;
        path[1] = address(usdc);

        // Calculate required input via Uniswap
        if (usdcAmount > 0) {
            uint256[] memory amounts = uniswapRouter.getAmountsIn(usdcAmount, path);
            tokenAmount = amounts[0];
        }
    }

    /**
     * @notice Get expected amount of XCUP to receive when swapping token to XCUP
     * @param tokenIn Address of the input token (use address(0) for ETH, or address(usdc) for direct USDC swap)
     * @param amountIn Amount of tokens to swap
     * @return usdcAmount Amount of USDC after first swap via Uniswap (or input amount if tokenIn is USDC)
     * @return xcupAmount Expected amount of XCUP to receive
     */
    function getAmountsOutForToken(
        address tokenIn,
        uint256 amountIn
    ) external view returns (uint256 usdcAmount, uint256 xcupAmount) {
        // Special case: USDC -> XCUP (direct swap via pool, skip Uniswap)
        if (tokenIn == address(usdc)) {
            if (amountIn == 0) {
                return (0, 0);
            }

            usdcAmount = amountIn; // No swap needed, already USDC

            // Calculate XCUP after USDC -> XCUP swap via XCUPOraclePool
            (uint256 reserveXCUP, uint256 reserveUSDC) = xcupPool.getReserves();
            if (reserveXCUP == 0 || reserveUSDC == 0) {
                return (usdcAmount, 0);
            }

            uint16 poolFeeBps = xcupPool.swapFee();
            uint256 usdcAmountWithFee = (usdcAmount * (10000 - poolFeeBps)) / 10000;
            // Conservative estimate based on reserves
            xcupAmount = (usdcAmountWithFee * reserveXCUP) / (reserveUSDC + usdcAmountWithFee);
            return (usdcAmount, xcupAmount);
        }

        if (tokenIn == address(0)) {
            // ETH case: use WETH
            tokenIn = uniswapRouter.WETH();
        }

        if (amountIn == 0) {
            return (0, 0);
        }

        // Step 1: Calculate USDC after TokenIn -> USDC swap via Uniswap
        address[] memory path = new address[](2);
        path[0] = tokenIn;
        path[1] = address(usdc);

        uint256[] memory amountsOut = uniswapRouter.getAmountsOut(amountIn, path);
        usdcAmount = amountsOut[amountsOut.length - 1];

        // Step 2: Calculate XCUP after USDC -> XCUP swap via XCUPOraclePool
        // For oracle-based pool, use conservative estimate
        (uint256 rX, uint256 rU) = xcupPool.getReserves();
        if (rX == 0 || rU == 0 || usdcAmount == 0) {
            return (usdcAmount, 0);
        }

        uint16 feeBps = xcupPool.swapFee();
        uint256 amountInWithFee = (usdcAmount * (10000 - feeBps)) / 10000;
        // Conservative estimate based on reserves
        xcupAmount = (amountInWithFee * rX) / (rU + amountInWithFee);
    }

    // --- Internal Functions ---

    /**
     * @dev Swaps XCUP to USDC via XCUPOraclePool
     */
    function _swapXCUPToUSDC(uint256 amount) internal returns (uint256) {
        (uint256 rX, uint256 rU) = xcupPool.getReserves();
        if (rX == 0 || rU == 0) revert SwapFailed();

        // XCUPOraclePool uses oracle-based pricing, so we need to get expected output
        // via getAmountsOut or directly through the pool
        uint16 feeBps = xcupPool.swapFee();

        // Calculate minimum output considering fee and slippage
        // Use simple formula for estimation (pool will verify via oracle)
        uint256 amountInWithFee = (amount * (10000 - feeBps)) / 10000;

        // For oracle-based pool, we cannot calculate precisely without access to oracle
        // So we use conservative estimate based on reserves
        // Minimum output should be at least proportional to reserves
        uint256 conservativeEstimate = (amountInWithFee * rU) / (rX + amountInWithFee);
        if (conservativeEstimate == 0) revert SwapFailed();

        uint256 minOut = (conservativeEstimate * (SLIPPAGE_MULTIPLIER - slippageTolerance)) / SLIPPAGE_MULTIPLIER;

        uint256 balanceBefore = usdc.balanceOf(address(this));

        // Approve pool to pull xCUP and execute swap
        xcup.forceApprove(address(xcupPool), amount);
        xcupPool.swapExactXCUPToUSDC(amount, minOut);

        uint256 balanceAfter = usdc.balanceOf(address(this));
        uint256 usdcReceived = balanceAfter - balanceBefore;

        if (usdcReceived < minOut) revert SwapFailed();

        return usdcReceived;
    }

    /**
     * @dev Swaps USDC to target token via Uniswap
     */
    function _swapUSDCToToken(
        uint256 usdcAmount,
        address tokenOut,
        uint256 minAmountOut,
        uint256 deadline
    ) internal returns (uint256) {
        // Build path: USDC -> TokenOut
        address[] memory path = new address[](2);
        path[0] = address(usdc);
        path[1] = tokenOut;

        // Get expected output
        uint256[] memory amountsOut = uniswapRouter.getAmountsOut(usdcAmount, path);
        uint256 expectedOut = amountsOut[amountsOut.length - 1];

        // Calculate minimum output considering slippage
        uint256 minOut = (expectedOut * (SLIPPAGE_MULTIPLIER - slippageTolerance)) / SLIPPAGE_MULTIPLIER;
        if (minOut < minAmountOut) minOut = minAmountOut;

        // Approve USDC for Uniswap
        usdc.forceApprove(address(uniswapRouter), usdcAmount);

        // Execute swap
        uint256 balanceBefore = IERC20(tokenOut).balanceOf(address(this));
        uniswapRouter.swapExactTokensForTokens(usdcAmount, minOut, path, address(this), deadline);

        uint256 balanceAfter = IERC20(tokenOut).balanceOf(address(this));
        uint256 tokenReceived = balanceAfter - balanceBefore;

        if (tokenReceived < minOut) revert InsufficientOutput();

        return tokenReceived;
    }

    /**
     * @dev Swaps token to USDC via Uniswap
     */
    function _swapTokenToUSDC(address tokenIn, uint256 amountIn, uint256 deadline) internal returns (uint256) {
        // Build path: TokenIn -> USDC
        address[] memory path = new address[](2);
        path[0] = tokenIn;
        path[1] = address(usdc);

        // Get expected output
        uint256[] memory amountsOut = uniswapRouter.getAmountsOut(amountIn, path);
        uint256 expectedOut = amountsOut[amountsOut.length - 1];

        // Calculate minimum output considering slippage
        uint256 minOut = (expectedOut * (SLIPPAGE_MULTIPLIER - slippageTolerance)) / SLIPPAGE_MULTIPLIER;

        // Approve tokenIn for Uniswap
        IERC20(tokenIn).forceApprove(address(uniswapRouter), amountIn);

        // Execute swap - convert memory to calldata for external call
        uint256 balanceBefore = usdc.balanceOf(address(this));

        uniswapRouter.swapExactTokensForTokens(amountIn, minOut, path, address(this), deadline);

        uint256 balanceAfter = usdc.balanceOf(address(this));
        uint256 usdcReceived = balanceAfter - balanceBefore;

        if (usdcReceived < minOut) revert InsufficientOutput();

        return usdcReceived;
    }

    /**
     * @dev Swaps USDC to XCUP via XCUPOraclePool
     */
    function _swapUSDCToXCUP(uint256 usdcAmount) internal returns (uint256) {
        (uint256 rX, uint256 rU) = xcupPool.getReserves();
        if (rX == 0 || rU == 0) revert SwapFailed();

        // XCUPOraclePool uses oracle-based pricing
        uint16 feeBps = xcupPool.swapFee();

        // Calculate minimum output considering fee and slippage
        // Use conservative estimate based on reserves
        uint256 amountInWithFee = (usdcAmount * (10000 - feeBps)) / 10000;
        uint256 conservativeEstimate = (amountInWithFee * rX) / (rU + amountInWithFee);
        if (conservativeEstimate == 0) revert SwapFailed();

        uint256 minOut = (conservativeEstimate * (SLIPPAGE_MULTIPLIER - slippageTolerance)) / SLIPPAGE_MULTIPLIER;

        uint256 balanceBefore = xcup.balanceOf(address(this));

        // Approve pool to pull USDC and execute swap
        usdc.forceApprove(address(xcupPool), usdcAmount);
        xcupPool.swapExactUSDCToXCUP(usdcAmount, minOut);

        uint256 balanceAfter = xcup.balanceOf(address(this));
        uint256 xcupReceived = balanceAfter - balanceBefore;

        if (xcupReceived < minOut) revert SwapFailed();

        return xcupReceived;
    }

    // --- Emergency Functions ---

    function emergencyWithdraw(IERC20 token) external onlyOwner nonReentrant {
        uint256 balance = token.balanceOf(address(this));
        if (balance > 0) {
            token.safeTransfer(owner(), balance);
        }
    }

    function emergencyWithdrawETH() external onlyOwner nonReentrant {
        uint256 balance = address(this).balance;
        if (balance > 0) {
            (bool success, ) = payable(owner()).call{value: balance}("");
            if (!success) revert SwapFailed();
        }
    }

    // Allow contract to receive ETH when unwrapping WETH
    receive() external payable {}
}
