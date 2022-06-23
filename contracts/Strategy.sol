// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.6.12;
pragma experimental ABIEncoderV2;

import {BaseStrategy, StrategyParams} from "@yearnvaults/contracts/BaseStrategy.sol";
import "@openzeppelin/contracts/math/Math.sol";
import {
    SafeERC20,
    SafeMath,
    IERC20,
    Address
} from "@openzeppelin/contracts/token/ERC20/SafeERC20.sol";

import "../interfaces/curve/IStableSwapExchange.sol";
import "../interfaces/liquity/IPriceFeed.sol";
import "../interfaces/liquity/IStabilityPool.sol";
import "../interfaces/uniswap/ISwapRouter.sol";
import "../interfaces/BaseFee/IBaseFee.sol";
import "../interfaces/weth/IWETH9.sol";

contract Strategy is BaseStrategy {
    using SafeERC20 for IERC20;
    using Address for address;
    using SafeMath for uint256;

    // LQTY rewards accrue to Stability Providers who deposit LUSD to the Stability Pool
    IERC20 internal constant LQTY =
        IERC20(0x6DEA81C8171D0bA574754EF6F8b412F2Ed88c54D);

    // Source of liquidity to repay debt from liquidated troves
    IStabilityPool internal constant stabilityPool =
        IStabilityPool(0x66017D22b0f8556afDd19FC67041899Eb65a21bb);

    // Chainlink ETH:USD with Tellor ETH:USD as fallback
    IPriceFeed internal constant priceFeed =
        IPriceFeed(0x4c517D4e2C851CA76d7eC94B805269Df0f2201De);

    // Uniswap v3 router to do LQTY->ETH
    ISwapRouter internal constant router =
        ISwapRouter(0xE592427A0AEce92De3Edee1F18E0157C05861564);

    // LUSD3CRV Curve Metapool
    IStableSwapExchange internal constant curvePool =
        IStableSwapExchange(0xEd279fDD11cA84bEef15AF5D39BB4d4bEE23F0cA);

    // Wrapped Ether - Used for swaps routing
    IWETH9 internal constant WETH =
        IWETH9(0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2);

    // DAI - Used for swaps routing
    IERC20 internal constant DAI =
        IERC20(0x6B175474E89094C44Da98b954EedeAC495271d0F);

    // Switch between Uniswap v3 (low liquidity) and Curve to convert DAI->LUSD
    bool public convertDAItoLUSDonCurve;

    // Allow changing fees to take advantage of cheaper or more liquid Uniswap pools
    uint24 public lqtyToEthFee;
    uint24 public ethToDaiFee;
    uint24 public daiToLusdFee;

    // Minimum expected output when swapping
    // This should be relative to MAX_BPS representing 100%
    uint256 public minExpectedSwapPercentage;

    // 100%
    uint256 internal constant MAX_BPS = 10000;

    // keeper stuff
    uint256 public harvestProfitMin; // minimum size that we want to harvest
    uint256 public harvestProfitMax; // maximum size that we want to harvest
    /***
        Variables for tend() and tendTrigger() to make sure we are actively swapping ETH out
    ***/
    //Bool repersenting whether or not we should tip the keeper calling tend()
    //Will likely only need to be set during high volatility due to many subsequent tend() calls 
    bool public tip = false;
    //The max amount of ETH should be in relation to the total value of the strat i.e. 100 == 1%
    uint256 public maxEthPercent;
    //The absolute max amount of ETH we will allow the strat to hold
    uint256 public maxEthAmount;
    //Percent relative to MAX_BPS of the most we will give as a tip in claimEthAndSell() in relation to the claimed ETH up to estimatedCallCost
    uint256 public tipPercent = 100;
    //Max eth to sell in one transaction through calimEthAndSell()
    uint256 public maxEthToSell;

    constructor(address _vault) public BaseStrategy(_vault) {
        // Use curve as default route to swap DAI for LUSD
        convertDAItoLUSDonCurve = true;

        // Set health check to health.ychad.eth
        healthCheck = 0xDDCea799fF1699e98EDF118e0629A974Df7DF012;

        // Set default pools to use on Uniswap
        lqtyToEthFee = 3000;
        ethToDaiFee = 3000;
        daiToLusdFee = 500;

        // Allow % slippage by default
        minExpectedSwapPercentage = 9500;

        //Deploy on expectation of ~1m TVL between .1 -1% gain
        harvestProfitMin = 1_000e18;
        harvestProfitMax = 10_000e18;
        //Initiall set to 1%
        maxEthPercent = 100;
        maxEthAmount = 100e18;
        //Set to max on deploy and updated later if needed to
        maxEthToSell = type(uint256).max;
    }

    // Strategy should be able to receive ETH
    receive() external payable {}

    // ----------------- SETTERS & EXTERNAL CONFIGURATION -----------------

    // Allow governance to claim any outstanding ETH balance
    // This is done to provide additional flexibility since this is ETH and not WETH
    // so gov cannot sweep it
    function swallowETH() external onlyGovernance {
        (bool sent, ) = msg.sender.call{value: address(this).balance}("");
        require(sent); // dev: could not send ether to governance
    }

    // Allow governance to wrap any outstanding ETH balance
    function wrapETH() external onlyGovernance {
        WETH.deposit{value: address(this).balance}();
    }

    // Switch between Uniswap v3 (low liquidity) and Curve to convert DAI->LUSD
    function setConvertDAItoLUSDonCurve(bool _convertDAItoLUSDonCurve)
        external
        onlyEmergencyAuthorized
    {
        convertDAItoLUSDonCurve = _convertDAItoLUSDonCurve;
    }

    // Take advantage of cheaper Uniswap pools
    // Setting a non-existent pool will cause the swap operation to revert
    function setSwapFees(
        uint24 _lqtyToEthFee,
        uint24 _ethToDaiFee,
        uint24 _daiToLusdFee
    ) external onlyEmergencyAuthorized {
        lqtyToEthFee = _lqtyToEthFee;
        ethToDaiFee = _ethToDaiFee;
        daiToLusdFee = _daiToLusdFee;
    }

    // Ideally we would receive fair market value by performing every swap
    // through Flashbots. However, since we may be swapping capital and not
    // only profits, it is important to do our best to avoid bad swaps or
    // sandwiches in case we end up in an uncle block.
    function setMinExpectedSwapPercentage(uint256 _minExpectedSwapPercentage)
        external
        onlyEmergencyAuthorized
    {
        minExpectedSwapPercentage = _minExpectedSwapPercentage;
    }

    //To update whether or not we should tip the keeper when calling tend()
    //Allows for many calls to be economical during volatile periods with a large amount of liquidations
    function setToTip(bool _tip) external onlyEmergencyAuthorized {
        tip = _tip;
    }

    //Change tend triggers and variables based on market conditions
    function setTendAmounts(
        uint256 _maxEthPercent,
        uint256 _maxEthAmount,
        uint256 _tipPercent,
        uint256 _maxEthToSell
    ) external onlyEmergencyAuthorized {
        require(_maxEthPercent <= MAX_BPS && _tipPercent < MAX_BPS, "Too Many Bips");
        require(_maxEthToSell > 0, "Can't be 0");
        maxEthPercent = _maxEthPercent;
        maxEthAmount = _maxEthAmount;
        tipPercent = _tipPercent;
        maxEthToSell = _maxEthToSell;
    }   

    // Min profit to start checking for harvests if gas is good, max will harvest no matter gas.
    function setHarvestTriggerParams(
        uint256 _harvestProfitMin,
        uint256 _harvestProfitMax
    ) external onlyEmergencyAuthorized {
        harvestProfitMin = _harvestProfitMin;
        harvestProfitMax = _harvestProfitMax;
    }

    // Wrapper around `provideToSP` to allow forcing a deposit externally
    // This could be useful to trigger LQTY / ETH transfers without harvesting.
    // `provideToSP` will revert if not enough funds are provided so no need
    // to have an additional check.
    function depositLUSD(uint256 _amount) external onlyEmergencyAuthorized {
        stabilityPool.provideToSP(_amount, address(0));
    }

    // Wrapper around `withdrawFromSP` to allow forcing a withdrawal externally.
    // This could be useful to trigger LQTY / ETH transfers without harvesting
    // or bypassing any scenario where strategy funds are locked (e.g: bad accounting).
    // `withdrawFromSP` will revert if there are no deposits. If _amount is larger
    // than the deposit it will return all remaining balance.
    function withdrawLUSD(uint256 _amount) external onlyEmergencyAuthorized {
        stabilityPool.withdrawFromSP(_amount);
    }

    // ----------------- BASE STRATEGY FUNCTIONS -----------------

    function name() external view override returns (string memory) {
        return "StrategyLiquityStabilityPoolLUSD";
    }

    //This treats 1 DAI = 1 LUSD which may not be true and should not be used for any real accounting
    function estimatedTotalAssets() public view override returns (uint256) {
        // 1 LUSD = 1 USD *guaranteed* (TM)
        return
            totalLUSDBalance().add(DAI.balanceOf(address(this))).add(
                totalETHBalance().mul(priceFeed.lastGoodPrice()).div(1e18)
            );
    }

    function prepareReturn(uint256 _debtOutstanding)
        internal
        override
        returns (
            uint256 _profit,
            uint256 _loss,
            uint256 _debtPayment
        )
    {
        // How much do we owe to the LUSD vault?
        uint256 totalDebt = vault.strategies(address(this)).totalDebt;

        // Claim LQTY/ETH and sell them for more LUSD
        //This should fail if we can not get enough LUSD due to peg
        _claimRewards();

        // At this point all ETH DAI and LQTY has been converted to LUSD
        uint256 totalAssetsAfterClaim = totalLUSDBalance();

        if (totalAssetsAfterClaim > totalDebt) {
            _profit = totalAssetsAfterClaim.sub(totalDebt);
            _loss = 0;
        } else {
            _profit = 0;
            _loss = totalDebt.sub(totalAssetsAfterClaim);
        }

        // We cannot incur in additional losses during liquidatePosition because they
        // have already been accounted for in the check above, so we ignore them
        uint256 _amountFreed;
        (_amountFreed, ) = liquidatePosition(_debtOutstanding.add(_profit));
        _debtPayment = Math.min(_debtOutstanding, _amountFreed);
        
    }

    function adjustPosition(uint256 _debtOutstanding) internal override {
        //Functions that should only be used during the Tend() call
        //Sell all available eth. Sends the estmated cost to call tend() as the argument
        claimAndSellEth(gasleft());

        if(DAI.balanceOf(address(this)) > 0) {
            //Try and swap DAI back to LUSD. Only use Curve so we can get an expected amount out to compare before swapping
            //This function should not fail even if we cant get enough LUSD at the moment
            _tryToSellDAIAmountForLUSDonCurve(DAI.balanceOf(address(this)));
        }
        

        // Provide any leftover balance to the stability pool
        // Use zero address for frontend as we are interacting with the contracts directly
        uint256 wantBalance = balanceOfWant();
        if (wantBalance > _debtOutstanding) {
            stabilityPool.provideToSP(
                wantBalance.sub(_debtOutstanding),
                address(0)
            );
        }
    }

    function liquidatePosition(uint256 _amountNeeded)
        internal
        override
        returns (uint256 _liquidatedAmount, uint256 _loss)
    {
        uint256 balance = balanceOfWant();

        // Check if we can handle it without withdrawing from stability pool
        if (balance >= _amountNeeded) {
            return (_amountNeeded, 0);
        }

        // Only need to free the amount of want not readily available
        uint256 amountToWithdraw = _amountNeeded.sub(balance);

        uint256 stabilityBalance = stabilityPool.getCompoundedLUSDDeposit(address(this));
        if(amountToWithdraw > stabilityBalance) {
            //This will cause withdraws to fail if is for more than our LUSD balance while we still have DAI in the strat
            //This way we do not report incorrect losses before DAI can be swapped back to LUSD
            require(DAI.balanceOf(address(this)) == 0, "To much DAI");
            stabilityPool.withdrawFromSP(stabilityBalance);
        } else {
            stabilityPool.withdrawFromSP(amountToWithdraw);
        }

        // After withdrawing from the stability pool it could happen that we have
        // enough LQTY / ETH to cover a loss before reporting it.
        // However, doing a swap at this point could make withdrawals insecure
        // and front-runnable, so we assume LUSD that cannot be returned is a
        // realized loss.
        uint256 looseWant = balanceOfWant();
        if (_amountNeeded > looseWant) {
            _liquidatedAmount = looseWant;
            _loss = _amountNeeded.sub(looseWant);
        } else {
            _liquidatedAmount = _amountNeeded;
            _loss = 0;
        }
    }

    function liquidateAllPositions()
        internal
        override
        returns (uint256 _amountFreed)
    {
        stabilityPool.withdrawFromSP(
            stabilityPool.getCompoundedLUSDDeposit(address(this))
        );
        //Swap any DAI back to LUSD
        //May need to adjust slippage allowed before this depending on peg
        uint256 daiB = DAI.balanceOf(address(this));
        if (daiB > 0) {
            _sellDAIAmountForLusd(daiB);
        }

        return balanceOfWant();
    }

    function prepareMigration(address _newStrategy) internal override {
        if (stabilityPool.getCompoundedLUSDDeposit(address(this)) <= 0) {
            return;
        }

        // Withdraw entire LUSD balance from Stability Pool
        // ETH + LQTY + DAI gains should be harvested before migrating
        // `migrate` will automatically forward all `want` in this strategy to the new one
        stabilityPool.withdrawFromSP(
            stabilityPool.getCompoundedLUSDDeposit(address(this))
        );
    }

    function protectedTokens()
        internal
        view
        override
        returns (address[] memory)
    {}

    function ethToWant(uint256 _amtInWei)
        public
        view
        virtual
        override
        returns (uint256)
    {
        return _amtInWei.mul(priceFeed.lastGoodPrice()).div(1e18);
    }

    // ----------------- PUBLIC BALANCES -----------------

    function balanceOfWant() public view returns (uint256) {
        return want.balanceOf(address(this));
    }

    function totalLUSDBalance() public view returns (uint256) {
        return
            balanceOfWant().add(
                stabilityPool.getCompoundedLUSDDeposit(address(this))
            );
    }

    function totalLQTYBalance() public view returns (uint256) {
        return
            LQTY.balanceOf(address(this)).add(
                stabilityPool.getDepositorLQTYGain(address(this))
            );
    }

    function totalETHBalance() public view returns (uint256) {
        return
            address(this).balance.add(
                stabilityPool.getDepositorETHGain(address(this))
            );
    }

    // ----------------- SUPPORT FUNCTIONS ----------

    function _checkAllowance(
        address _contract,
        IERC20 _token,
        uint256 _amount
    ) internal {
        if (_token.allowance(address(this), _contract) < _amount) {
            _token.safeApprove(_contract, 0);
            _token.safeApprove(_contract, type(uint256).max);
        }
    }

    function _claimRewards() internal {
        // Withdraw minimum amount to force LQTY and ETH to be claimed
        if (stabilityPool.getCompoundedLUSDDeposit(address(this)) > 0) {
            stabilityPool.withdrawFromSP(0);
        }

        // Convert LQTY rewards to DAI
        if (LQTY.balanceOf(address(this)) > 0) {
            _sellLQTYforDAI();
        }

        // Convert ETH obtained from liquidations to DAI
        uint256 ethB = address(this).balance;
        if (ethB > 0) {
            _sellETHforDAI(ethB);
        }

        // Convert all outstanding DAI back to LUSD
        uint256 daiB = DAI.balanceOf(address(this));
        if (daiB > 0) {
            _sellDAIAmountForLusd(daiB);
        }
    }

    // ----------------- TOKEN CONVERSIONS -----------------

    function _sellLQTYforDAI() internal {
        _checkAllowance(address(router), LQTY, LQTY.balanceOf(address(this)));

        bytes memory path =
            abi.encodePacked(
                address(LQTY), // LQTY-ETH
                lqtyToEthFee,
                address(WETH), // ETH-DAI
                ethToDaiFee,
                address(DAI)
            );

        // Proceeds from LQTY are not subject to minExpectedSwapPercentage
        // so they could get sandwiched if we end up in an uncle block
        router.exactInput(
            ISwapRouter.ExactInputParams(
                path,
                address(this),
                now,
                LQTY.balanceOf(address(this)),
                0
            )
        );
    }

    function _sellETHforDAI(uint256 ethBalance) internal {
        uint256 ethUSD = priceFeed.fetchPrice();

        // Balance * Price * Swap Percentage (adjusted to 18 decimals)
        uint256 minExpected =
            ethBalance
                .mul(ethUSD)
                .mul(minExpectedSwapPercentage)
                .div(MAX_BPS)
                .div(1e18);

        ISwapRouter.ExactInputSingleParams memory params =
            ISwapRouter.ExactInputSingleParams(
                address(WETH), // tokenIn
                address(DAI), // tokenOut
                ethToDaiFee, // ETH-DAI fee
                address(this), // recipient
                now, // deadline
                ethBalance, // amountIn
                minExpected, // amountOut
                0 // sqrtPriceLimitX96
            );

        router.exactInputSingle{value: ethBalance}(params);
        router.refundETH();
    }

    function _sellDAIAmountForLusd(uint256 _amount) internal {
        
        require(DAI.balanceOf(address(this)) >= _amount, "Not enough DAI");

        if (convertDAItoLUSDonCurve) {
            _sellDAIAmountForLUSDonCurve(_amount);
        } else {
            _sellDAIAmountForLUSDonUniswap(_amount);
        }
    }

    function _sellDAIAmountForLUSDonCurve(uint256 daiBalance) internal {

        _checkAllowance(address(curvePool), DAI, daiBalance);

        curvePool.exchange_underlying(
                1, // from DAI index
                0, // to LUSD index
                daiBalance, // amount
                daiBalance.mul(minExpectedSwapPercentage).div(MAX_BPS) // minDy
            );
    }

    function _sellDAIAmountForLUSDonUniswap(uint256 daiBalance) internal {

        _checkAllowance(address(router), DAI, daiBalance);

        ISwapRouter.ExactInputSingleParams memory params =
            ISwapRouter.ExactInputSingleParams(
                address(DAI), // tokenIn
                address(want), // tokenOut
                daiToLusdFee, // DAI-LUSD fee
                address(this), // recipient
                now, // deadline
                daiBalance, // amountIn
                daiBalance.mul(minExpectedSwapPercentage).div(MAX_BPS), // amountOut
                0 // sqrtPriceLimitX96
            );
        router.exactInputSingle(params);
    }
    
    //Function only called during tend() that will not send the tx unless we believe it will go through
    //This allows us to only sell the DAI if we can get enough out without the whole tx failing
    function _tryToSellDAIAmountForLUSDonCurve(uint256 _amount) internal {

        uint256 minOut = _amount.mul(minExpectedSwapPercentage).div(MAX_BPS);

        uint256 actualOut = curvePool.get_dy_underlying(1, 0, _amount);

        if(actualOut >= minOut) {
        
            _checkAllowance(address(curvePool), DAI, _amount);

            curvePool.exchange_underlying(
                1, // from DAI index
                0, // to LUSD index
                _amount, // amount
                minOut // minDy
            );
        }
    }

    //To be called during tend() if needed
    //Will reimburse the caller the amount to call or a maximum amount if tip == true
    //If we have an extreme amount of ETH maxEthtoSell can be updated before this call
    function claimAndSellEth(uint256 estimatedCallCost) internal {
        //First check so we do not continue during a harvest
        if(totalETHBalance() == 0) return;

        if (stabilityPool.getCompoundedLUSDDeposit(address(this)) > 0) {
            stabilityPool.withdrawFromSP(0);
        }

        uint256 ethBalance = Math.min(address(this).balance, maxEthToSell);
        //Second check to make sure we actually claimed eth
        if(ethBalance == 0) return;

        if(tip) {
            uint256 maxTip = ethBalance.mul(tipPercent).div(MAX_BPS);
            uint256 toTip = Math.min(maxTip, estimatedCallCost);
   
            (bool sent, ) = msg.sender.call{value: toTip}("");
            require(sent); // dev: could not send ether to governance
        }
        //have to reupdate to account for the tip that was sent
        ethBalance = Math.min(address(this).balance, maxEthToSell);
        
        _sellETHforDAI(ethBalance);
    }

    //To be called if we need to swap less than the full amount of DAI to LUSD due to the peg or current liquidity 
    function sellDaiAmountToLusd(uint256 _amount) external onlyEmergencyAuthorized {
        _sellDAIAmountForLusd(_amount);
    }

    function tendTrigger(uint256 callCostInWei) public view override returns (bool){
        uint256 totalAssets = estimatedTotalAssets();
        uint256 ethBalance = totalETHBalance();
        if(ethBalance == 0) return false;

        if(ethBalance >= maxEthAmount) return true;

        // check if the gas cost is higher than we allow. if it is, block tend.
        if (callCostInWei > ethBalance / 10) return false;

        uint256 ethInWant = ethToWant(ethBalance);
        uint256 maxAllowedEth = totalAssets.mul(maxEthPercent).div(MAX_BPS);

        if(ethInWant > maxAllowedEth) return true;

        return false;
    }

    //This expects TendTrigger is keeping up with ETH accumulation
    function harvestTrigger(uint256 callCostInWei) public view override returns (bool) {
        // Should not trigger if strategy is not active (no assets and no debtRatio). This means we don't need to adjust keeper job.
        if (!isActive()) {
            return false;
        }

        StrategyParams memory params = vault.strategies(address(this));
        uint256 assets = estimatedTotalAssets();
        uint256 debt = params.totalDebt;

        // harvest if we have a profit to claim at our upper limit without considering gas price
        uint256 claimableProfit = assets > debt ? assets.sub(debt) : 0;

        //Determines if we would likely be able to swap the expected profit from DAI -> LUSD. Should not harvest if not
        //Make sure there is a profit above 1 to avaid errors with curve call
        if(claimableProfit > 1) {
            if(curvePool.get_dy_underlying(1, 0, claimableProfit) < claimableProfit.mul(minExpectedSwapPercentage).div(MAX_BPS)) {
                return false;
            }
        }

        if (claimableProfit > harvestProfitMax) {
            return true;
        }

        // check if the base fee gas price is higher than we allow. if it is, block harvests.
        if (!isBaseFeeAcceptable()) {
            return false;
        }

        // harvest if we have a sufficient profit to claim, but only if our gas price is acceptable
        if (claimableProfit > harvestProfitMin) {
            return true;
        }
        
        // Should not trigger if we haven't waited long enough since previous harvest
        if (block.timestamp.sub(params.lastReport) < minReportDelay) return false;

        // harvest no matter what once we reach our maxDelay
        if (block.timestamp.sub(params.lastReport) > maxReportDelay) {
            return true;
        }

        // otherwise, we don't harvest
        return false;
    }
    
     // check if the current baseFee is below our external target
    function isBaseFeeAcceptable() internal view returns (bool) {
        return
            IBaseFee(0xb5e1CAcB567d98faaDB60a1fD4820720141f064F)
                .isCurrentBaseFeeAcceptable();
    }


}
