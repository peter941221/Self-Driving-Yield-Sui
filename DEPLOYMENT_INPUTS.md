# DEPLOYMENT_INPUTS

## 策略选择：Fork BSC 主网测试

**选择理由：**
- BSC Testnet 上 BTCB/USDT 和 WBNB/USDT 交易对不存在
- Aster ALP 和 1001x 合约仅在 BSC 主网部署
- Fork 测试可以与真实协议交互，展示完整功能
- 项目已有 40/40 测试通过，Fork suite A-F 已验证

---

## 运行 Fork 测试（推荐）

```bash
# 设置主网 RPC
$env:BSC_RPC_URL="https://bsc-dataseed.binance.org/"

# 运行全部测试
forge test

# 运行 Fork 套件 (A-F)
forge test --match-path test/ForkSuite.t.sol

# 运行适配器测试
forge test --match-path test/*Adapter.t.sol
```

---

## 备用：BSC Testnet 信息（仅供参考）

### 0) Safety
- DO NOT paste any private key into this file.
- You will set PRIVATE_KEY in your shell or in a local .env (gitignored).

### 1) Network
chain_id=97
rpc_url=https://data-seed-prebsc-1-s1.binance.org:8545

### 2) Token + Pancake addresses
PANCAKE_FACTORY=0x6725F303b657a9451d8BA641348b6761A6CC7a17
PANCAKE_ROUTER=0xD99D1c33F9fC3444f8101754aBC46c52416550D1
WBNB=0xae13d989daC2f0dEbFf460aC112a837C89BAa7cd
USDT=0x0fB5D7c73FA349A90392f873a4FA1eCf6a3d0a96
BTCB=0x3Fb6a6C06c7486BD194BB99a078B89B9ECaF4c82
BUSD=0xaB1a4d4f1D656d2450692D237fdD6C7f9146e814

### 3) Pair addresses (查询结果)
BTCB_USDT_PAIR=0x0000000000000000000000000000000000000000 (不存在)
BNB_USDT_PAIR=0x0000000000000000000000000000000000000000 (不存在)
WBNB_BUSD_PAIR=0x58C6Fc654b3deE6839b65136f61cB9120d96BCc6 (存在，有流动性)

### 4) Aster (测试网无)
ASTER_DIAMOND=N/A
