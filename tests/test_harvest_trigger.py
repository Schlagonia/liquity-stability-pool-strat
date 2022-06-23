import brownie
from brownie import Contract
from brownie import config, Wei
import math

# test our harvest triggers
def test_triggers(
    gov,
    token,
    vault,
    accounts,
    weth,
    user,
    strategy,
    chain,
    amount,
    gasOracle,
    strategist_ms,
):

    # inactive strategy (0 DR and 0 assets) shouldn't be touched by keepers
    gasOracle.setMaxAcceptableBaseFee(10000 * 1e9, {"from": strategist_ms})
    vault.updateStrategyDebtRatio(strategy, 0, {"from": gov})
    tx = strategy.harvestTrigger(0, {"from": gov})
    print("\nShould we harvest? Should be false.", tx)
    assert tx == False
    vault.updateStrategyDebtRatio(strategy, 10000, {"from": gov})

    ## deposit to the vault after approving
    startinguser = token.balanceOf(user)
    token.approve(vault, 2**256 - 1, {"from": user})
    vault.deposit(amount, {"from": user})
    newuser = token.balanceOf(user)
    starting_assets = vault.totalAssets()

    # harvest the credit
    chain.sleep(1)
    strategy.harvest({"from": gov})
    chain.sleep(1)

    # should trigger false, nothing is ready yet
    tx = strategy.harvestTrigger(0, {"from": gov})
    print("\nShould we tend? Should be false.", tx)
    assert tx == False

    # simulate a day of earnings
    chain.sleep(86400)
    chain.mine(1)

    # set our max delay to 1 day so we trigger true, then set it back to 21 days
    strategy.setMaxReportDelay(86400)
    tx = strategy.harvestTrigger(0, {"from": gov})
    print("\nShould we harvest? Should be True.", tx)
    assert tx == True
    strategy.setMaxReportDelay(86400 * 21)

    accounts.at(weth, force=True).transfer(strategy, Wei("1 ether"))

    # update our minProfit so our harvest triggers true
    strategy.setHarvestTriggerParams(1e6, 1000000e18, {"from": gov})
    tx = strategy.harvestTrigger(0, {"from": gov})
    print("\nShould we harvest? Should be true.", tx)
    assert tx == True

    strategy.setMinExpectedSwapPercentage(9990)
    tx = strategy.harvestTrigger(0, {"from": gov})
    print("\nShould we harvest? Should be False.", tx)
    assert tx == False

    strategy.setMinExpectedSwapPercentage(9500)
    
    # update our maxProfit so harvest triggers true
    strategy.setHarvestTriggerParams(1000000e6, 1e6, {"from": gov})
    tx = strategy.harvestTrigger(0, {"from": gov})
    print("\nShould we harvest? Should be true.", tx)
    assert tx == True

    #Turn off health check because profit will be higher than allowed
    strategy.setDoHealthCheck(False, {"from": gov})
    # harvest, wait
    chain.sleep(1)
    strategy.harvest({"from": gov})
    chain.sleep(86400)
    chain.mine(1)

    # harvest should trigger false due to high gas price
    gasOracle.setMaxAcceptableBaseFee(1 * 1e9, {"from": strategist_ms})
    chain.mine(1)
    tx = strategy.harvestTrigger(0, {"from": gov})
    print("\nShould we harvest? Should be false.", tx)
    assert tx == False

    # withdraw and confirm we made money
    vault.withdraw({"from": user})
    assert token.balanceOf(user) >= startinguser