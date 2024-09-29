// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {IHooks} from "pancake-v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "pancake-v4-core/src/libraries/Hooks.sol";
import {TickMath} from "pancake-v4-core/src/pool-cl/libraries/TickMath.sol";
import {IPoolManager} from "pancake-v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "pancake-v4-core/src/types/PoolKey.sol";
import {BalanceDelta, BalanceDeltaLibrary} from "pancake-v4-core/src/types/BalanceDelta.sol";
import {PoolId, PoolIdLibrary} from "pancake-v4-core/src/types/PoolId.sol";
import {IERC20Minimal} from "pancake-v4-core/src/interfaces/IERC20Minimal.sol";
import {CurrencyLibrary, Currency} from "pancake-v4-core/src/types/Currency.sol";
// import {PoolSwapTest} from "pancake-v4-core/src/test/PoolSwapTest.sol";
import {Deployers} from "pancake-v4-core/test/pool-cl/helpers/Deployers.sol";
// import {StateLibrary} from "pancake-v4-core/src/libraries/StateLibrary.sol";
// import {SetUpLibrary} from "./utils/SetUpLibrary.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {IOracle} from "../../src/pool-cl/interface/IOracle.sol";
import {CentralisedOracle} from "../../src/pool-cl/CentralisedOracle.sol";
import {PredictionMarketHook} from "../../src/pool-cl/PredictionMarketHook.sol";
import {PredictionMarket} from "../../src/pool-cl/PredictionMarket.sol";
import {IPredictionMarket} from "../../src/pool-cl/interface/IPredictionMarket.sol";
import {Ownable} from "openzeppelin-contracts/contracts/access/Ownable.sol";
import {ICLPoolManager} from "pancake-v4-core/src/pool-cl/interfaces/ICLPoolManager.sol";
import {CLPoolManager} from "pancake-v4-core/src/pool-cl/CLPoolManager.sol";

import {PoolIdLibrary} from "pancake-v4-core/src/types/PoolId.sol";
import {CLPoolParametersHelper} from "pancake-v4-core/src/pool-cl/libraries/CLPoolParametersHelper.sol";
import {CLTestUtils} from "./utils/CLTestUtils.sol";
import {CLPoolManagerRouter} from "pancake-v4-core/test/pool-cl/helpers/CLPoolManagerRouter.sol";


/**
 * What is liquidity delta?
 *
 *  https://uniswap.org/whitepaper-v3.pdf
 *  Section 6.29 & 6.30
 *
 *  Definition:
 *  - P_a -> lower price range
 *  - P_b -> upper price range
 *  - P -> current price
 *  - lDelta -> liquidity delta
 *
 *  3 scenarios when providing liquidity to calculate liquidity delta:
 *
 *  1. P < P_a
 *
 *  lDelta = xDelta / (1/sqrt(P_a) - 1/sqrt(P_b))
 *
 *  2. P_a < P < P_b
 *
 *  lDelta = xDelta / (1/sqrt(P) - 1/sqrt(P_b)) = yDelta / (sqrt(P) - sqrt(P_a))
 *
 *  3. P > P_b
 *
 *  lDelta = yDelta / (sqrt(P_b) - sqrt(P_a))
 */
contract PredictionMarketHookTest is Test, CLTestUtils, Deployers {
  using PoolIdLibrary for PoolKey;
  using CLPoolParametersHelper for bytes32;

  bytes IPFS_BYTES = abi.encode("QmbU7wZ5UttANT56ZHo3CAxbpfYXbo8Wj9fSXkYunUDByP");
  bytes32 marketId; // Created marketId

  Currency yes;
  Currency no;
  Currency usdm;

  CLPoolManagerRouter router;

  PredictionMarketHook predictionMarketHook;

  PoolKey yesUsdmKey;
  PoolKey noUsdmKey;

  // Sorted YES-USDM
  Currency[2] yesUsdmLp;
  // Sorted NO-USDM
  Currency[2] noUsdmLp;

  IOracle oracle;
  // Smaller ticks have more precision, but cost more gas (vice-versa)
  int24 private TICK_SPACING = 10;

  // Users
  address USER_A = address(0xa);
  address USER_B = address(0xb);
  address USER_C = address(0xc);


  function deployAndApproveCurrency(string memory name) private returns (Currency) {
    MockERC20 usdmErc20 = new MockERC20(name, "USDM", 18);

    // approve permit2 contract to transfer our funds
    usdmErc20.approve(address(permit2), type(uint256).max);
    permit2.approve(address(usdmErc20), address(positionManager), type(uint160).max, type(uint48).max);
    permit2.approve(address(usdmErc20), address(universalRouter), type(uint160).max, type(uint48).max);

    return Currency.wrap(address(usdmErc20));
  }

  function _initializeMarketsHelperFn(bytes memory ipfsDetails, string[] memory outcomeNames)
        private
        returns (bytes32, PoolId[] memory, IPredictionMarket.Outcome[] memory, IOracle oracle)
    {
        IPredictionMarket.OutcomeDetails[] memory outcomeDetails =
            new IPredictionMarket.OutcomeDetails[](outcomeNames.length);
        for (uint256 i = 0; i < outcomeNames.length; i++) {
            outcomeDetails[i] = IPredictionMarket.OutcomeDetails(ipfsDetails, outcomeNames[i]);
        }

        (bytes32 marketId, PoolId[] memory poolIds, IPredictionMarket.Outcome[] memory pmOutcomes, IOracle oracle) =
            predictionMarketHook.initializeMarket(0, ipfsDetails, outcomeDetails);
        return (marketId, poolIds, pmOutcomes, oracle);
    }

  function setUp() public {
      (Currency c1, Currency c2) = deployContractsWithTokens();

      usdm = deployAndApproveCurrency("USM");

      (vault, poolManager) = createFreshManager();
      router = new CLPoolManagerRouter(vault, poolManager);
      
      predictionMarketHook = new PredictionMarketHook(usdm, poolManager, router);

      // Created a ipfs detail from question.json
      bytes memory ipfsDetail = IPFS_BYTES;
      string[] memory outcomeNames = new string[](2);
      outcomeNames[0] = "YES";
      outcomeNames[1] = "NO";
      (bytes32 _marketId, PoolId[] memory poolIds, IPredictionMarket.Outcome[] memory outcomes, IOracle oracles) =
          _initializeMarketsHelperFn(ipfsDetail, outcomeNames);
      yes = outcomes[0].outcomeToken;
      no = outcomes[1].outcomeToken;
      oracle = oracles;
      marketId = _marketId;
      yesUsdmKey = predictionMarketHook.getPoolKeyByPoolId(poolIds[0]);
      noUsdmKey = predictionMarketHook.getPoolKeyByPoolId(poolIds[1]);
      yesUsdmLp = [yes, usdm];
      noUsdmLp = [no, usdm];
  }

   /**
     * Check oracle and pool poolManager state after the markets have been initialized
     * Ensure oracle is set up correctly and has the correct access controls
     */
    function test_initializeMarkets() public {
        // Check balances in poolmanager
        assertEq(usdm.balanceOf(address(poolManager)), 0);
        assertApproxEqRel(yes.balanceOf(address(vault)), 9.68181772459792e20, 1e9);
        assertApproxEqRel(no.balanceOf(address(vault)), 9.68181772459792e20, 1e9);
        // ===== ORACLE CHECK =====
        // Check if oracle is set up correctly
        assertEq(oracle.getOutcome(), 0);
        assertEq(oracle.isOutcomeSet(), false);
        assertEq(oracle.getIpfsHash(), IPFS_BYTES);
        // Attempted to set the outcome without the correct access control
        vm.prank(USER_A);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, USER_A));
        oracle.setOutcome(1);
        vm.prank(address(predictionMarketHook));
        oracle.setOutcome(1);
        assertEq(oracle.getOutcome(), 1);
        vm.prank(address(predictionMarketHook));
        oracle.setOutcome(0); // Reset to 0
    }

    function test_getInitialPrice() public {
      // $1 = 1e18. $0.01 = 1e16
      // Current price should be approximately $0.01 at launch
      assertApproxEqRel(predictionMarketHook.getPriceInUsdm(yesUsdmKey.toId()), 1e16, 1e15);
    }


    function testFuzz_getPriceInUsdm(PoolId poolId) public {
        // expect revert for InvalidPool(poolId)
        vm.expectRevert();
        predictionMarketHook.getPriceInUsdm(poolId);
    }

    function test_claimWithoutResolution() public {
        vm.expectRevert("Market not resolved");
        predictionMarketHook.claim(marketId, 1e18);
    }

    function test_FuzzSettle(bytes32 marketId, int16 outcome) public {
        vm.expectRevert();
        predictionMarketHook.settle(marketId, outcome);
    }

    function test_FuzzClaim(bytes32 marketId, uint256 outcomeTokenAmountToClaim) public {
        vm.expectRevert();
        predictionMarketHook.claim(marketId, outcomeTokenAmountToClaim);
    }

     // Helper function
    function uintToInt(uint256 _value) internal pure returns (int256) {
        require(_value <= uint256(type(int256).max), "Value exceeds int256 max limit");
        return int256(_value);
    }

}