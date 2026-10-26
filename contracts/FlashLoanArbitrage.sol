// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title AntigravityFlashLoanArbitrage
 * @notice Ultra-Gas-Efficient Zero-Capital Atomic Flash-Loan Arbitrage Executor for Base Mainnet (Chain ID: 8453).
 * @dev Supports 3 Major Flash Loan Providers:
 *      1. Balancer V2 Vault (0xBA12222222228d8Ba445958a75a0704d566BF2C8) — 0.00% (0 bps) fee ($15M+ liquidity)
 *      2. Morpho Blue       (0xBBBBBbbBBb9cC5e90e3b3Af64bdAF62C37EEFFCb) — 0.00% (0 bps) fee ($430M+ liquidity)
 *      3. Aave V3 Pool      (0xA238Dd80C259a72e81d7e4664a9801593F98d1c5) — 0.05% (5 bps) fee ($50M+ liquidity)
 *      - Direct Pool Swaps (zero router overhead, no ERC20 approve() gas cost) on:
 *          1. Uniswap V3 Pools          (uniswapV3SwapCallback)
 *          2. Aerodrome Slipstream (CL) (uniswapV3SwapCallback)
 *          3. PancakeSwap V3 Pools      (pancakeV3SwapCallback)
 *          4. Aerodrome vAMM Pools      (direct pool.getAmountOut + pool.swap)
 */

interface IERC20 {
    function balanceOf(address account) external view returns (uint256);
    function transfer(address recipient, uint256 amount) external returns (bool);
    function approve(address spender, uint256 amount) external returns (bool);
}

interface IBalancerVault {
    function flashLoan(
        address recipient,
        address[] memory tokens,
        uint256[] memory amounts,
        bytes memory userData
    ) external;
}

interface IMorpho {
    function flashLoan(
        address token,
        uint256 assets,
        bytes calldata data
    ) external;
}

interface IAaveV3Pool {
    function flashLoanSimple(
        address receiverAddress,
        address asset,
        uint256 amount,
        bytes calldata params,
        uint16 referralCode
    ) external;
}

interface ICLPool {
    function token0() external view returns (address);
    function token1() external view returns (address);
    function swap(
        address recipient,
        bool zeroForOne,
        int256 amountSpecified,
        uint160 sqrtPriceLimitX96,
        bytes calldata data
    ) external returns (int256 amount0, int256 amount1);
}

interface IAeroVammPool {
    function token0() external view returns (address);
    function getAmountOut(uint256 amountIn, address tokenIn) external view returns (uint256);
    function swap(
        uint256 amount0Out,
        uint256 amount1Out,
        address to,
        bytes calldata data
    ) external;
}

contract AntigravityFlashLoanArbitrage {
    address public constant BALANCER_VAULT = 0xBA12222222228d8Ba445958a75a0704d566BF2C8;
    address public constant MORPHO_BLUE    = 0xBBBBBbbBBb9cC5e90e3b3Af64bdAF62C37EEFFCb;
    address public constant AAVE_V3_POOL   = 0xA238Dd80C259a72e81d7e4664a9801593F98d1c5;

    uint160 internal constant MIN_SQRT_RATIO_PLUS_ONE = 4295128740;
    uint160 internal constant MAX_SQRT_RATIO_MINUS_ONE = 1461446703485210103287273052203988822378723970341;

    address public immutable owner;
    address private activeCallbackPool;

    enum PoolKind {
        CL_POOL,        // Uniswap V3, Aerodrome Slipstream CL, PancakeSwap V3
        AERO_VAMM_POOL  // Aerodrome vAMM / sAMM
    }

    struct ArbExecutionPlan {
        address loanToken;        // Token borrowed via Flash Loan (e.g. USDC or WETH)
        address targetToken;      // Intermediate token bought in Leg 1 and sold in Leg 2
        uint256 loanAmount;       // Principal borrowed
        address buyPool;          // Leg 1 pool address
        address sellPool;         // Leg 2 pool address
        uint8 buyPoolKind;        // 0 = CL_POOL, 1 = AERO_VAMM_POOL
        uint8 sellPoolKind;       // 0 = CL_POOL, 1 = AERO_VAMM_POOL
        uint256 minNetProfit;     // Minimum net profit in loanToken required not to revert
    }

    event ArbitrageExecuted(
        address indexed provider,
        address indexed loanToken,
        address indexed targetToken,
        uint256 loanAmount,
        uint256 netProfit
    );

    error OnlyOwner();
    error UnauthorizedFlashCallback();
    error UnauthorizedPoolCallback();
    error InsufficientNetProfit(uint256 balanceAfter, uint256 requiredAmount);

    modifier onlyOwner() {
        if (msg.sender != owner) revert OnlyOwner();
        _;
    }

    constructor() {
        owner = msg.sender;
    }

    /**
     * @notice Initiates a 0%-fee atomic flash-loan arbitrage via Balancer V2 Vault on Base.
     */
    function executeBalancerFlashArb(ArbExecutionPlan calldata plan) external onlyOwner {
        address[] memory tokens = new address[](1);
        tokens[0] = plan.loanToken;

        uint256[] memory amounts = new uint256[](1);
        amounts[0] = plan.loanAmount;

        bytes memory userData = abi.encode(uint8(0), abi.encode(plan));
        IBalancerVault(BALANCER_VAULT).flashLoan(address(this), tokens, amounts, userData);
    }

    /**
     * @notice Initiates a 0%-fee atomic flash-loan arbitrage via Morpho Blue on Base ($430M+ liquidity).
     */
    function executeMorphoFlashArb(ArbExecutionPlan calldata plan) external onlyOwner {
        bytes memory data = abi.encode(plan);
        IMorpho(MORPHO_BLUE).flashLoan(plan.loanToken, plan.loanAmount, data);
    }

    /**
     * @notice Initiates a 0.05%-fee atomic flash-loan arbitrage via Aave V3 Pool on Base.
     */
    function executeAaveFlashArb(ArbExecutionPlan calldata plan) external onlyOwner {
        bytes memory params = abi.encode(plan);
        IAaveV3Pool(AAVE_V3_POOL).flashLoanSimple(
            address(this),
            plan.loanToken,
            plan.loanAmount,
            params,
            0
        );
    }

    /**
     * @notice Unified router entrypoint:
     *         0 = Balancer V2 (0% fee)
     *         1 = Morpho Blue (0% fee)
     *         2 = Aave V3     (0.05% fee)
     */
    function executeFlashArb(uint8 providerId, ArbExecutionPlan calldata plan) external onlyOwner {
        if (providerId == 0) {
            address[] memory tokens = new address[](1);
            tokens[0] = plan.loanToken;
            uint256[] memory amounts = new uint256[](1);
            amounts[0] = plan.loanAmount;
            bytes memory userData = abi.encode(uint8(0), abi.encode(plan));
            IBalancerVault(BALANCER_VAULT).flashLoan(address(this), tokens, amounts, userData);
        } else if (providerId == 1) {
            bytes memory data = abi.encode(plan);
            IMorpho(MORPHO_BLUE).flashLoan(plan.loanToken, plan.loanAmount, data);
        } else if (providerId == 2) {
            bytes memory params = abi.encode(plan);
            IAaveV3Pool(AAVE_V3_POOL).flashLoanSimple(
                address(this),
                plan.loanToken,
                plan.loanAmount,
                params,
                0
            );
        } else {
            revert("Invalid providerId");
        }
    }

    /**
     * @notice Balancer V2 flash-loan callback.
     */
    function receiveFlashLoan(
        address[] memory tokens,
        uint256[] memory amounts,
        uint256[] memory feeAmounts,
        bytes memory userData
    ) external {
        if (msg.sender != BALANCER_VAULT) revert UnauthorizedFlashCallback();

        (, bytes memory innerPayload) = abi.decode(userData, (uint8, bytes));
        ArbExecutionPlan memory plan = abi.decode(innerPayload, (ArbExecutionPlan));

        uint256 loanAmount = amounts[0];
        uint256 amountOwed = loanAmount + feeAmounts[0];

        uint256 finalBalance = _executeTwoLegSwaps(plan, loanAmount);
        uint256 requiredBalance = amountOwed + plan.minNetProfit;
        if (finalBalance < requiredBalance) {
            revert InsufficientNetProfit(finalBalance, requiredBalance);
        }

        IERC20(tokens[0]).transfer(BALANCER_VAULT, amountOwed);

        uint256 netProfit = finalBalance - amountOwed;
        if (netProfit > 0) {
            IERC20(tokens[0]).transfer(owner, netProfit);
        }

        emit ArbitrageExecuted(BALANCER_VAULT, plan.loanToken, plan.targetToken, loanAmount, netProfit);
    }

    /**
     * @notice Morpho Blue flash-loan callback.
     */
    function onMorphoFlashLoan(uint256 assets, bytes calldata data) external {
        if (msg.sender != MORPHO_BLUE) revert UnauthorizedFlashCallback();

        ArbExecutionPlan memory plan = abi.decode(data, (ArbExecutionPlan));

        uint256 finalBalance = _executeTwoLegSwaps(plan, assets);
        uint256 requiredBalance = assets + plan.minNetProfit;
        if (finalBalance < requiredBalance) {
            revert InsufficientNetProfit(finalBalance, requiredBalance);
        }

        // Repay Morpho Blue: approve Morpho to pull back assets (0% fee)
        IERC20(plan.loanToken).approve(MORPHO_BLUE, assets);

        uint256 netProfit = finalBalance - assets;
        if (netProfit > 0) {
            IERC20(plan.loanToken).transfer(owner, netProfit);
        }

        emit ArbitrageExecuted(MORPHO_BLUE, plan.loanToken, plan.targetToken, assets, netProfit);
    }

    /**
     * @notice Aave V3 flash-loan callback.
     */
    function executeOperation(
        address asset,
        uint256 amount,
        uint256 premium,
        address initiator,
        bytes calldata params
    ) external returns (bool) {
        if (msg.sender != AAVE_V3_POOL || initiator != address(this)) {
            revert UnauthorizedFlashCallback();
        }

        ArbExecutionPlan memory plan = abi.decode(params, (ArbExecutionPlan));
        uint256 amountOwed = amount + premium;

        uint256 finalBalance = _executeTwoLegSwaps(plan, amount);
        uint256 requiredBalance = amountOwed + plan.minNetProfit;
        if (finalBalance < requiredBalance) {
            revert InsufficientNetProfit(finalBalance, requiredBalance);
        }

        IERC20(asset).approve(AAVE_V3_POOL, amountOwed);

        uint256 netProfit = finalBalance - amountOwed;
        if (netProfit > 0) {
            IERC20(asset).transfer(owner, netProfit);
        }

        emit ArbitrageExecuted(AAVE_V3_POOL, plan.loanToken, plan.targetToken, amount, netProfit);
        return true;
    }

    function _executeTwoLegSwaps(
        ArbExecutionPlan memory plan,
        uint256 amountIn
    ) internal returns (uint256 finalBalance) {
        uint256 midAmount = _swapOnPool(
            plan.buyPool,
            PoolKind(plan.buyPoolKind),
            plan.loanToken,
            plan.targetToken,
            amountIn
        );

        _swapOnPool(
            plan.sellPool,
            PoolKind(plan.sellPoolKind),
            plan.targetToken,
            plan.loanToken,
            midAmount
        );

        finalBalance = IERC20(plan.loanToken).balanceOf(address(this));
    }

    function _swapOnPool(
        address pool,
        PoolKind kind,
        address tokenIn,
        address tokenOut,
        uint256 amountIn
    ) internal returns (uint256 amountOut) {
        if (kind == PoolKind.CL_POOL) {
            address t0 = ICLPool(pool).token0();
            bool zeroForOne = (tokenIn == t0);
            uint160 limit = zeroForOne ? MIN_SQRT_RATIO_PLUS_ONE : MAX_SQRT_RATIO_MINUS_ONE;

            activeCallbackPool = pool;
            (int256 amount0, int256 amount1) = ICLPool(pool).swap(
                address(this),
                zeroForOne,
                int256(amountIn),
                limit,
                abi.encode(tokenIn)
            );
            activeCallbackPool = address(0);

            amountOut = uint256(-(zeroForOne ? amount1 : amount0));
        } else {
            address t0 = IAeroVammPool(pool).token0();
            amountOut = IAeroVammPool(pool).getAmountOut(amountIn, tokenIn);
            IERC20(tokenIn).transfer(pool, amountIn);
            uint256 amount0Out = (tokenOut == t0) ? amountOut : 0;
            uint256 amount1Out = (tokenOut == t0) ? 0 : amountOut;
            IAeroVammPool(pool).swap(amount0Out, amount1Out, address(this), "");
        }
    }

    /**
     * @notice Callback for Uniswap V3 and Aerodrome Slipstream (CL) pools.
     */
    function uniswapV3SwapCallback(
        int256 amount0Delta,
        int256 amount1Delta,
        bytes calldata data
    ) external {
        _handleCLCallback(amount0Delta, amount1Delta, data);
    }

    /**
     * @notice Callback for PancakeSwap V3 pools.
     */
    function pancakeV3SwapCallback(
        int256 amount0Delta,
        int256 amount1Delta,
        bytes calldata data
    ) external {
        _handleCLCallback(amount0Delta, amount1Delta, data);
    }

    function _handleCLCallback(
        int256 amount0Delta,
        int256 amount1Delta,
        bytes calldata data
    ) internal {
        if (msg.sender != activeCallbackPool) revert UnauthorizedPoolCallback();
        address tokenIn = abi.decode(data, (address));
        uint256 amountToPay = amount0Delta > 0 ? uint256(amount0Delta) : uint256(amount1Delta);
        IERC20(tokenIn).transfer(msg.sender, amountToPay);
    }

    /**
     * @notice Emergency rescue of any ERC20 tokens or native ETH to owner wallet.
     */
    function rescueTokens(address token) external onlyOwner {
        if (token == address(0)) {
            payable(owner).transfer(address(this).balance);
        } else {
            uint256 bal = IERC20(token).balanceOf(address(this));
            if (bal > 0) {
                IERC20(token).transfer(owner, bal);
            }
        }
    }
}
