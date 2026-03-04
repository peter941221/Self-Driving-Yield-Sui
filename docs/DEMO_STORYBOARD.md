# Demo Storyboard (3 Minutes)

> **录制前准备**: 打开VSCode，终端字体调大(16pt+)，关闭不相关窗口

---

## Scene 1 (0:00 - 0:25) 🎯 开场钩子

### 画面
```
┌─────────────────────────────────────────────────────┐
│  VSCode打开 README.md                               │
│  滚动到 "Key Ideas" 部分                             │
│  高亮 "Dual Engine" 和 "ALP as a Hedge"             │
└─────────────────────────────────────────────────────┘
```

### 台词
> "Imagine a yield vault that **hedges itself**. When markets are calm, it earns LP fees. When volatility spikes, it shifts to ALP — which actually profits from chaos. No admin, no keeper, fully autonomous."

### 关键点
- 🎣 用"self-hedging"作为钩子
- 💡 突出ALP的"short volatility"特性

---

## Scene 2 (0:25 - 0:55) 🏗️ 架构展示

### 画面
```
┌─────────────────────────────────────────────────────┐
│  滚动到 README 的 Architecture 图                    │
│  手势指向数据流向                                    │
└─────────────────────────────────────────────────────┘
```

### 台词
> "Here's how it works: Users deposit USDT into the EngineVault. The vault allocates across three engines — ALP for yield, Pancake V2 LP for fees, and 1001x for delta hedging. A TWAP oracle monitors volatility and triggers regime switches."

### 关键点
- 📊 强调"三引擎"协同
- ⚡ 指出TWAP oracle的核心作用

---

## Scene 3 (0:55 - 1:30) 🛡️ 安全机制

### 画面
```
┌─────────────────────────────────────────────────────┐
│  打开 THREAT_MODEL.md                               │
│  滚动到 "Key Risks & Mitigations"                   │
│  或打开 README 的 "Hackathon Pillars" 表格          │
└─────────────────────────────────────────────────────┘
```

### 台词
> "Security is baked in. We have ONLY_UNWIND mode that stops risky deployments during flash crashes. Bounties are capped to prevent gaming. All parameters are immutable — there's literally no admin key to rug."

### 关键点
- 🔒 "No admin key" 是强有力的卖点
- ⚠️ 强调ONLY_UNWIND的熔断机制

---

## Scene 4 (1:30 - 2:10) ✅ 测试验证

### 画面
```
┌─────────────────────────────────────────────────────┐
│  切换到终端 (字体大!)                               │
│  运行: forge test                                   │
│  等待 "40 passed" 输出                              │
└─────────────────────────────────────────────────────┘
```

### 命令
```bash
forge test
```

### 台词
> "All 40 tests pass. This includes unit tests, invariant tests, fork tests, and negative cases like the ONLY_UNWIND trigger. We also ran Slither static analysis with zero findings."

### 关键点
- 📈 数字"40"有说服力
- 🔬 提到invariant和negative tests显专业

---

## Scene 5 (2:10 - 2:45) 🎬 实时演示

### 画面
```
┌─────────────────────────────────────────────────────┐
│  终端继续                                           │
│  运行: forge script script/ForkCycleDemo.s.sol     │
│  指向输出中的 "Shares", "Regime", "TotalAssets"    │
└─────────────────────────────────────────────────────┘
```

### 命令 (提前确保能跑通!)
```bash
forge script script/ForkCycleDemo.s.sol --rpc-url https://bsc-dataseed.binance.org/
```

### 台词
> "Here's a live fork demo on BSC mainnet. We deposit USDT, run cycle(), and watch the vault rebalance. You can see shares minted, regime detected, and assets allocated."

### 关键点
- 🎥 实时演示最有力
- 💻 提前测试确保命令成功

---

## Scene 6 (2:45 - 3:00) 🏁 收尾

### 画面
```
┌─────────────────────────────────────────────────────┐
│  回到 README                                        │
│  滚动到 "Status" 部分                               │
│  或显示项目GitHub链接                               │
└─────────────────────────────────────────────────────┘
```

### 台词
> "Self-Driving Yield Engine — autonomous, trustless, and built for volatility. Check out the repo for full code and docs. Thanks!"

### 关键点
- 🔗 留下GitHub链接印象
- ⏱️ 控制在3分钟内

---

## 📋 录制检查清单

```
□ 提前运行 forge test 确认全绿
□ 提前运行 ForkCycleDemo 确认能跑
□ 终端字体调大 (16pt+)
□ 关闭通知/弹窗
□ 准备好VSCode布局
□ 录制软件就绪 (OBS/Win+G)
□ 麦克风测试
□ 计时练习一遍
```

## 🎬 录制技巧

1. **语速**: 稍快但清晰，不要拖沓
2. **停顿**: 场景切换时停顿1秒
3. **手势**: 鼠标高亮关键词
4. **音量**: 确保声音清晰，无背景噪音
5. **剪辑**: 可以后期加速/裁剪，不必一次完美 
