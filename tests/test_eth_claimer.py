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

    accounts.at(weth, force=True).transfer(strategy, Wei("1 ether"))
    beforeEth = gov.balance()
    assert strategy.balance() == 1e18
    strategy.claimAndSellEth({"from": gov})

    assert dai.balanceOf(strategy.address) > 0
    assert strategy.balance() == 0
    assert gov.balance() - beforeEth == 1e17


def test_claim_and_harvest(chain, token, vault, strategy, user, amount, weth, dai, accounts, gov, RELATIVE_APPROX):
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
    beforeEth = gov.balance()
    assert strategy.balance() == 1e18
    strategy.claimAndSellEth({"from": gov})

    assert strategy.balance() == 0
    assert gov.balance() - beforeEth == 1e17
    assert dai.balanceOf(strategy.address) > 0

    strategy.harvest()

    assert dai.balanceOf(strategy.address) == 0
    assert strategy.balance() == 0

    assert strategy.totalLUSDBalance() == strategy.estimatedTotalAssets()
    assert strategy.estimatedTotalAssets() > amount
    # withdrawal
    vault.withdraw({"from": user})
    assert token.balanceOf(user) > user_balance_before

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

    accounts.at(weth, force=True).transfer(strategy, Wei("1 ether"))
    beforeEth = gov.balance()
    assert strategy.balance() == 1e18
    strategy.claimAndSellEth({"from": gov})

    assert strategy.balance() == 0
    assert gov.balance() - beforeEth == 1e17
    assert dai.balanceOf(strategy.address) > 0

    # withdrawal
    vault.withdraw({"from": user})
    assert pytest.approx(token.balanceOf(user), rel=RELATIVE_APPROX) == amount

    