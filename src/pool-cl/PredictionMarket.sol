// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

// External Libraries and Contracts
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

// Internal Interfaces and Libraries
import "./interface/IOracle.sol";
import "./interface/IPredictionMarket.sol";
import "./OutcomeToken.sol";
import "./CentralisedOracle.sol";
import "./lib/SortTokens.sol";
import "openzeppelin-contracts/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import "openzeppelin-contracts/contracts/utils/ReentrancyGuard.sol";

import "pancake-v4-core/src/types/Currency.sol";
import "pancake-v4-core/src/types/PoolKey.sol";
import "pancake-v4-core/src/types/PoolId.sol";
import "pancake-v4-core/src/pool-cl/libraries/TickMath.sol";
import "pancake-v4-core/src/pool-cl/interfaces/ICLHooks.sol";
import "pancake-v4-core/src/pool-cl/CLPoolManager.sol";
import "pancake-v4-core/src/pool-cl/interfaces/ICLPoolManager.sol";
import "pancake-v4-core/src/types/BalanceDelta.sol";

import "pancake-v4-core/src/pool-cl/libraries/FullMath.sol";
import "pancake-v4-core/src/libraries/SafeCast.sol";
import "pancake-v4-core/src/pool-cl/libraries/FixedPoint96.sol";
import "pancake-v4-core/test/pool-cl/helpers/CLPoolManagerRouter.sol";
import "pancake-v4-core/src/pool-cl/libraries/CLPoolParametersHelper.sol";
import "pancake-v4-core/src/pool-cl/interfaces/ICLPoolManager.sol";


// Uniswap V4 Core Libraries and Contracts
import {CLBaseHook} from "./CLBaseHook.sol";


/**
 * @title PredictionMarket
 * @notice Abstract contract for creating and managing prediction markets.
 */
abstract contract PredictionMarket is ReentrancyGuard, IPredictionMarket {
    using PoolIdLibrary for PoolKey;
    // using TransientStateLibrary for ICLPoolManager;
    using BalanceDeltaLibrary for BalanceDelta;
    using CurrencyLibrary for Currency;
    // using StateLibrary for ICLPoolManager;
    using FullMath for uint256;

    // Constants
    int24 public constant TICK_SPACING = 10;
    uint24 public constant FEE = 0; // 0% fee
    bytes public constant ZERO_BYTES = "";
    int16 public constant UNINITIALIZED_OUTCOME = -1;

    // State Variables
    Currency public immutable usdm;
    ICLPoolManager private immutable manager;
    CLPoolManagerRouter private immutable modifyLiquidityRouter;

    // Mappings
    mapping(bytes32 => Market) public markets;
    mapping(bytes32 => Event) public events;

    mapping(address => bytes32[]) public userMarkets;

    mapping(PoolId => PoolKey) public poolKeys;
    mapping(PoolId => bytes32 eventId) public poolIdToEventId;
    mapping(PoolId => bytes32 marketId) public poolIdToMarketId;

    // Circulating supply of outcome tokens
    mapping(PoolId => uint256 supply) public outcomeTokenCirculatingSupply;
    // Supply of USDM that can be withdrawn by the hook
    mapping(PoolId => uint256 supply) public usdmAmountInPool;
    // Keep track of liquidity provided by the hook, only keep tracks of latest
    mapping(PoolId => ICLPoolManager.ModifyLiquidityParams) public hookProvidedLiquidityForPool;

    /**
     * @notice Constructor
     * @param _usdm The USDM currency used as collateral
     * @param _poolManager The Uniswap V4 PoolManager contract
     */
    constructor(Currency _usdm, ICLPoolManager _poolManager, CLPoolManagerRouter _modifyLiquidityRouter) {
        usdm = _usdm;
        manager = _poolManager;
        modifyLiquidityRouter = _modifyLiquidityRouter;
    }
    

    /**
     * @notice Initializes outcome tokens and their pools
     * @param outcomeDetails The details of each outcome
     * @return lpPools The array of liquidity pool IDs
     */
    function initializePool(OutcomeDetails[] calldata outcomeDetails) external returns (PoolId[] memory lpPools) {
        Outcome[] memory outcomes = _deployOutcomeTokens(outcomeDetails);
        lpPools = _initializeOutcomePools(outcomes);
        return lpPools;
    }

    /**
     * @notice Gets the pool key by pool ID
     * @param poolId The pool ID
     * @return The pool key associated with the given pool ID
     */
    function getPoolKeyByPoolId(PoolId poolId) external view returns (PoolKey memory) {
        return poolKeys[poolId];
    }

    /**
     * @notice Does not check if marketId exists, if it does not, it will return false
     * @param marketId The market ID to check
     * @return The event has been settled
     */
    function isMarketResolved(bytes32 marketId) external view returns (bool) {
        Market storage market = markets[marketId];
        Event storage pmmEvent = events[market.eventId];
        return pmmEvent.isOutcomeSet;
    }

    /**
     * @notice Initializes a new prediction market
     * @param _fee The fee for the market
     * @param _eventIpfsHash The IPFS hash of the event data
     * @param _outcomeDetails The details of each outcome
     * @return marketId The ID of the created market
     * @return lpPools The array of liquidity pool IDs
     * @return outcomes The array of outcomes
     * @return oracle The oracle used for this market
     */
    function initializeMarket(uint24 _fee, bytes memory _eventIpfsHash, OutcomeDetails[] calldata _outcomeDetails)
        external
        override
        returns (bytes32 marketId, PoolId[] memory lpPools, Outcome[] memory outcomes, IOracle oracle)
    {
        // Deploy outcome tokens, mint to this hook
        outcomes = _deployOutcomeTokens(_outcomeDetails);

        // Initialize outcome pools to poolManager
        lpPools = _initializeOutcomePools(outcomes);

        // Seed single-sided liquidity into the outcome pools
        _seedSingleSidedLiquidity(lpPools);

        // Initialize the event, create the market & deploy the oracle
        bytes32 eventId = _initializeEvent(_fee, _eventIpfsHash, outcomes, lpPools);
        oracle = _deployOracle(_eventIpfsHash);
        marketId = _createMarket(_fee, eventId, oracle, lpPools);

        return (marketId, lpPools, outcomes, oracle);
    }

    /**
     * @notice Starts a market, moving it to the STARTED stage
     * @param marketId The ID of the market to start
     */
    function startMarket(bytes32 marketId) public override {
        Market storage market = markets[marketId];

        // Check if the market exists and is in the correct stage
//        require(market.creator != address(0), "Market not found"); @dev - this is not needed for testing
        require(market.stage == Stage.CREATED, "Market already started");
        require(msg.sender == market.creator, "Only market creator can start");

        // Update market stage
        market.stage = Stage.STARTED;

        emit MarketStarted(marketId);
    }

    /**
     * @notice Settles a market based on the outcome
     * @param marketId The ID of the market to settle
     * @param outcome The outcome index
     */
    function settle(bytes32 marketId, int16 outcome) public virtual override {
        Market storage market = markets[marketId];

        // Check if the market exists and is in the correct stage
        {
            require(outcome >= 0, "Invalid outcome");
            require(market.creator != address(0), "Market not found");
            require(market.stage == Stage.STARTED, "Market not started");
            require(msg.sender == market.creator, "Only market creator can settle");
        }

        // Update event outcome

        Event storage pmmEvent = events[market.eventId];
        {
            pmmEvent.outcomeResolution = outcome;
            pmmEvent.isOutcomeSet = true;

            // Update market stage and set outcome in oracle
            market.stage = Stage.RESOLVED;
            market.oracle.setOutcome(outcome);
        }

        // Interactions
        uint256 totalUsdmAmount;

        // Remove liquidity from losing pools and collect USDM amounts
        for (uint256 i = 0; i < pmmEvent.lpPools.length; i++) {
            // Remove liquidity from losing pools
            PoolId poolId = pmmEvent.lpPools[i];
            PoolKey memory poolKey = poolKeys[poolId];

            ICLPoolManager.ModifyLiquidityParams memory liquidityParams = hookProvidedLiquidityForPool[poolId];

            // Negate the liquidityDelta to remove liquidity
            liquidityParams.liquidityDelta = -liquidityParams.liquidityDelta;

            // Remove liquidity and get the balance delta
            (BalanceDelta delta, ) =
                modifyLiquidityRouter.modifyPosition(poolKey, liquidityParams, ZERO_BYTES);

            delete hookProvidedLiquidityForPool[poolId];

            {
                bool isUsdmCurrency0 = poolKey.currency0.toId() == usdm.toId();
                int256 usdmDelta = isUsdmCurrency0 ? delta.amount0() : delta.amount1();

                // Accumulate the amount of USDM obtained
                if (usdmDelta > 0) {
                    totalUsdmAmount += uint256(usdmDelta);
                } else {
                    totalUsdmAmount += uint256(-usdmDelta); // Convert negative amount to positive
                }
            }
        }

        market.usdmAmountAtSettlement = totalUsdmAmount;

        emit MarketResolved(marketId, outcome);
    }

    function amountToClaim(bytes32 marketId) public view returns (uint256) {
        Market storage market = markets[marketId];
        Event storage pmmEvent = events[market.eventId];

        require(market.stage == Stage.RESOLVED && pmmEvent.outcomeResolution >= 0, "Outcome not resolved");

        PoolId poolId = pmmEvent.lpPools[uint256(int256(pmmEvent.outcomeResolution))];
        PoolKey memory poolKey = poolKeys[poolId];

        Currency outcomeCcy = poolKey.currency0.toId() == usdm.toId() ? poolKey.currency1 : poolKey.currency0;
        IERC20Metadata outcomeToken = IERC20Metadata(Currency.unwrap(outcomeCcy));

        uint256 outcomeTokenAmountToClaim = outcomeToken.balanceOf(msg.sender);
        uint256 totalUsdmForMarket = market.usdmAmountAtSettlement;
        uint256 circulatingSupply = outcomeTokenCirculatingSupply[poolKey.toId()];

        // Division by zero check
        if (circulatingSupply == 0) {
            return 0;
        }

        return (totalUsdmForMarket * outcomeTokenAmountToClaim) / circulatingSupply;
    }

    function claim(bytes32 marketId, uint256 outcomeTokenAmountToClaim) external nonReentrant returns (uint256 usdmAmountToClaim) {
        Market storage market = markets[marketId];
        Event storage pmmEvent = events[market.eventId];

        require(outcomeTokenAmountToClaim > 0, "Invalid amount to claim");
        require(market.stage == Stage.RESOLVED && pmmEvent.outcomeResolution >= 0, "Market not resolved");

        PoolId poolId = pmmEvent.lpPools[uint256(int256(pmmEvent.outcomeResolution))];
        PoolKey memory poolKey = poolKeys[poolId];

        Currency outcomeCcy = poolKey.currency0.toId() == usdm.toId() ? poolKey.currency1 : poolKey.currency0;
        IERC20Metadata outcomeToken = IERC20Metadata(Currency.unwrap(outcomeCcy));

        uint256 circulatingSupply = outcomeTokenCirculatingSupply[poolKey.toId()];
        {
            require(circulatingSupply > 0, "No circulating supply available");
            require(outcomeToken.balanceOf(msg.sender) >= outcomeTokenAmountToClaim, "Insufficient balance");
            require(outcomeTokenAmountToClaim < circulatingSupply, "Amount too big");
            require(outcomeToken.allowance(msg.sender, address(this)) >= outcomeTokenAmountToClaim, "Insufficient token allowance");
        }

        {
            usdmAmountToClaim = (market.usdmAmountAtSettlement * outcomeTokenAmountToClaim) / circulatingSupply;
            emit Claimed(marketId, msg.sender, address(outcomeToken), outcomeTokenAmountToClaim);

            require(outcomeToken.transferFrom(msg.sender, address(this), outcomeTokenAmountToClaim), "Token transfer failed");
            usdm.transfer(msg.sender, usdmAmountToClaim);
        }
    }


    /**
     * @notice Deploys outcome tokens based on the provided details
     * @param outcomeDetails The details for each outcome
     * @return outcomes The array of deployed outcomes
     */
    function _deployOutcomeTokens(OutcomeDetails[] calldata outcomeDetails)
        internal
        returns (Outcome[] memory outcomes)
    {
        outcomes = new Outcome[](outcomeDetails.length);
        for (uint256 i = 0; i < outcomeDetails.length; i++) {
            OutcomeToken outcomeToken = new OutcomeToken(outcomeDetails[i].name);
            outcomeToken.approve(address(manager), type(uint256).max);
            outcomeToken.approve(address(modifyLiquidityRouter), type(uint256).max);
            outcomes[i] = Outcome(Currency.wrap(address(outcomeToken)), outcomeDetails[i]);
        }
        return outcomes;
    }

    /**
     * @notice Initializes outcome pools for the given outcomes
     * @param outcomes The array of outcomes
     * @return lpPools The array of liquidity pool IDs
     */
    function _initializeOutcomePools(Outcome[] memory outcomes) internal returns (PoolId[] memory lpPools) {
        uint256 outcomesLength = outcomes.length;
        lpPools = new PoolId[](outcomesLength);

        for (uint256 i = 0; i < outcomesLength; i++) {
            Outcome memory outcome = outcomes[i];
            IERC20 outcomeToken = IERC20(Currency.unwrap(outcome.outcomeToken));
            IERC20 usdmToken = IERC20(Currency.unwrap(usdm));

            // Sort tokens and get PoolKey
            PoolKey memory poolKey = _getPoolKey(outcomeToken, usdmToken);
            lpPools[i] = poolKey.toId();

            // Get tick range and initialize the pool
            _initializePool(poolKey, outcomeToken);
        }

        return lpPools;
    }


    /**
     * @notice Returns the internal hooks registration bitmap
     * @dev This function defines which hooks are enabled for the prediction market
     * @return uint16 A bitmap representing the enabled hooks
     */
    function getInternalHooksRegistrationBitmap() internal pure virtual returns (uint16) {
        return _internalHooksRegistrationBitmapFrom(
            CLBaseHook.Permissions({
                beforeInitialize: true, // Deploy oracles, initialize market, event
                afterInitialize: false, // Not needed for this implementation
                beforeAddLiquidity: true, // Only allow hook to add liquidity
                afterAddLiquidity: true, // Track supply of USDM
                beforeRemoveLiquidity: true, // Only allow hook to remove liquidity
                afterRemoveLiquidity: true, // Track supply of USDM
                beforeSwap: true, // Check if outcome has been set
                afterSwap: true, // Calculate supply of outcome tokens in pool
                beforeDonate: false, // Donation not implemented
                afterDonate: false, // Donation not implemented
                beforeSwapReturnsDelta: false, // Not needed for this implementation
                afterSwapReturnsDelta: false, // Not needed for this implementation
                afterAddLiquidityReturnsDelta: false, // Not needed for this implementation
                afterRemoveLiquidityReturnsDelta: false // Not needed for this implementation
            })
        );
    }

    /**
     * @notice Converts the CLBaseHook.Permissions struct to a bitmap
     * @dev This function is used internally to generate the hooks registration bitmap
     * @param permissions A struct containing boolean flags for each hook
     * @return uint16 The resulting bitmap representing enabled hooks
     */
    function _internalHooksRegistrationBitmapFrom(CLBaseHook.Permissions memory permissions) internal virtual pure returns (uint16) {
        // Convert each permission to its corresponding bit in the bitmap
        return uint16(
            (permissions.beforeInitialize ? 1 << HOOKS_BEFORE_INITIALIZE_OFFSET : 0)
                | (permissions.afterInitialize ? 1 << HOOKS_AFTER_INITIALIZE_OFFSET : 0)
                | (permissions.beforeAddLiquidity ? 1 << HOOKS_BEFORE_ADD_LIQUIDITY_OFFSET : 0)
                | (permissions.afterAddLiquidity ? 1 << HOOKS_AFTER_ADD_LIQUIDITY_OFFSET : 0)
                | (permissions.beforeRemoveLiquidity ? 1 << HOOKS_BEFORE_REMOVE_LIQUIDITY_OFFSET : 0)
                | (permissions.afterRemoveLiquidity ? 1 << HOOKS_AFTER_REMOVE_LIQUIDITY_OFFSET : 0)
                | (permissions.beforeSwap ? 1 << HOOKS_BEFORE_SWAP_OFFSET : 0)
                | (permissions.afterSwap ? 1 << HOOKS_AFTER_SWAP_OFFSET : 0)
                | (permissions.beforeDonate ? 1 << HOOKS_BEFORE_DONATE_OFFSET : 0)
                | (permissions.afterDonate ? 1 << HOOKS_AFTER_DONATE_OFFSET : 0)
                | (permissions.beforeSwapReturnsDelta ? 1 << HOOKS_BEFORE_SWAP_RETURNS_DELTA_OFFSET : 0)
                | (permissions.afterSwapReturnsDelta ? 1 << HOOKS_AFTER_SWAP_RETURNS_DELTA_OFFSET : 0)
                | (permissions.afterAddLiquidityReturnsDelta ? 1 << HOOKS_AFTER_ADD_LIQUIDIY_RETURNS_DELTA_OFFSET : 0)
                | (permissions.afterRemoveLiquidityReturnsDelta ? 1 << HOOKS_AFTER_REMOVE_LIQUIDIY_RETURNS_DELTA_OFFSET : 0)
        );
    }

    function _getPoolKey(IERC20 outcomeToken, IERC20 usdmToken) internal view returns (PoolKey memory) {
        (Currency currency0, Currency currency1) = SortTokens.sort(outcomeToken, usdmToken);
        return PoolKey(
          currency0,
          currency1, 
          IHooks(address(this)), 
          manager, 
          FEE, 
          CLPoolParametersHelper.setTickSpacing(bytes32(uint256(getInternalHooksRegistrationBitmap())), 1)
        );
    }

    function _initializePool(PoolKey memory poolKey, IERC20 outcomeToken) internal {
        bool isToken0 = poolKey.currency0.toId() == Currency.wrap(address(outcomeToken)).toId();
        (int24 lowerTick, int24 upperTick) = getInitialOutcomeTokenTickRange(isToken0);
        int24 initialTick = isToken0 ? lowerTick - TICK_SPACING : upperTick + TICK_SPACING;

        uint160 initialSqrtPricex96 = TickMath.getSqrtRatioAtTick(initialTick);
        manager.initialize(poolKey, initialSqrtPricex96, ZERO_BYTES);
        poolKeys[poolKey.toId()] = poolKey;
    }

    /**
     * @notice Seeds single-sided liquidity into the outcome pools
     * @param lpPools The array of liquidity pool IDs
     */
    function _seedSingleSidedLiquidity(PoolId[] memory lpPools) internal {
        for (uint256 i = 0; i < lpPools.length; i++) {
            PoolId poolId = lpPools[i];
            PoolKey memory poolKey = poolKeys[poolId];

            require(
                poolKey.currency0.toId() != Currency.wrap(address(0)).toId()
                    && poolKey.currency1.toId() != Currency.wrap(address(0)).toId(),
                "Pool not found"
            );

            // Determine if the outcome token is token0 or token1
            bool isOutcomeToken0 = poolKey.currency0.toId() != usdm.toId();
            (int24 tickLower, int24 tickUpper) = getInitialOutcomeTokenTickRange(isOutcomeToken0);

            ICLPoolManager.ModifyLiquidityParams memory liquidityParams = ICLPoolManager.ModifyLiquidityParams({
                tickLower: tickLower,
                tickUpper: tickUpper,
                liquidityDelta: 100e18,
                salt: 0 // Optionally introduce salt to prevent duplicate liquidity provision
            });
            hookProvidedLiquidityForPool[poolId] = liquidityParams;
            modifyLiquidityRouter.modifyPosition(poolKey, liquidityParams, ZERO_BYTES);
        }
    }

    /**
     * @notice Initializes an event
     * @param fee The fee for the event
     * @param eventIpfsHash The IPFS hash of the event data
     * @param outcomes The array of outcomes
     * @param lpPools The array of liquidity pool IDs
     * @return eventId The ID of the created event
     */
    function _initializeEvent(
        uint24 fee,
        bytes memory eventIpfsHash,
        Outcome[] memory outcomes,
        PoolId[] memory lpPools
    ) internal returns (bytes32 eventId) {
        Event memory newEvent = Event({
            collateralToken: usdm,
            ipfsHash: eventIpfsHash,
            isOutcomeSet: false,
            outcomeResolution: UNINITIALIZED_OUTCOME,
            outcomes: outcomes,
            lpPools: lpPools
        });

        eventId = keccak256(abi.encode(usdm, eventIpfsHash, false, UNINITIALIZED_OUTCOME, outcomes, lpPools));

        events[eventId] = newEvent;

        // Map pool IDs to the event for easier indexing
        for (uint256 i = 0; i < lpPools.length; i++) {
            poolIdToEventId[lpPools[i]] = eventId;
        }

        emit EventCreated(eventId);
        return eventId;
    }

    /**
     * @notice Creates a market
     * @param fee The fee for the market
     * @param eventId The ID of the event associated with the market
     * @param oracle The oracle used for the market
     * @return marketId The ID of the created market
     */
    function _createMarket(uint24 fee, bytes32 eventId, IOracle oracle, PoolId[] memory lpPools) internal returns (bytes32 marketId) {
        Market memory market = Market({
            stage: Stage.CREATED,
            creator: msg.sender,
            createdAtBlock: block.number,
            usdmAmountAtSettlement: 0,
            eventId: eventId,
            oracle: oracle,
            fee: fee
        });

        marketId = keccak256(abi.encode(market));
        markets[marketId] = market;
        userMarkets[msg.sender].push(marketId);

         // Map pool IDs to the event for easier indexing
        for (uint256 i = 0; i < lpPools.length; i++) {
            poolIdToMarketId[lpPools[i]] = marketId;
        }

        emit MarketCreated(marketId, msg.sender);
        return marketId;
    }

    /**
     * @notice Deploys a centralized oracle
     * @param ipfsHash The IPFS hash associated with the oracle data
     * @return The deployed oracle instance
     */
    function _deployOracle(bytes memory ipfsHash) internal returns (IOracle) {
        return new CentralisedOracle(ipfsHash, address(this));
    }

    /**
     * @notice Provides the tick range for liquidity provisioning
     * @param isToken0 Whether the outcome token is token0
     * @return lowerTick The lower tick
     * @return upperTick The upper tick
     */
    function getInitialOutcomeTokenTickRange(bool isToken0) private pure returns (int24 lowerTick, int24 upperTick) {
        if (isToken0) {
            // Outcome token to USDM
            return (-46050, 23030);
        } else {
            // USDM to Outcome token
            return (-23030, 46050);
        }
    }

    function getPriceInUsdm(PoolId poolId) public view returns (uint256) {
        (uint160 sqrtPriceX96,,,) = manager.getSlot0(poolId);
        require(sqrtPriceX96 != 0, "Invalid pool ID, price=0");
        
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
