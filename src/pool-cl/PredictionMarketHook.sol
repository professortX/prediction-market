// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;


import {
    HOOKS_BEFORE_INITIALIZE_OFFSET,
    HOOKS_AFTER_INITIALIZE_OFFSET,
    HOOKS_BEFORE_ADD_LIQUIDITY_OFFSET,
    HOOKS_AFTER_ADD_LIQUIDITY_OFFSET,
    HOOKS_BEFORE_REMOVE_LIQUIDITY_OFFSET,
    HOOKS_AFTER_REMOVE_LIQUIDITY_OFFSET,
    HOOKS_BEFORE_SWAP_OFFSET,
    HOOKS_AFTER_SWAP_OFFSET,
    HOOKS_BEFORE_DONATE_OFFSET,
    HOOKS_AFTER_DONATE_OFFSET,
    HOOKS_BEFORE_SWAP_RETURNS_DELTA_OFFSET,
    HOOKS_AFTER_SWAP_RETURNS_DELTA_OFFSET,
    HOOKS_AFTER_ADD_LIQUIDIY_RETURNS_DELTA_OFFSET,
    HOOKS_AFTER_REMOVE_LIQUIDIY_RETURNS_DELTA_OFFSET
} from "pancake-v4-core/src/pool-cl/interfaces/ICLHooks.sol";
import {PoolKey} from "pancake-v4-core/src/types/PoolKey.sol";
import {BalanceDelta} from "pancake-v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta} from "pancake-v4-core/src/types/BeforeSwapDelta.sol";
import {IHooks} from "pancake-v4-core/src/interfaces/IHooks.sol";
import {IVault} from "pancake-v4-core/src/interfaces/IVault.sol";
import {ICLHooks} from "pancake-v4-core/src/pool-cl/interfaces/ICLHooks.sol";
import {ICLPoolManager} from "pancake-v4-core/src/pool-cl/interfaces/ICLPoolManager.sol";
import {CLPoolManager} from "pancake-v4-core/src/pool-cl/CLPoolManager.sol";

import {Hooks} from "pancake-v4-core/src/libraries/Hooks.sol";
import {PoolId, PoolIdLibrary} from "pancake-v4-core/src/types/PoolId.sol";
import {BalanceDelta} from "pancake-v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary, toBeforeSwapDelta} from "pancake-v4-core/src/types/BeforeSwapDelta.sol";
import {BalanceDeltaLibrary} from "pancake-v4-core/src/types/BalanceDelta.sol";
import {Currency, CurrencyLibrary} from "pancake-v4-core/src/types/Currency.sol";
import {IOracle} from "./interface/IOracle.sol";
import {CLPoolManagerRouter} from "pancake-v4-core/test/pool-cl/helpers/CLPoolManagerRouter.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {CLBaseHook} from "./CLBaseHook.sol";
import {PredictionMarket} from "./PredictionMarket.sol";


// contract PredictionMarketHook is ICLHooks, PredictionMarket, NoDelegateCall {
contract PredictionMarketHook is CLBaseHook, PredictionMarket {
    using PoolIdLibrary for PoolKey;

    // NOTE: ---------------------------------------------------------
    // state variables should typically be unique to a pool
    // a single hook contract should be able to service multiple pools
    // ---------------------------------------------------------------
    address immutable private originalAddress;

    constructor(Currency _usdm, ICLPoolManager _poolManager, CLPoolManagerRouter _modifyLiquidityRouter) PredictionMarket(_usdm, _poolManager, _modifyLiquidityRouter) CLBaseHook(_poolManager) {}

    /**
     * @dev Invalid PoolId
     */
    error InvalidPoolId(PoolId poolId);

    modifier onlyPoolManager() {
        require(msg.sender == address(poolManager));
        _;
    }

    modifier noDelegateCall() {
        require(address(this) == originalAddress, "no delegate call");
        _;
    }

    function getHooksRegistrationBitmap() external pure override returns (uint16) {
        return PredictionMarket.getInternalHooksRegistrationBitmap();
    }

 
    // -----------------------------------------------
    // NOTE: see IHooks.sol for function documentation
    // -----------------------------------------------
    function beforeInitialize(address, PoolKey calldata, uint160, bytes calldata) external override returns (bytes4) {
        return (CLBaseHook.beforeInitialize.selector);
    }

    function beforeSwap(address, PoolKey calldata key, ICLPoolManager.SwapParams calldata swapParams, bytes calldata)
        external
        override
        onlyPoolManager
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        // @dev - Check if outcome has been set
        Event memory pmEvent = poolIdToEvent[key.toId()];
        if (!pmEvent.isOutcomeSet) {
            return (this.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
        }

        // After outcome is set, cannot buy outcome tokens, only claim
        bool isBuyingOutcomeTokens;

        if (swapParams.zeroForOne) {
            isBuyingOutcomeTokens = key.currency0.toId() == usdm.toId();
        } else {
            isBuyingOutcomeTokens = key.currency1.toId() == usdm.toId();
        }
        if (isBuyingOutcomeTokens) {
            revert("Outcome has been set, cannot buy outcome tokens");
        }

        // Only allow exactInput when claiming
        if (swapParams.amountSpecified > 0) {
            revert("Only exactInput is allowed when claiming");
        }

        // Circulating supply
        uint256 circulatingSupply = outcomeTokenCirculatingSupply[key.toId()];
        if (circulatingSupply == 0) {
            // DO NOT SWAP here
            return (this.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
        }

        // Get initial total amount of collateral tokens in the pool

        int128 amountToSettle; // Implement based on claim mechanism
        BeforeSwapDelta beforeSwapDelta = toBeforeSwapDelta(int128(-swapParams.amountSpecified), amountToSettle);
        return (this.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
    }

    function afterSwap(
        address,
        PoolKey calldata poolKey,
        ICLPoolManager.SwapParams calldata swapParams,
        BalanceDelta delta,
        bytes calldata
    ) external override onlyPoolManager returns (bytes4, int128) {
        Event memory pmEvent = poolIdToEvent[poolKey.toId()];

        if (pmEvent.isOutcomeSet) {
            return (this.afterSwap.selector, 0);
        }

        bool isUsdmCcy0 = poolKey.currency0.toId() == usdm.toId();
        bool isUserBuyingOutcomeToken = (swapParams.zeroForOne && isUsdmCcy0) || (!swapParams.zeroForOne && !isUsdmCcy0);

        int256 outcomeTokenAmount = isUsdmCcy0 ? delta.amount1() : delta.amount0();
        int256 usdmTokenAmountReceived = isUsdmCcy0 ? delta.amount0() : delta.amount1();

        // If user is buying outcome token (+)
        if (isUserBuyingOutcomeToken) {
            outcomeTokenCirculatingSupply[poolKey.toId()] += uint256(outcomeTokenAmount);
            usdmAmountInPool[poolKey.toId()] += uint256(-usdmTokenAmountReceived);
        } else {
            // If user is selling outcome token (-)
            outcomeTokenCirculatingSupply[poolKey.toId()] -= uint256(-outcomeTokenAmount);
            usdmAmountInPool[poolKey.toId()] -= uint256(usdmTokenAmountReceived);
        }

        return (this.afterSwap.selector, 0);
    }

    /**
     * Only allows the hook to add liquidity here
     */
    function beforeAddLiquidity(address, PoolKey calldata, ICLPoolManager.ModifyLiquidityParams calldata, bytes calldata)
        external
        override
        onlyPoolManager
        noDelegateCall
        returns (bytes4)
    {
        return (this.beforeAddLiquidity.selector);
    }

    function beforeRemoveLiquidity(
        address,
        PoolKey calldata,
        ICLPoolManager.ModifyLiquidityParams calldata,
        bytes calldata
    ) external override onlyPoolManager noDelegateCall returns (bytes4) {
        return (this.beforeRemoveLiquidity.selector);
    }

    function afterAddLiquidity(
        address sender,
        PoolKey calldata key,
        ICLPoolManager.ModifyLiquidityParams calldata params,
        BalanceDelta delta,
        bytes calldata hookData
    ) external override onlyPoolManager noDelegateCall returns (bytes4, BalanceDelta) {
        return (this.afterAddLiquidity.selector, BalanceDeltaLibrary.ZERO_DELTA);
    }

    function afterRemoveLiquidity(
        address sender,
        PoolKey calldata key,
        ICLPoolManager.ModifyLiquidityParams calldata params,
        BalanceDelta delta,
        bytes calldata hookData
    ) external override onlyPoolManager noDelegateCall returns (bytes4, BalanceDelta) {
        return (this.afterRemoveLiquidity.selector, BalanceDeltaLibrary.ZERO_DELTA);
    }

    function getPriceInUsdm(PoolId poolId) public view returns (uint256) {
        (uint160 sqrtPriceX96,,,) = poolManager.getSlot0(poolId);
        if (sqrtPriceX96 == 0) {
            revert InvalidPoolId(poolId);
        }
        uint256 sqrtPriceX96Uint = uint256(sqrtPriceX96);
        PoolKey memory poolKey = poolKeys[poolId];
        Currency curr0 = poolKey.currency0;
        Currency curr1 = poolKey.currency1;
        uint8 curr0Decimals = ERC20(Currency.unwrap(curr0)).decimals();
        uint8 curr1Decimals = ERC20(Currency.unwrap(curr1)).decimals();

        bool isCurr0Usdm = curr0.toId() == usdm.toId();
        bool isCurr1Usdm = curr1.toId() == usdm.toId();

        require(isCurr0Usdm || isCurr1Usdm, "Neither currency is USDM");

        uint256 price;

        if (isCurr0Usdm) {
            // curr0 is USDM, calculate price of curr1 in terms of USDM (inverse price)
            uint256 numerator = (1 << 192) * 1e18;
            uint256 denominator = sqrtPriceX96Uint * sqrtPriceX96Uint;
            uint256 decimalsDifference;

            if (curr1Decimals >= curr0Decimals) {
                decimalsDifference = curr1Decimals - curr0Decimals;
                numerator *= 10 ** decimalsDifference;
            } else {
                decimalsDifference = curr0Decimals - curr1Decimals;
                denominator *= 10 ** decimalsDifference;
            }

            price = numerator / denominator;
        } else if (isCurr1Usdm) {
            // curr1 is USDM, calculate price of curr0 in terms of USDM
            uint256 numerator = sqrtPriceX96Uint * sqrtPriceX96Uint * 1e18;
            uint256 denominator = 1 << 192;
            uint256 decimalsDifference;

            if (curr0Decimals >= curr1Decimals) {
                decimalsDifference = curr0Decimals - curr1Decimals;
                numerator *= 10 ** decimalsDifference;
            } else {
                decimalsDifference = curr1Decimals - curr0Decimals;
                denominator *= 10 ** decimalsDifference;
            }

            price = numerator / denominator;
        }

        return price;
    }

}
