# Sigma86

**Institutional Quantitative Execution Protocol**

Sigma86 is a deterministic liquidation solver for DAO treasuries. When a DAO needs to sell millions of dollars of native tokens over a multi-day horizon, traditional linear TWAP bleeds capital to AMM convexity (dx / (x + dx)) and MEV bots. 

Sigma86 adapts Wall Street's **Almgren-Chriss (2000)** optimal execution model to Constant Product Market Makers (CPMM). It derives a closed-form mapping from a DAO's Value-at-Risk (VaR) budget directly into an optimal hyperbolic decay schedule. This schedule is autonomously executed by an off-chain Bazantic agent via a gas-optimized Yul assembly vault, defended by Chainlink Oracles and Flashbots.

---

## 🏗️ Core Architecture

1. **Quantitative Solver (gent-gateway):**
   * Built in TypeScript, this MCP server ingests Chainlink historical volatility and the DAO's VaR budget to compute the optimal Almgren-Chriss fractional execution schedule.
2. **Autonomous Execution (azanticRecipe.ts):**
   * The Bazantic "Institutional Treasury Copilot" agent orchestrates the workflow: calculating the schedule, requesting quotes from the 1inch API, checking oracle bounds, and dispatching the transaction directly to Flashbots Protect RPC.
3. **On-Chain Trust Boundary (Sigma86Vault.sol):**
   * **Gas-Optimized Yul Core:** Bypasses Solidity's ABI encoding overhead by copying 1inch router calldata directly to memory. Lowering the base gas footprint frees up budget for higher effective priority fees, maximizing top-of-block inclusion probability.
   * **Oracle Circuit Breaker:** Validates realized execution price against live Chainlink data feeds. Reverts and pauses the schedule on consecutive slippage breaches.
   * **Self-Custodial:** Single-unwind proxy controlled exclusively by the DAO's dedicated treasury wallet (EOA or Multisig) with timelocked recovery functions.

---

## 📊 Empirical 1,000-Path Monte Carlo Benchmark

The solver includes a fully deterministic 1,000-path stochastic Monte Carlo simulator (5 seeds x 200 paths) comparing the Sigma86 schedule against a naive linear TWAP over a $1,000,000 portfolio unwind.

| Market Regime | Net Outperformance vs TWAP | Max Adverse Excursion (MAE) Impact |
| :--- | :--- | :--- |
| **Crash (-20% Trend)** | **+$12,321** | 9.09% Drawdown Avoided |
| **Martingale (0% Trend)** | **-$737 (-0.07%)** | Consistent with no directional edge |
| **Rally (+20% Trend)** | **-$18,003** | Explicit insurance premium paid |

*Note: In a driftless martingale, the -$737 underperformance exactly quantifies the cost of AMM convexity when front-loading volume, proving the mathematical invariants hold without spurious directional alpha.*

---

## 🛠️ Quick Start

### 1. Smart Contract Verification
Run the 35 passing unit, integration, and adversarial tests:
`ash
cd contracts
forge test -vvv
`

### 2. Autonomous Agent Recipe (End-to-End Test)
Run the Bazantic agent orchestration loop (Chainlink + Sigma86 Math + 1inch Quote + Trust Verification):
`ash
cd agent-gateway
npm install
npm run test:recipe
`

### 3. Reproduce Monte Carlo Backtest
Verify the deterministic performance metrics:
`ash
cd agent-gateway
npm run backtest
`

---
*Built for ETHOnline 2026. Start Fresh Track.*
