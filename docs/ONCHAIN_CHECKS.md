# On-Chain Checks (BSC)

This file records on-chain verification outputs from `script/ChainChecks.s.sol`.


## Run Command

```bash
forge script script/ChainChecks.s.sol --rpc-url "https://bsc-dataseed.binance.org/"
```

Factory hash check:

```bash
cast call 0xcA143Ce32Fe78f1f7019d7d551a6402fC5350c73 "INIT_CODE_PAIR_HASH()(bytes32)" --rpc-url https://bsc-dataseed.binance.org/
```


## Latest Output (2026-02-23)

```
+------------------+--------------------------------------------+
| Item             | Value                                      |
+------------------+--------------------------------------------+
| Diamond          | 0x1b6F2d3844C6ae7D56ceb3C3643b9060ba28FEb0   |
| Pair (BTCB/USDT) | 0x3F803EC2b816Ea7F06EC76aA2B6f2532F9892d62   |
| Token0           | 0x55d398326f99059fF775485246999027B3197955   |
| Token1           | 0x7130d2A12B9BCbFAe4f2634d864A1Ee1Ce3Ead9c   |
| Reserve0         | 89681934850007810006786                     |
| Reserve1         | 1371035204587529363                         |
| ALP              | 0x4E47057f45adF24ba41375a175dA0357cB3480E5   |
| Cooldown (sec)   | 172800                                      |
| ALP Price (1e8)  | 180337314                                   |
| INIT_CODE_HASH   | 0x00fb7f630766e6a796048ea87d01acd3068e8ff6   |
|                  | 7d078148a3fa3f4a84f69bd5                     |
+------------------+--------------------------------------------+
```


## Fee Confirmation (Pancake V2)

Fee is encoded in core swap math and periphery helpers:

- PancakePair `swap()` uses `balance * 1000 - amountIn * 2` -> 0.20% total fee.

- PancakeLibrary `getAmountOut` uses `amountIn * 998 / 1000` -> 0.20% fee.


References:

- PancakeSwap core: `https://raw.githubusercontent.com/pancakeswap/pancake-swap-core/master/contracts/PancakePair.sol`

- PancakeSwap periphery: `https://raw.githubusercontent.com/pancakeswap/pancake-swap-periphery/master/contracts/libraries/PancakeLibrary.sol`


Notes:

- `lastMintedTimestamp(address)` may not exist in the current diamond ABI; the script prints 0.

- INIT_CODE_HASH is sourced from the factory call `INIT_CODE_PAIR_HASH()`.

- `alpPrice()` appears to be 1e8-scaled (Aster pricing convention).
