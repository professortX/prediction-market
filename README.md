# Vorhersage
### **Powered by Pancakeswap v4 Hooks 🥞🐰🥞** and Brevis 🔐⛓🖇
Unlimited Upside Tokenized
Prediction Market

Vorhersage is a prediction market that uses memecoins to forecast real life events. Each outcome is represented as an ERC20 token. The protocol uses single-sided liquidity pools on Pancakeswap to bootstrap liquidity for these ERC20 tokens.

ERC20 tokens offer traders the potential for unlimited upside, enhancing the overall trading experience.

At the end of the settlement date, a portion of the trading fees and the entire USD reserves of the losing pool will be distributed the holders of the winning outcome token. Eigenlayer AVS / Optimistic Oracles (e.g. UMA) will be used as an oracle to determine the event outcome.

### ** Brevis Usage **

With Brevis, Our protocol has unlocked the possibility of becoming more data centric protocol, We are using brevis to read historial on chain data of our uniswap swap functions, and calculate the top traders over a period of time. Finally, we will distribute Rewards from our Protocol Revenue to the top traders 🏆

More info in: https://github.com/professortX/prediction-market/tree/main/brevis

---

## Set up

*requires [foundry](https://book.getfoundry.sh)*

```
forge install
forge test
```

### Local Development (Anvil)

Other than writing unit tests (recommended!), you can only deploy & test hooks on [anvil](https://book.getfoundry.sh/anvil/)

```bash
./setup-local.sh
```

To kill the anvil process, you may run `kill-anvil.sh`.
