import brownie
import pytest

from brownie import chain, reverts, Wei


def test_claim(chain, token, vault, strategy, user, amount, weth, dai, accounts, gov, RELATIVE_APPROX):
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
    accounts.at(weth, force=True).transfer(strategy, Wei("1 ether"))
    before_eth = gov.balance()
    assert strategy.balance() == 1e18
    chain.sleep(1)
    strategy.claimAndSellEth(1, {"from": gov})

    assert dai.balanceOf(strategy.address) > 0
    assert strategy.balance() == 0


def test_claim_and_harvest(chain, token, vault, strategy, user, strategist, amount, weth, dai, accounts, gov, RELATIVE_APPROX):
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
    strategy.claimAndSellEth(100e18, {"from": gov})

    assert strategy.balance() == 0
    assert dai.balanceOf(strategy.address) > 0
    #Turn off health check because profit will be higher
    strategy.setDoHealthCheck(False, {"from":gov})
    chain.sleep(1)
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

def test_tip_change(
    chain, token, vault, strategy, user, strategist, amount, weth, dai, accounts, gov, RELATIVE_APPROX
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

    accounts.at(weth, force=True).transfer(strategy, Wei("1 ether"))
    before_eth = gov.balance()
    assert strategy.balance() == 1e18
    chain.sleep(1)
    strategy.claimAndSellEth(100e18, {"from": gov})
    assert before_eth + (1e18 * .01) >= gov.balance()

    strategy.setTipPercent(10)
    accounts.at(weth, force=True).transfer(strategy, Wei("1 ether"))
    before_eth = gov.balance()
    assert strategy.balance() == 1e18
    chain.sleep(1)
    strategy.claimAndSellEth(100e18, {"from": gov})
    assert before_eth + (1e18 * .001) >= gov.balance()

    with reverts():
        strategy.setTipPercent(10001)


def test_claim_and_withdraw_no_harvest(chain, token, vault, strategy, user, amount, weth, dai, accounts, gov, RELATIVE_APPROX):
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
    accounts.at(weth, force=True).transfer(strategy, Wei("1 ether"))
    before_eth = gov.balance()
    assert strategy.balance() == 1e18
    chain.sleep(1)
    strategy.claimAndSellEth(100, {"from": gov})

    assert strategy.balance() == 0
    assert dai.balanceOf(strategy.address) > 0
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

    strategy.swapDaiAmountToLusd(amount/2, {"from": strategist})
    assert dai.balanceOf(strategy.address) <= amount /2

    strategy.swapDaiAmountToLusd(dai.balanceOf(strategy.address), {"from": strategist})
    #may be a slight amount left due to calculations
    assert dai.balanceOf(strategy.address) < amount/10

def test_max_eth_sell(
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

    strategy.setMaxEthToSell(1e18)
    accounts.at(weth, force=True).transfer(strategy, Wei("2 ether"))

    assert strategy.balance() == 2e18
    chain.sleep(1)
    strategy.claimAndSellEth(100, {"from": gov})

    #Need to accunt for the call cost that is being reimbursed
    assert strategy.balance() == 1e18 - 100
    assert dai.balanceOf(strategy.address) > 0
    chain.sleep(1)
    # withdrawal
    vault.withdraw({"from": user})
    assert pytest.approx(token.balanceOf(user), rel=RELATIVE_APPROX) == amount
