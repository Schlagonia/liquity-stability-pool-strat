import pytest
from brownie import config
from brownie import Contract


@pytest.fixture(autouse=True)
def isolation(fn_isolation):
    pass


@pytest.fixture
def gov(accounts):
    yield accounts.at("0xFEB4acf3df3cDEA7399794D0869ef76A6EfAff52", force=True)


@pytest.fixture
def user(accounts):
    yield accounts[0]


@pytest.fixture
def rewards(accounts):
    yield accounts[1]


@pytest.fixture
def guardian(accounts):
    yield accounts[2]


@pytest.fixture
def management(accounts):
    yield accounts[3]


@pytest.fixture
def strategist(accounts):
    yield accounts[4]


@pytest.fixture
def keeper(accounts):
    yield accounts[5]


@pytest.fixture
def healthCheck():
    yield Contract("0xDDCea799fF1699e98EDF118e0629A974Df7DF012")


@pytest.fixture
def token():
    token_address = "0x5f98805A4E8be255a32880FDeC7F6728C6568bA0"  # this should be the address of the ERC-20 used by the strategy/vault (DAI)
    yield Contract(token_address)


@pytest.fixture
def amount(accounts, token, user):
    amount = 10_000 * 10 ** token.decimals()
    # In order to get some funds for the token you are about to use,
    # it impersonate an exchange address to use it's funds.
    reserve = accounts.at("0x3DdfA8eC3052539b6C9549F12cEA2C295cfF5296", force=True)
    token.transfer(user, amount, {"from": reserve})
    yield amount


@pytest.fixture
def lusd():
    yield Contract("0x5f98805A4E8be255a32880FDeC7F6728C6568bA0")


@pytest.fixture
def lusd_whale(accounts):
    yield accounts.at("0x3DdfA8eC3052539b6C9549F12cEA2C295cfF5296", force=True)


@pytest.fixture
def dai():
    yield Contract("0x6B175474E89094C44Da98b954EedeAC495271d0F")


@pytest.fixture
def dai_whale(accounts):
    yield accounts.at("0x2FAF487A4414Fe77e2327F0bf4AE2a264a776AD2", force=True)


@pytest.fixture
def lqty():
    yield Contract("0x6DEA81C8171D0bA574754EF6F8b412F2Ed88c54D")


@pytest.fixture
def lqty_whale(accounts):
    yield accounts.at("0x4f9Fbb3f1E99B56e0Fe2892e623Ed36A76Fc605d", force=True)


@pytest.fixture
def weth():
    token_address = "0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2"
    yield Contract(token_address)

@pytest.fixture
def gasOracle():
    yield Contract("0xb5e1CAcB567d98faaDB60a1fD4820720141f064F")

@pytest.fixture
def strategist_ms(accounts):
        # like governance, but better
    yield accounts.at("0x16388463d60FFE0661Cf7F1f31a7D658aC790ff7", force=True)
    
"""
@pytest.fixture
def weth_amout(user, weth):
    weth_amout = 10 ** weth.decimals()
    user.transfer(weth, weth_amout)
    yield weth_amout
"""

@pytest.fixture
def vault(pm, gov, rewards, guardian, management, token):
    Vault = pm(config["dependencies"][0]).Vault
    vault = guardian.deploy(Vault)
    vault.initialize(token, gov, rewards, "", "", guardian, management)
    vault.setDepositLimit(2 ** 256 - 1, {"from": gov})
    vault.setManagement(management, {"from": gov})
    yield vault


@pytest.fixture
def strategy(strategist, keeper, vault, Strategy, gov, gasOracle, strategist_ms):
    strategy = strategist.deploy(Strategy, vault)
    strategy.setKeeper(keeper)
    strategy.setDoHealthCheck(True, {"from": gov})
    vault.addStrategy(strategy, 10_000, 0, 2 ** 256 - 1, 1_000, {"from": gov})  

    # make all harvests permissive unless we change the value lower
    gasOracle.setMaxAcceptableBaseFee(2000 * 1e9, {"from": strategist_ms})
    #Set min swap fee lower due to current market
    strategy.setMinExpectedSwapPercentage(9500)
    yield strategy


@pytest.fixture
def test_strategy(strategist, keeper, vault, TestStrategy, gov):
    strategy = strategist.deploy(TestStrategy, vault)
    strategy.setKeeper(keeper)
    strategy.setDoHealthCheck(True, {"from": gov})
    vault.addStrategy(strategy, 10_000, 0, 2 ** 256 - 1, 1_000, {"from": gov})
    #Set min swap fee lower due to current market
    strategy.setMinExpectedSwapPercentage(9500)
    yield strategy


@pytest.fixture(scope="session")
def RELATIVE_APPROX():
    yield 1e-5
