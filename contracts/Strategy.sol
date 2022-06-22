// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.6.12;
pragma experimental ABIEncoderV2;

import {BaseStrategy} from "@yearnvaults/contracts/BaseStrategy.sol";
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

    /***
        Variables for tend() and tendTrigger() to make sure we are actively swapping ETH out
    ***/
    //Bool repersenting whether or not we should tip the keeper calling tend()
    //Will likely only need to be set during high volatility due to many subsequent tend() calls 
    bool public tip = false;
    //The estimated call cost set during tend() based on the gas sent with the tx to calc the tip if applicable
    uint256 public tendCallCost;
    //The max amount of ETH should be in relation to the total value of the strat i.e. 100 == 1%
    uint256 public maxEthPercent;
    //The max amount of ETH denominated in ETH we will allow the strat to hold
    uint256 public maxEthAmount;
    //Percent relative to MAX_BPS of the most we will give as a tip in claimEthAndSell() in relation to the claimed ETH up to tendCallCost
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

        // Allow 2% slippage by default
        minExpectedSwapPercentage = 9800;

        //Initiall set to 1%
        maxEthPercent = 100;
        maxEthAmount = 10e18;
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
        if(tendTrigger(69)){
            tendCallCost = gasleft();
            claimAndSellEth();
        }
        if(DAI.balanceOf(address(this)) > 0) {
            //Try and swap DAI back to LUSD. Only use Curve so we can get an expected amount out to compare before swapping
            _sellDAIAmountForLUSDonCurve(DAI.balanceOf(address(this)));
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

        // Cannot withdraw more than what we have in deposit
        amountToWithdraw = Math.min(
            amountToWithdraw,
            stabilityPool.getCompoundedLUSDDeposit(address(this))
        );

        if (amountToWithdraw > 0) {
            stabilityPool.withdrawFromSP(amountToWithdraw);
        }

        // After withdrawing from the stability pool it could happen that we have
        // enough LQTY / ETH / DAI to cover a loss before reporting it.
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
        if (DAI.balanceOf(address(this)) > 0) {
            _sellDAIforLUSD();
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
        if (address(this).balance > 0) {
            _sellETHforDAI();
        }

        // Convert all outstanding DAI back to LUSD
        if (DAI.balanceOf(address(this)) > 0) {
            _sellDAIforLUSD();
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

    function _sellETHforDAI() internal {
        uint256 ethUSD = priceFeed.fetchPrice();
        uint256 ethBalance = address(this).balance;

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

        router.exactInputSingle{value: address(this).balance}(params);
        router.refundETH();
    }

    function _sellDAIforLUSD() internal {
        // These methods will assume 1 DAI = 1 LUSD and attempt to enforce
        // min output to be at least minExpectedSwapPercentage of balance
        if (convertDAItoLUSDonCurve) {
            _sellDAIforLUSDonCurve();
        } else {
            _sellDAIforLUSDonUniswap();
        }
    }

    function _sellDAIforLUSDonCurve() internal {
        uint256 daiBalance = DAI.balanceOf(address(this));

        _checkAllowance(address(curvePool), DAI, daiBalance);

        curvePool.exchange_underlying(
                1, // from DAI index
                0, // to LUSD index
                daiBalance, // amount
                daiBalance.mul(minExpectedSwapPercentage).div(MAX_BPS) // minDy
            );
    }

    function _sellDAIforLUSDonUniswap() internal {
        uint256 daiBalance = DAI.balanceOf(address(this));

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

    function _swapDaiAmountToLusd(uint256 _amount) internal {
        
        if(DAI.balanceOf(address(this)) == 0) return;

        if (convertDAItoLUSDonCurve) {
            _sellDAIAmountForLUSDonCurve(_amount);
        } else {
            _sellDAIAmountForLUSDonUniswap(_amount);
        }
    }

    function _sellDAIAmountForLUSDonCurve(uint256 _amount) internal {

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

    function _sellDAIAmountForLUSDonUniswap(uint256 _amount) internal {

        _checkAllowance(address(router), DAI, _amount);

        ISwapRouter.ExactInputSingleParams memory params =
            ISwapRouter.ExactInputSingleParams(
                address(DAI), // tokenIn
                address(want), // tokenOut
                daiToLusdFee, // DAI-LUSD fee
                address(this), // recipient
                now, // deadline
                _amount, // amountIn
                _amount.mul(minExpectedSwapPercentage).div(MAX_BPS), // amountOut
                0 // sqrtPriceLimitX96
            );
        router.exactInputSingle(params);
    }

    //To be called during tend() if needed
    //Will reimburse the caller the amount to call or a maximum amount if tip == true
    //If we have an extreme amount of ETH maxEthtoSell can be updated before this call
    function claimAndSellEth() internal {
        if (stabilityPool.getCompoundedLUSDDeposit(address(this)) > 0) {
            stabilityPool.withdrawFromSP(0);
        }

        if(tip) {
            uint256 maxTip = address(this).balance.mul(tipPercent).div(MAX_BPS);
            uint256 toTip = Math.min(maxTip, tendCallCost);
   
            (bool sent, ) = msg.sender.call{value: toTip}("");
            require(sent); // dev: could not send ether to governance
        }
        //have to reupdate to account for the tip that was sent
        uint256 ethBalance = Math.min(address(this).balance, maxEthToSell);
        if(ethBalance == 0) return;
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

    //To be called if we need to swap less than the full amount of DAI to LUSD due to the peg or current liquidity 
    function swapDaiAmountToLusd(uint256 _amount) external onlyEmergencyAuthorized {
        _swapDaiAmountToLusd(_amount);
    }

    function tendTrigger(uint256 callCostInWei) public view override returns (bool){

        uint256 totalAssets = estimatedTotalAssets();
        uint256 ethBalance = totalETHBalance();

        if(ethBalance >= maxEthAmount) return true;

        uint256 ethInWant = ethToWant(ethBalance);
        uint256 maxAllowedEth = totalAssets.mul(maxEthPercent).div(MAX_BPS);

        if(ethInWant > maxAllowedEth) return true;

        return false;
    }

}
