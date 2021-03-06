import brownie
import pytest

from brownie import chain, reverts, Wei

def test_tend(chain, token, vault, strategy, user, amount, weth, dai, accounts, gov, RELATIVE_APPROX, gasOracle):
    #need to adjust maxTendBaseFee for a forked enviorment
    strategy.setTendAmounts(strategy.maxEthPercent(), strategy.maxEthAmount(), strategy.maxEthToSell(), 1001e9)
    # Deposit to the vault
    assert gasOracle.maxAcceptableBaseFee() == 2000 * 1e9
    user_balance_before = token.balanceOf(user)
    token.approve(vault.address, amount, {"from": user})
    vault.deposit(amount, {"from": user})
    assert token.balanceOf(vault.address) == amount

    # harvest
    chain.sleep(1)
    strategy.harvest()
    assets = strategy.estimatedTotalAssets()
    assert pytest.approx(assets, rel=RELATIVE_APPROX) == amount
    chain.sleep(1)
    shouldTend = strategy.tendTrigger(1)
    assert shouldTend == False

    accounts.at(weth, force=True).transfer(strategy, Wei("1 ether"))
    before_eth = gov.balance()
    assert strategy.balance() == 1e18
    chain.sleep(1)
    shouldTend = strategy.tendTrigger(1)
    assert shouldTend == True

    strategy.tend()

    assert strategy.balance() == 0
    assert strategy.estimatedTotalAssets() > assets

    accounts.at(weth, force=True).transfer(strategy, Wei("1 ether"))
    assert strategy.balance() == 1e18
    chain.sleep(1)
    shouldTend = strategy.tendTrigger(1)
    assert shouldTend == True
    strategy.setMinExpectedSwapPercentage(9900)
    chain.sleep(1)

    strategy.tend()

    assert strategy.balance() == 0
    assert dai.balanceOf(strategy.address) > 0


def test_tend_and_harvest(chain, token, vault, strategy, user, strategist, amount, weth, dai, accounts, keeper, gov, RELATIVE_APPROX):
    #need to adjust maxTendBaseFee for a forked enviorment
    strategy.setTendAmounts(strategy.maxEthPercent(), strategy.maxEthAmount(), strategy.maxEthToSell(), 1001e9)
    # Deposit to the vault
   
    user_balance_before = token.balanceOf(user)
    token.approve(vault.address, amount, {"from": user})
    vault.deposit(amount, {"from": user})
    assert token.balanceOf(vault.address) == amount

    # harvest
    chain.sleep(1)
    strategy.harvest()
    assert pytest.approx(strategy.estimatedTotalAssets(), rel=RELATIVE_APPROX) == amount

    accounts.at(weth, force=True).transfer(strategy, Wei("1 ether"))
    before_eth = gov.balance()
    assert strategy.balance() == 1e18
    chain.sleep(1)
    shouldTend = strategy.tendTrigger(1e17)
    assert shouldTend == True

    strategy.tend()

    assert strategy.balance() == 0

    #Turn off health check because profit will be higher than allowed
    strategy.setDoHealthCheck(False, {"from": gov})
    assert strategy.doHealthCheck() == False
   
    strategy.harvest()

    assert dai.balanceOf(strategy.address) == 0
    assert strategy.balance() == 0
    assert strategy.totalLUSDBalance() == strategy.estimatedTotalAssets()
    #assume we made a profit
    assert token.balanceOf(vault.address) > 0
    # withdrawal
    chain.sleep(3600 * 24)
    vault.withdraw({"from": user})
    assert token.balanceOf(user) > user_balance_before

def test_tend_and_withdraw_no_harvest(chain, token, vault, strategy, user, amount, weth, dai, accounts, gov, RELATIVE_APPROX):
    #need to adjust maxTendBaseFee for a forked enviorment
    strategy.setTendAmounts(strategy.maxEthPercent(), strategy.maxEthAmount(), strategy.maxEthToSell(), 1001e9)
    # Deposit to the vault
    user_balance_before = token.balanceOf(user)
    token.approve(vault.address, amount, {"from": user})
    vault.deposit(amount, {"from": user})
    assert token.balanceOf(vault.address) == amount

    # harvest
    chain.sleep(1)
    strategy.harvest()
    assert pytest.approx(strategy.estimatedTotalAssets(), rel=RELATIVE_APPROX) == amount
    chain.sleep(1)
    accounts.at(weth, force=True).transfer(strategy, Wei("10 ether"))
    before_eth = gov.balance()
    assert strategy.balance() == 10e18
    chain.sleep(1)
    shouldTend = strategy.tendTrigger(1e17)
    assert shouldTend == True

    strategy.tend()

    assert strategy.balance() == 0
    chain.sleep(1)
    # withdrawal
    vault.withdraw({"from": user})
    assert pytest.approx(token.balanceOf(user), rel=RELATIVE_APPROX) == amount

    
def test_manual_sell_dai(
    chain, token, vault, strategy, strategist, user, amount, weth, dai, dai_whale, accounts, gov, RELATIVE_APPROX
):
    # Deposit to the vault
    user_balance_before = token.balanceOf(user)
    token.approve(vault.address, amount, {"from": user})
    vault.deposit(amount, {"from": user})
    assert token.balanceOf(vault.address) == amount

    # harvest
    chain.sleep(1)
    strategy.harvest()
    assert pytest.approx(strategy.estimatedTotalAssets(), rel=RELATIVE_APPROX) == amount
    chain.sleep(1)

    dai.transfer(strategy.address, amount, {"from": dai_whale})
    assert dai.balanceOf(strategy.address) == amount

    strategy.sellDaiAmountToLusd(amount/2, {"from": strategist})
    assert dai.balanceOf(strategy.address) <= amount /2

    strategy.sellDaiAmountToLusd(dai.balanceOf(strategy.address), {"from": strategist})
    #may be a slight amount left due to calculations
    assert dai.balanceOf(strategy.address) < amount/10

def test_max_eth_sell(
    chain, token, vault, strategy, strategist, user, amount, weth, dai, dai_whale, accounts, gov, RELATIVE_APPROX
):
    #need to adjust maxTendBaseFee for a forked enviorment
    strategy.setTendAmounts(strategy.maxEthPercent(), strategy.maxEthAmount(), strategy.maxEthToSell(), 1001e9)
    # Deposit to the vault
    user_balance_before = token.balanceOf(user)
    token.approve(vault.address, amount, {"from": user})
    vault.deposit(amount, {"from": user})
    assert token.balanceOf(vault.address) == amount

    # harvest
    chain.sleep(1)
    strategy.harvest()
    assert pytest.approx(strategy.estimatedTotalAssets(), rel=RELATIVE_APPROX) == amount
    chain.sleep(1)

    strategy.setTendAmounts(strategy.maxEthPercent(), strategy.maxEthAmount(), 5e18, strategy.maxTendBaseFee())
    accounts.at(weth, force=True).transfer(strategy, Wei("10 ether"))

    assert strategy.balance() == 10e18
    chain.sleep(1)
    shouldTend = strategy.tendTrigger(1)
    assert shouldTend == True

    strategy.tend()

    #Need to accunt for the call cost that is being reimbursed
    assert strategy.balance() == 5e18

    chain.sleep(1)
    # withdrawal
    vault.withdraw({"from": user})
    assert pytest.approx(token.balanceOf(user), rel=RELATIVE_APPROX) == amount


def test_change_max_percent_and_amount(
    chain, token, vault, strategy, strategist, user, amount, weth, dai, dai_whale, accounts, gov, RELATIVE_APPROX
):
    #need to adjust maxTendBaseFee for a forked enviorment
    strategy.setTendAmounts(strategy.maxEthPercent(), strategy.maxEthAmount(), strategy.maxEthToSell(), 1001e9)
    # Deposit to the vault
    #amount = 100_000 * (10 ** token.decimals())
    user_balance_before = token.balanceOf(user)
    token.approve(vault.address, amount, {"from": user})
    vault.deposit(amount, {"from": user})
    assert token.balanceOf(vault.address) == amount

    # harvest
    chain.sleep(1)
    strategy.harvest()
    assert pytest.approx(strategy.estimatedTotalAssets(), rel=RELATIVE_APPROX) == amount
    chain.sleep(1)
    assert strategy.tendTrigger(1) == False
    
    accounts.at(weth, force=True).transfer(strategy, Wei(".01 ether"))
    chain.sleep(1)
    assert strategy.balance() == 1e16
    assert strategy.tendTrigger(100) == False

    strategy.setTendAmounts(strategy.maxEthPercent(), 1e16, strategy.maxEthToSell(), strategy.maxTendBaseFee())
    chain.sleep(1)

    assert strategy.tendTrigger(1) == True

    strategy.setTendAmounts(strategy.maxEthPercent(), 100e18, strategy.maxEthToSell(), strategy.maxTendBaseFee())
    chain.sleep(1)
    assert strategy.tendTrigger(1) == False

    strategy.setTendAmounts(1, strategy.maxEthAmount(), strategy.maxEthToSell(), strategy.maxTendBaseFee())
    chain.sleep(1)
    assert strategy.tendTrigger(1) == True

    chain.sleep(1)
    assert strategy.tendTrigger(1e18) == False

