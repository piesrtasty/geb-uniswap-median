pragma solidity ^0.6.7;

import "ds-test/test.sol";
import "ds-weth/weth9.sol";
import "ds-token/token.sol";

import "./orcl/MockMedianizer.sol";
import "./geb/MockTreasury.sol";

import "../uni/UniswapV2Factory.sol";
import "../uni/UniswapV2Pair.sol";
import "../uni/UniswapV2Router02.sol";

import { UniswapConsecutiveSlotsPriceFeedMedianizer } from  "../UniswapConsecutiveSlotsPriceFeedMedianizer.sol";

abstract contract Hevm {
    function warp(uint256) virtual public;
}

// --- Token Contracts ---
contract USDC is DSToken {
    constructor(bytes32 symbol) public DSToken(symbol) {
        decimals = 6;
        mint(100 ether);
    }
}

// --- Median Contracts ---
contract ETHMedianizer is MockMedianizer {
    constructor() public {
        symbol = "ETHUSD";
    }
}
contract USDCMedianizer is MockMedianizer {
    constructor() public {
        symbol = "USDCUSD";
    }
}

contract UniswapConsecutiveSlotsPriceFeedMedianizerTest is DSTest {
    Hevm hevm;

    MockTreasury treasury;

    ETHMedianizer converterETHPriceFeed;
    USDCMedianizer converterUSDCPriceFeed;

    UniswapConsecutiveSlotsPriceFeedMedianizer uniswapRAIWETHMedianizer;
    UniswapConsecutiveSlotsPriceFeedMedianizer uniswapRAIUSDCMedianizer;

    UniswapV2Factory uniswapFactory;
    UniswapV2Router02 uniswapRouter;

    UniswapV2Pair raiWETHPair;
    UniswapV2Pair raiUSDCPair;

    DSToken rai;
    USDC usdc;
    WETH9_ weth;

    uint256 startTime = 1577836800;

    uint256 initTokenAmount  = 100000000 ether;
    uint256 initETHUSDPrice  = 250 * 10 ** 18;
    uint256 initUSDCUSDPrice = 10 ** 18;

    uint256 initETHRAIPairLiquidity = 5 ether;               // 1250 USD
    uint256 initRAIETHPairLiquidity = 294.672324375E18;      // 1 RAI = 4.242 USD

    uint256 initUSDCRAIPairLiquidity = 4.242E6;
    uint256 initRAIUSDCPairLiquidity = 1 ether;

    uint8   uniswapMedianizerGranularity            = 24;           // 1 hour
    uint256 converterScalingFactor                  = 1 ether;
    uint256 uniswapMedianizerWindowSize             = 86400;        // 24 hours
    uint256 uniswapETHRAIMedianizerDefaultAmountIn  = 1 ether;
    uint256 uniswapUSDCRAIMedianizerDefaultAmountIn = 10 ** 12 * 1 ether;

    uint256 simulatedConverterPriceChange = 2; // 2%

    uint256 ethRAISimulationExtraRAI = 100 ether;
    uint256 ethRAISimulationExtraETH = 0.5 ether;

    uint256 usdcRAISimulationExtraRAI = 10 ether;
    uint256 usdcRAISimulationExtraUSDC = 25E6;

    uint256 baseCallerReward = 15 ether;
    uint256 maxCallerReward  = 20 ether;
    uint256 maxRewardDelay   = 10;
    uint256 perSecondCallerRewardIncrease = 1.01E27;

    address alice = address(0x4567);
    address me;

    uint256 internal constant RAY = 10 ** 27;

    function setUp() public {
        me = address(this);

        hevm = Hevm(0x7109709ECfa91a80626fF3989D68f67F5b1DD12D);
        hevm.warp(startTime);

        // Setup Uniswap
        uniswapFactory = new UniswapV2Factory(address(this));
        createUniswapPairs();
        uniswapRouter = new UniswapV2Router02(address(uniswapFactory), address(weth));

        // Setup converter medians
        converterETHPriceFeed = new ETHMedianizer();
        converterETHPriceFeed.modifyParameters("medianPrice", initETHUSDPrice);

        converterUSDCPriceFeed = new USDCMedianizer();
        converterUSDCPriceFeed.modifyParameters("medianPrice", initUSDCUSDPrice);

        // Create treasury
        treasury = new MockTreasury(address(rai));
        rai.transfer(address(treasury), 5000 * baseCallerReward);

        // Setup Uniswap medians
        uniswapRAIWETHMedianizer = new UniswapConsecutiveSlotsPriceFeedMedianizer(
            address(0x1),
            address(uniswapFactory),
            address(treasury),
            uniswapETHRAIMedianizerDefaultAmountIn,
            uniswapMedianizerWindowSize,
            converterScalingFactor,
            baseCallerReward,
            maxCallerReward,
            perSecondCallerRewardIncrease,
            uniswapMedianizerGranularity
        );
        uniswapRAIUSDCMedianizer = new UniswapConsecutiveSlotsPriceFeedMedianizer(
            address(0x1),
            address(uniswapFactory),
            address(treasury),
            uniswapUSDCRAIMedianizerDefaultAmountIn,
            uniswapMedianizerWindowSize,
            converterScalingFactor,
            baseCallerReward,
            maxCallerReward,
            perSecondCallerRewardIncrease,
            uniswapMedianizerGranularity
        );

        // Set max reward increase delay
        uniswapRAIWETHMedianizer.modifyParameters("maxRewardIncreaseDelay", maxRewardDelay);
        uniswapRAIUSDCMedianizer.modifyParameters("maxRewardIncreaseDelay", maxRewardDelay);

        // Set treasury allowance
        treasury.setTotalAllowance(address(uniswapRAIWETHMedianizer), uint(-1));
        treasury.setPerBlockAllowance(address(uniswapRAIWETHMedianizer), uint(-1));

        treasury.setTotalAllowance(address(uniswapRAIUSDCMedianizer), uint(-1));
        treasury.setPerBlockAllowance(address(uniswapRAIUSDCMedianizer), uint(-1));

        // Set converter addresses
        uniswapRAIWETHMedianizer.modifyParameters("converterFeed", address(converterETHPriceFeed));
        uniswapRAIUSDCMedianizer.modifyParameters("converterFeed", address(converterUSDCPriceFeed));

        // Set target and denomination tokens
        uniswapRAIWETHMedianizer.modifyParameters("targetToken", address(rai));
        uniswapRAIWETHMedianizer.modifyParameters("denominationToken", address(weth));

        uniswapRAIUSDCMedianizer.modifyParameters("targetToken", address(rai));
        uniswapRAIUSDCMedianizer.modifyParameters("denominationToken", address(usdc));

        assertTrue(uniswapRAIWETHMedianizer.uniswapPair() != address(0));
        assertTrue(uniswapRAIUSDCMedianizer.uniswapPair() != address(0));

        // Add pair liquidity
        addPairLiquidityRouter(address(rai), address(weth), initRAIETHPairLiquidity, initETHRAIPairLiquidity);
        addPairLiquidityRouter(address(rai), address(usdc), initRAIUSDCPairLiquidity, initUSDCRAIPairLiquidity);
    }

    // --- Math ---
    function multiply(uint x, uint y) internal pure returns (uint z) {
        require(y == 0 || (z = x * y) / y == x, 'mul-overflow');
    }

    // --- Uniswap utils ---
    function createUniswapPairs() internal {
        // Create Tokens
        weth = new WETH9_();

        rai = new DSToken("RAI");
        rai.mint(initTokenAmount);

        usdc = new USDC("USDC");

        // Create WETH
        weth.deposit{value: initTokenAmount}();

        // Setup WETH/RAI pair
        uniswapFactory.createPair(address(weth), address(rai));
        raiWETHPair = UniswapV2Pair(uniswapFactory.getPair(address(weth), address(rai)));

        // Setup USDC/RAI pair
        uniswapFactory.createPair(address(usdc), address(rai));
        raiUSDCPair = UniswapV2Pair(uniswapFactory.getPair(address(usdc), address(rai)));
    }
    function addPairLiquidityRouter(address token1, address token2, uint256 amount1, uint256 amount2) internal {
        DSToken(token1).approve(address(uniswapRouter), uint(-1));
        DSToken(token2).approve(address(uniswapRouter), uint(-1));
        uniswapRouter.addLiquidity(token1, token2, amount1, amount2, amount1, amount2, address(this), now);
        UniswapV2Pair updatedPair = UniswapV2Pair(uniswapFactory.getPair(token1, token2));
        updatedPair.sync();
    }
    function addPairLiquidityTransfer(UniswapV2Pair pair, address token1, address token2, uint256 amount1, uint256 amount2) internal {
        DSToken(token1).transfer(address(pair), amount1);
        DSToken(token2).transfer(address(pair), amount2);
        pair.sync();
    }

    // --- Simulation Utils ---
    function simulateETHRAISamePrices() internal {
        for (uint i = 0; i < uint(uniswapMedianizerGranularity) + 1; i++) {
          hevm.warp(now + uniswapRAIWETHMedianizer.periodSize());
          uniswapRAIWETHMedianizer.updateResult(address(alice));
          raiWETHPair.sync();
        }
    }
    function simulateUSDCRAISamePrices() internal {
        for (uint i = 0; i < uint(uniswapMedianizerGranularity) + 1; i++) {
          hevm.warp(now + uniswapRAIUSDCMedianizer.periodSize());
          uniswapRAIUSDCMedianizer.updateResult(address(alice));
          raiUSDCPair.sync();
        }
    }
    function simulateBothOraclesSamePrices() internal {
        for (uint i = 0; i < uint(uniswapMedianizerGranularity) * 2; i++) {
          hevm.warp(now + uniswapRAIUSDCMedianizer.periodSize());
          uniswapRAIWETHMedianizer.updateResult(address(alice));
          uniswapRAIUSDCMedianizer.updateResult(address(alice));
          raiWETHPair.sync();
          raiUSDCPair.sync();
        }
    }
    function simulateWETHRAIPrices() internal {
        uint256 i;
        hevm.warp(now + 10);

        for (i = 0; i < uint(uniswapMedianizerGranularity) / 2; i++) {
          addPairLiquidityTransfer(raiWETHPair, address(rai), address(weth), ethRAISimulationExtraRAI, 0);
          uniswapRAIWETHMedianizer.updateResult(address(alice));
          hevm.warp(now + uniswapRAIWETHMedianizer.periodSize());
        }
        for (i = 0; i < uint(uniswapMedianizerGranularity) / 2; i++) {
          addPairLiquidityTransfer(raiWETHPair, address(rai), address(weth), 0, ethRAISimulationExtraETH);
          uniswapRAIWETHMedianizer.updateResult(address(alice));
          hevm.warp(now + uniswapRAIWETHMedianizer.periodSize());
        }
    }
    function simulateUSDCRAIPrices() internal {
        uint256 i;
        hevm.warp(now + 10);

        for (i = 0; i < uint(uniswapMedianizerGranularity) / 2; i++) {
          addPairLiquidityTransfer(raiUSDCPair, address(rai), address(usdc), usdcRAISimulationExtraRAI, 0);
          uniswapRAIUSDCMedianizer.updateResult(address(alice));
          hevm.warp(now + uniswapRAIUSDCMedianizer.periodSize());
        }
        for (i = 0; i < uint(uniswapMedianizerGranularity) / 2; i++) {
          addPairLiquidityTransfer(raiUSDCPair, address(rai), address(usdc), 0, usdcRAISimulationExtraUSDC);
          uniswapRAIUSDCMedianizer.updateResult(address(alice));
          hevm.warp(now + uniswapRAIUSDCMedianizer.periodSize());
        }
    }
    function simulatedBothOraclesPrices() public {
        uint256 i;
        hevm.warp(now + 10);

        for (i = 0; i < uint(uniswapMedianizerGranularity) / 2; i++) {
          addPairLiquidityTransfer(raiWETHPair, address(rai), address(weth), ethRAISimulationExtraRAI, 0);
          uniswapRAIWETHMedianizer.updateResult(address(alice));

          addPairLiquidityTransfer(raiUSDCPair, address(rai), address(usdc), usdcRAISimulationExtraRAI, 0);
          uniswapRAIUSDCMedianizer.updateResult(address(alice));

          hevm.warp(now + uniswapRAIWETHMedianizer.periodSize());
        }
        for (i = 0; i < uint(uniswapMedianizerGranularity) / 2; i++) {
          addPairLiquidityTransfer(raiWETHPair, address(rai), address(weth), 0, ethRAISimulationExtraETH);
          uniswapRAIWETHMedianizer.updateResult(address(alice));

          addPairLiquidityTransfer(raiUSDCPair, address(rai), address(usdc), 0, usdcRAISimulationExtraUSDC);
          uniswapRAIUSDCMedianizer.updateResult(address(alice));

          hevm.warp(now + uniswapRAIWETHMedianizer.periodSize());
        }
    }

    function test_correct_setup() public {
        assertEq(uniswapRAIWETHMedianizer.authorizedAccounts(me), 1);
        assertEq(uniswapRAIUSDCMedianizer.authorizedAccounts(me), 1);

        assertTrue(address(uniswapRAIWETHMedianizer.converterFeed()) == address(converterETHPriceFeed));
        assertTrue(address(uniswapRAIUSDCMedianizer.converterFeed()) == address(converterUSDCPriceFeed));

        assertTrue(address(uniswapRAIWETHMedianizer.uniswapFactory()) == address(uniswapFactory));
        assertTrue(address(uniswapRAIUSDCMedianizer.uniswapFactory()) == address(uniswapFactory));

        assertEq(uniswapRAIWETHMedianizer.defaultAmountIn(), uniswapETHRAIMedianizerDefaultAmountIn);
        assertEq(uniswapRAIUSDCMedianizer.defaultAmountIn(), uniswapUSDCRAIMedianizerDefaultAmountIn);

        assertEq(uniswapRAIWETHMedianizer.windowSize(), uniswapMedianizerWindowSize);
        assertEq(uniswapRAIUSDCMedianizer.windowSize(), uniswapMedianizerWindowSize);

        assertEq(uniswapRAIWETHMedianizer.updates(), 0);
        assertEq(uniswapRAIUSDCMedianizer.updates(), 0);

        assertEq(uniswapRAIWETHMedianizer.periodSize(), 3600);
        assertEq(uniswapRAIUSDCMedianizer.periodSize(), 3600);

        assertEq(uniswapRAIWETHMedianizer.maxRewardIncreaseDelay(), maxRewardDelay);
        assertEq(uniswapRAIUSDCMedianizer.maxRewardIncreaseDelay(), maxRewardDelay);

        assertEq(uniswapRAIWETHMedianizer.converterFeedScalingFactor(), converterScalingFactor);
        assertEq(uniswapRAIUSDCMedianizer.converterFeedScalingFactor(), converterScalingFactor);

        assertEq(uint256(uniswapRAIWETHMedianizer.granularity()), uniswapMedianizerGranularity);
        assertEq(uint256(uniswapRAIUSDCMedianizer.granularity()), uniswapMedianizerGranularity);

        assertTrue(uniswapRAIWETHMedianizer.targetToken() == address(rai));
        assertTrue(uniswapRAIUSDCMedianizer.targetToken() == address(rai));

        assertTrue(uniswapRAIWETHMedianizer.denominationToken() == address(weth));
        assertTrue(uniswapRAIUSDCMedianizer.denominationToken() == address(usdc));

        assertTrue(uniswapRAIWETHMedianizer.uniswapPair() == address(raiWETHPair));
        assertTrue(uniswapRAIUSDCMedianizer.uniswapPair() == address(raiUSDCPair));

        assertTrue(address(uniswapRAIWETHMedianizer.treasury()) == address(treasury));
        assertTrue(address(uniswapRAIUSDCMedianizer.treasury()) == address(treasury));

        assertEq(uniswapRAIWETHMedianizer.baseUpdateCallerReward(), baseCallerReward);
        assertEq(uniswapRAIUSDCMedianizer.baseUpdateCallerReward(), baseCallerReward);

        assertEq(uniswapRAIWETHMedianizer.maxUpdateCallerReward(), maxCallerReward);
        assertEq(uniswapRAIUSDCMedianizer.maxUpdateCallerReward(), maxCallerReward);

        assertEq(uniswapRAIWETHMedianizer.perSecondCallerRewardIncrease(), perSecondCallerRewardIncrease);
        assertEq(uniswapRAIUSDCMedianizer.perSecondCallerRewardIncrease(), perSecondCallerRewardIncrease);

        (uint256 medianPrice, bool isValid) = uniswapRAIWETHMedianizer.getResultWithValidity();
        assertEq(medianPrice, 0);
        assertTrue(!isValid);

        (medianPrice, isValid) = uniswapRAIUSDCMedianizer.getResultWithValidity();
        assertEq(medianPrice, 0);
        assertTrue(!isValid);

        (uint256 uniObservationsListLength, uint256 converterObservationsListLength) = uniswapRAIWETHMedianizer.getObservationListLength();
        assertEq(uniObservationsListLength, converterObservationsListLength);
        assertTrue(uniObservationsListLength == 0);

        (uniObservationsListLength, converterObservationsListLength) = uniswapRAIUSDCMedianizer.getObservationListLength();
        assertEq(uniObservationsListLength, converterObservationsListLength);
        assertTrue(uniObservationsListLength == 0);

        assertEq(raiWETHPair.balanceOf(address(this)), 38384392946547948802);
        assertEq(raiUSDCPair.balanceOf(address(this)), 2059611612872);

        assertEq(raiWETHPair.totalSupply(), 38384392946547949802);
        assertEq(raiUSDCPair.totalSupply(), 2059611613872);
    }
    function testFail_small_granularity() public {
        uniswapRAIWETHMedianizer = new UniswapConsecutiveSlotsPriceFeedMedianizer(
            address(converterETHPriceFeed),
            address(uniswapFactory),
            address(treasury),
            uniswapETHRAIMedianizerDefaultAmountIn,
            uniswapMedianizerWindowSize,
            converterScalingFactor,
            baseCallerReward,
            maxCallerReward,
            perSecondCallerRewardIncrease,
            1
        );
    }
    function testFail_max_reward_smaller_than_base() public {
        uniswapRAIWETHMedianizer = new UniswapConsecutiveSlotsPriceFeedMedianizer(
            address(converterETHPriceFeed),
            address(uniswapFactory),
            address(treasury),
            uniswapETHRAIMedianizerDefaultAmountIn,
            uniswapMedianizerWindowSize,
            converterScalingFactor,
            baseCallerReward,
            0,
            perSecondCallerRewardIncrease,
            uniswapMedianizerGranularity
        );
    }
    function testFail_negative_reward_increase() public {
        uniswapRAIWETHMedianizer = new UniswapConsecutiveSlotsPriceFeedMedianizer(
            address(converterETHPriceFeed),
            address(uniswapFactory),
            address(treasury),
            uniswapETHRAIMedianizerDefaultAmountIn,
            uniswapMedianizerWindowSize,
            converterScalingFactor,
            baseCallerReward,
            maxCallerReward,
            RAY - 1,
            uniswapMedianizerGranularity
        );
    }
    function testFail_window_not_evenly_divisible() public {
        uniswapRAIWETHMedianizer = new UniswapConsecutiveSlotsPriceFeedMedianizer(
            address(converterETHPriceFeed),
            address(uniswapFactory),
            address(treasury),
            uniswapETHRAIMedianizerDefaultAmountIn,
            uniswapMedianizerWindowSize,
            converterScalingFactor,
            baseCallerReward,
            maxCallerReward,
            perSecondCallerRewardIncrease,
            23
        );
    }
    function test_change_converter_feed() public {
        uniswapRAIWETHMedianizer.modifyParameters("converterFeed", address(0x123));
        uniswapRAIUSDCMedianizer.modifyParameters("converterFeed", address(0x123));

        assertTrue(address(uniswapRAIWETHMedianizer.converterFeed()) == address(0x123));
        assertTrue(address(uniswapRAIUSDCMedianizer.converterFeed()) == address(0x123));
    }
    function test_update_result_converter_throws() public {
        converterETHPriceFeed.modifyParameters("revertUpdate", 1);
        converterUSDCPriceFeed.modifyParameters("revertUpdate", 1);

        hevm.warp(now + 3599);
        assertEq(rai.balanceOf(alice), 0);

        // RAI/WETH
        uniswapRAIWETHMedianizer.updateResult(alice);
        (uint uniTimestamp, uint price0Cumulative, uint price1Cumulative) =
          uniswapRAIWETHMedianizer.uniswapObservations(0);
        (uint converterTimestamp, uint converterPrice) = uniswapRAIWETHMedianizer.converterFeedObservations(0);
        (uint256 medianPrice, bool isValid) = uniswapRAIWETHMedianizer.getResultWithValidity();
        uint256 converterPriceCumulative = uniswapRAIWETHMedianizer.converterPriceCumulative();

        assertEq(uint256(uniswapRAIWETHMedianizer.earliestObservationIndex()), 0);
        assertEq(converterPriceCumulative, initETHUSDPrice * 3599);
        assertEq(medianPrice, 0);
        assertTrue(!isValid);
        assertEq(converterTimestamp, now);
        assertEq(converterPrice, initETHUSDPrice * 3599);
        assertEq(uniTimestamp, now);
        assertEq(price0Cumulative, 1101312847350787220573278491526876720617);
        assertEq(price1Cumulative, 317082312251449702080310206411507700);
        assertEq(rai.balanceOf(alice), 0);
        assertEq(uniswapRAIWETHMedianizer.updates(), 1);

        // RAI/USDC
        uniswapRAIUSDCMedianizer.updateResult(alice);
        (uniTimestamp, price0Cumulative, price1Cumulative) =
          uniswapRAIUSDCMedianizer.uniswapObservations(0);
        (converterTimestamp, converterPrice) = uniswapRAIUSDCMedianizer.converterFeedObservations(0);
        (medianPrice, isValid) = uniswapRAIUSDCMedianizer.getResultWithValidity();
        converterPriceCumulative = uniswapRAIUSDCMedianizer.converterPriceCumulative();

        assertEq(uint256(uniswapRAIUSDCMedianizer.earliestObservationIndex()), 0);
        assertEq(converterPriceCumulative, initUSDCUSDPrice * 3599);
        assertEq(medianPrice, 0);
        assertTrue(!isValid);
        assertEq(converterTimestamp, now);
        assertEq(converterPrice, initUSDCUSDPrice * 3599);
        assertEq(uniTimestamp, now);
        assertEq(price0Cumulative, 4405251389407554133682521520241189416313059876349);
        assertEq(price1Cumulative, 79270578062783154942013374);
        assertEq(rai.balanceOf(alice), 0);
        assertEq(uniswapRAIUSDCMedianizer.updates(), 1);
    }
    function testFail_read_raieth_before_passing_granularity() public {
        hevm.warp(now + 3599);
        assertEq(rai.balanceOf(alice), 0);

        // RAI/WETH
        uniswapRAIWETHMedianizer.updateResult(alice);

        uint medianPrice = uniswapRAIWETHMedianizer.read();
    }
    function testFail_read_raiusdc_before_passing_granularity() public {
        hevm.warp(now + 3599);
        assertEq(rai.balanceOf(alice), 0);

        // RAI/USDC
        uniswapRAIUSDCMedianizer.updateResult(alice);

        uint medianPrice = uniswapRAIUSDCMedianizer.read();
    }
    function test_get_result_before_passing_granularity() public {
        hevm.warp(now + 3599);
        assertEq(rai.balanceOf(alice), 0);

        // RAI/WETH
        uniswapRAIWETHMedianizer.updateResult(alice);
        (uint256 medianPrice, bool isValid) = uniswapRAIWETHMedianizer.getResultWithValidity();
        assertTrue(!isValid);

        // RAI/USDC
        uniswapRAIUSDCMedianizer.updateResult(alice);
        (medianPrice, isValid) = uniswapRAIUSDCMedianizer.getResultWithValidity();
        assertTrue(!isValid);
    }
    function test_update_treasury_throws() public {
        MockRevertableTreasury revertTreasury = new MockRevertableTreasury();

        // Set treasury allowance
        revertTreasury.setTotalAllowance(address(uniswapRAIWETHMedianizer), uint(-1));
        revertTreasury.setPerBlockAllowance(address(uniswapRAIWETHMedianizer), uint(-1));

        revertTreasury.setTotalAllowance(address(uniswapRAIUSDCMedianizer), uint(-1));
        revertTreasury.setPerBlockAllowance(address(uniswapRAIUSDCMedianizer), uint(-1));

        uniswapRAIWETHMedianizer.modifyParameters("treasury", address(revertTreasury));
        uniswapRAIUSDCMedianizer.modifyParameters("treasury", address(revertTreasury));

        hevm.warp(now + 3599);
        assertEq(rai.balanceOf(alice), 0);

        // RAI/WETH
        uniswapRAIWETHMedianizer.updateResult(alice);
        // RAI/USDC
        uniswapRAIUSDCMedianizer.updateResult(alice);

        assertEq(rai.balanceOf(alice), 0);
    }
    function test_update_treasury_reward_treasury() public {
        hevm.warp(now + 3599);
        assertEq(rai.balanceOf(alice), 0);

        uint treasuryBalance = rai.balanceOf(address(treasury));

        // RAI/WETH
        uniswapRAIWETHMedianizer.updateResult(address(treasury));
        // RAI/USDC
        uniswapRAIUSDCMedianizer.updateResult(address(treasury));

        assertEq(rai.balanceOf(address(treasury)), treasuryBalance);
    }
    function testFail_update_ETHRAI_again_immediately() public {
        converterETHPriceFeed.modifyParameters("revertUpdate", 1);

        hevm.warp(now + 1);
        uniswapRAIWETHMedianizer.updateResult(address(this));

        hevm.warp(now + 1);
        uniswapRAIWETHMedianizer.updateResult(address(this));
    }
    function testFail_update_USDCRAI_again_immediately() public {
        converterUSDCPriceFeed.modifyParameters("revertUpdate", 1);

        hevm.warp(now + 1);
        uniswapRAIUSDCMedianizer.updateResult(address(this));

        hevm.warp(now + 1);
        uniswapRAIUSDCMedianizer.updateResult(address(this));
    }
    function testFail_update_result_ETH_converter_invalid_value() public {
        converterETHPriceFeed.modifyParameters("medianPrice", 0);
        hevm.warp(now + 3599);
        uniswapRAIWETHMedianizer.updateResult(address(this));
    }
    function testFail_update_result_USDC_converter_invalid_value() public {
        converterUSDCPriceFeed.modifyParameters("medianPrice", 0);
        hevm.warp(now + 3599);
        uniswapRAIUSDCMedianizer.updateResult(address(this));
    }
    function test_update_result() public {
        hevm.warp(now + 3599);

        // RAI/WETH
        uniswapRAIWETHMedianizer.updateResult(address(this));
        (uint uniTimestamp, uint price0Cumulative, uint price1Cumulative) =
          uniswapRAIWETHMedianizer.uniswapObservations(0);
        (uint converterTimestamp, uint converterPrice) = uniswapRAIWETHMedianizer.converterFeedObservations(0);
        (uint256 medianPrice, bool isValid) = uniswapRAIWETHMedianizer.getResultWithValidity();
        uint256 converterPriceCumulative = uniswapRAIWETHMedianizer.converterPriceCumulative();

        assertEq(uint256(uniswapRAIWETHMedianizer.earliestObservationIndex()), 0);
        assertEq(converterPriceCumulative, initETHUSDPrice * 3599);
        assertEq(medianPrice, 0);
        assertTrue(!isValid);
        assertEq(converterTimestamp, now);
        assertEq(converterPrice, initETHUSDPrice * 3599);
        assertEq(uniTimestamp, now);
        assertEq(price0Cumulative, 1101312847350787220573278491526876720617);
        assertEq(price1Cumulative, 317082312251449702080310206411507700);

        // RAI/USDC
        uniswapRAIUSDCMedianizer.updateResult(address(this));
        (uniTimestamp, price0Cumulative, price1Cumulative) =
          uniswapRAIUSDCMedianizer.uniswapObservations(0);
        (converterTimestamp, converterPrice) = uniswapRAIUSDCMedianizer.converterFeedObservations(0);
        (medianPrice, isValid) = uniswapRAIUSDCMedianizer.getResultWithValidity();
        converterPriceCumulative = uniswapRAIUSDCMedianizer.converterPriceCumulative();

        assertEq(uint256(uniswapRAIUSDCMedianizer.earliestObservationIndex()), 0);
        assertEq(converterPriceCumulative, initUSDCUSDPrice * 3599);
        assertEq(medianPrice, 0);
        assertTrue(!isValid);
        assertEq(converterTimestamp, now);
        assertEq(converterPrice, initUSDCUSDPrice * 3599);
        assertEq(uniTimestamp, now);
        assertEq(price0Cumulative, 4405251389407554133682521520241189416313059876349);
        assertEq(price1Cumulative, 79270578062783154942013374);
    }
    function test_simulate_same_prices() public {
        simulateBothOraclesSamePrices();

        assertEq(uniswapRAIWETHMedianizer.converterPriceCumulative(), initETHUSDPrice * uniswapRAIWETHMedianizer.periodSize() * uniswapMedianizerGranularity);
        assertEq(
          uniswapRAIWETHMedianizer.converterComputeAmountOut(
            uniswapRAIUSDCMedianizer.periodSize() * uniswapMedianizerGranularity, 10**18
          ), initETHUSDPrice
        );
        assertEq(uniswapRAIUSDCMedianizer.converterPriceCumulative(), initUSDCUSDPrice * uniswapRAIUSDCMedianizer.periodSize() * uniswapMedianizerGranularity);
        assertEq(
          uniswapRAIUSDCMedianizer.converterComputeAmountOut(
            uniswapRAIUSDCMedianizer.periodSize() * uniswapMedianizerGranularity, 10**18
          ), initUSDCUSDPrice
        );

        // RAI/WETH
        (uint256 medianPrice, bool isValid) = uniswapRAIWETHMedianizer.getResultWithValidity();
        assertTrue(isValid);
        assertEq(medianPrice, 4242000000004242000);

        // RAI/USDC
        (medianPrice, isValid) = uniswapRAIUSDCMedianizer.getResultWithValidity();
        assertTrue(isValid);
        assertEq(medianPrice, 4241999999999999999);

        uint observedPrice;
        for (uint i = 0; i < uniswapMedianizerGranularity; i++) {
            (, observedPrice) = uniswapRAIWETHMedianizer.converterFeedObservations(i);
            assertEq(observedPrice, initETHUSDPrice * uniswapRAIUSDCMedianizer.periodSize());
        }
        for (uint i = 0; i < uniswapMedianizerGranularity; i++) {
            (, observedPrice) = uniswapRAIUSDCMedianizer.converterFeedObservations(i);
            assertEq(observedPrice, initUSDCUSDPrice * uniswapRAIUSDCMedianizer.periodSize());
        }
    }
    function test_simulate_denominator_token_positive_price_jump() public {
        simulateBothOraclesSamePrices();

        // Initial checks
        assertEq(uniswapRAIWETHMedianizer.converterPriceCumulative(), initETHUSDPrice * uniswapRAIWETHMedianizer.periodSize() * uniswapMedianizerGranularity);
        assertEq(uniswapRAIUSDCMedianizer.converterPriceCumulative(), initUSDCUSDPrice * uniswapRAIWETHMedianizer.periodSize() * uniswapMedianizerGranularity);

        // Price jumps
        hevm.warp(now + uniswapRAIWETHMedianizer.periodSize());
        uint totalWETHDeviation = 24 * 10 ** 18;
        uint totalUSDCDeviation = 10 ** 18;

        converterETHPriceFeed.modifyParameters("medianPrice", initETHUSDPrice + totalWETHDeviation);
        uniswapRAIWETHMedianizer.updateResult(address(alice));
        raiWETHPair.sync();

        converterUSDCPriceFeed.modifyParameters("medianPrice", initUSDCUSDPrice + 10 ** 18);
        uniswapRAIUSDCMedianizer.updateResult(address(alice));
        raiUSDCPair.sync();

        assertEq(
          uniswapRAIWETHMedianizer.converterPriceCumulative() / (24 * uniswapRAIWETHMedianizer.periodSize()), 251000000000000000000
        );

        uint granularityAdjustedDeviation = uint(totalWETHDeviation) / uniswapMedianizerGranularity;
        assertEq(
          uniswapRAIWETHMedianizer.converterPriceCumulative(), initETHUSDPrice * 23 * uniswapRAIWETHMedianizer.periodSize() + (initETHUSDPrice + totalWETHDeviation) * uniswapRAIWETHMedianizer.periodSize()
        );
        assertEq(uniswapRAIWETHMedianizer.converterComputeAmountOut(uniswapRAIWETHMedianizer.periodSize() * uniswapMedianizerGranularity, 10**18), initETHUSDPrice + granularityAdjustedDeviation);

        granularityAdjustedDeviation = uint(totalUSDCDeviation) / uniswapMedianizerGranularity;
        assertEq(
          uniswapRAIUSDCMedianizer.converterPriceCumulative(), initUSDCUSDPrice * 23 * uniswapRAIWETHMedianizer.periodSize() + (initUSDCUSDPrice + totalUSDCDeviation) * uniswapRAIWETHMedianizer.periodSize()
        );
        assertEq(uniswapRAIUSDCMedianizer.converterComputeAmountOut(uniswapRAIWETHMedianizer.periodSize() * uniswapMedianizerGranularity, 10**18), initUSDCUSDPrice + granularityAdjustedDeviation);

        // RAI/WETH
        (uint256 medianPrice, bool isValid) = uniswapRAIWETHMedianizer.getResultWithValidity();
        assertTrue(isValid);
        assertEq(medianPrice, 4258968000004258968);

        // RAI/USDC
        (medianPrice, isValid) = uniswapRAIUSDCMedianizer.getResultWithValidity();
        assertTrue(isValid);
        assertEq(medianPrice, 4418749999999999996);
    }
    function test_get_result_after_passing_granularity() public {
        simulateETHRAISamePrices();
        simulateUSDCRAISamePrices();

        // RAI/WETH
        (, bool isValid) = uniswapRAIWETHMedianizer.getResultWithValidity();
        assertTrue(isValid);

        // RAI/USDC
        (, isValid) = uniswapRAIUSDCMedianizer.getResultWithValidity();
        assertTrue(isValid);
    }
    function test_read_after_passing_granularity() public {
        simulateETHRAISamePrices();
        simulateUSDCRAISamePrices();

        // RAI/WETH
        uint median = uniswapRAIWETHMedianizer.read();
        assertTrue(median > 0);

        // RAI/USDC
        median = uniswapRAIUSDCMedianizer.read();
        assertTrue(median > 0);
    }
    function test_thin_liquidity_one_round_simulate_prices() public {
        simulatedBothOraclesPrices();

        // RAI/WETH
        (uint256 medianPrice, bool isValid) = uniswapRAIWETHMedianizer.getResultWithValidity();
        assertTrue(isValid);
        assertEq(medianPrice, 1453547942576074365);

        // RAI/USDC
        (medianPrice, isValid) = uniswapRAIUSDCMedianizer.getResultWithValidity();
        assertTrue(isValid);
        assertEq(medianPrice, 664282923955431645);
    }
    function test_thin_liquidity_multi_round_simulate_prices() public {
        for (uint i = 0; i < 5; i++) {
          simulatedBothOraclesPrices();
        }

        // RAI/WETH
        (uint256 medianPrice, bool isValid) = uniswapRAIWETHMedianizer.getResultWithValidity();
        assertTrue(isValid);
        assertEq(medianPrice, 1453547942576074365);

        // // RAI/USDC
        (medianPrice, isValid) = uniswapRAIUSDCMedianizer.getResultWithValidity();
        assertTrue(isValid);
        assertEq(medianPrice, 664282923955431645);
    }
    function test_deep_liquidity_one_round_simulate_prices() public {
        // Add WETH/RAI liquidity
        addPairLiquidityRouter(address(rai), address(weth), initRAIETHPairLiquidity * 10000, initETHRAIPairLiquidity * 10000);
        // Add USDC/RAI liquidity
        addPairLiquidityRouter(address(rai), address(usdc), initRAIUSDCPairLiquidity * 10000, initUSDCRAIPairLiquidity * 10000);

        // Simulate market making
        simulatedBothOraclesPrices();

        // RAI/WETH
        (uint256 medianPrice, bool isValid) = uniswapRAIWETHMedianizer.getResultWithValidity();
        assertTrue(isValid);
        assertEq(medianPrice, 4241320060231180592);

        // RAI/USDC
        (medianPrice, isValid) = uniswapRAIUSDCMedianizer.getResultWithValidity();
        assertTrue(isValid);
        assertEq(medianPrice, 4211276632829492353);
    }
}