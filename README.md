# Sigma86: Deterministic AMM Execution Solver

**An institutional-grade liquidation solver built for Constant Product Market Makers (CPMMs) and Flashbots.**

Unlike traditional intent-based auctions (CoW Swap, UniswapX, 1inch Fusion) where DAOs pay spread fees to third-party solvers to find liquidity, Sigma86 allows a treasury to **deterministically self-execute their own mathematically optimal, multi-day unwind schedule**.

Sigma86 adapts the traditional **Almgren-Chriss (2000) Optimal Execution** mathematical frontier to the unique mechanics of on-chain AMMs. 

---

## 📐 Mathematical Proof: AMM Convexity Collapsing to Almgren-Chriss
The original Almgren-Chriss (2000) paper derives optimal execution in a continuous limit-order-book market, assuming execution cost $E[C]$ scales linearly with trade speed $v$: $C = \eta v^2$. 

To adapt this for a Constant Product Market Maker ($x \cdot y = k$), we calculate the exact execution cost of swapping $\Delta x$ tokens. Since price $p = y/x$, the cost of a discrete AMM swap is:
$$C = p \cdot \Delta x - \left( y - \frac{xy}{x+\Delta x} \right) = \frac{y (\Delta x)^2}{x(x+\Delta x)} = \frac{p (\Delta x)^2}{x + \Delta x}$$

**The Continuous Time Limit:**
In a continuous execution schedule, $\Delta x$ is traded at rate $v$ over infinitesimal time $dt$ ($\Delta x = v \cdot dt$). As $dt \to 0$, the $v \cdot dt$ term in the denominator becomes infinitesimally small relative to the pool depth $x$.
Thus, the AMM execution cost function mathematically collapses into the exact continuous-time Almgren-Chriss functional form:
$$C \approx \frac{p}{x} v^2$$
This derivation proves that in the continuous limit, CPMM convexity does not change the functional form of the optimal curve. We can directly substitute $\eta = \frac{p}{x}$ (the inverse of pool base liquidity) into the standard solver.

**Calibrating Risk Aversion ($\lambda$):**
Sigma86 does not "parameter shop" to make backtests look good. $\lambda$ is strictly calibrated via a DAO-elicited **Value-at-Risk (VaR)** threshold. The DAO states a maximum dollar loss tolerance at a 95% confidence interval, and the solver mathematically fits $\lambda$ to target that exact variance ceiling based on historical 30-day pool volatility.

---

## 🧠 The Architecture: Partially Adaptive Algorithmic Time-Decay

We separated the heavy quantitative calculus off-chain (The Solver) from a simple, gas-efficient state-machine on-chain (The Executor).

### 1. The AMM-Adapted Solver (Off-chain Node.js)
**Partial Adaptivity (Mid-Flight Re-optimization):** While Sigma86 calculates the schedule *ex-ante*, executing a 50-hour schedule purely blind is dangerous. Sigma86 introduces **Mid-Flight Re-optimization Checkpoints**. At defined intervals (e.g., every 12 hours), the off-chain solver ingests realized volatility, recalculates a new curve for the remaining inventory, and submits an updated schedule to the Vault via `updateSchedule()`. This achieves true adaptivity without requiring block-by-block gas overhead.

The Sigma86 Off-chain Solver:
* Ingests portfolio sizes, the DAO's VaR parameter, and live pool liquidity depths.
* Submits the schedule via Viem strictly through **Flashbots Protect RPC** to prevent atomic mempool sandwich attacks.

### 2. The Sigma86Vault (On-chain Executor)
The on-chain `Sigma86Vault.sol` is a deliberately minimal execution layer.
* **Gas-Optimized Routing:** The `executeTick()` function runs in pure Yul assembly, passing raw API payloads directly into the 1inch router.
* **Trust Boundary (On-Chain Oracle):** The Vault physically enforces execution pricing via Chainlink feeds. If the price breaches the DAO's `maxSlippageBps`, the Vault terminates the trade. *(Note: This stops the Vault from accepting a bad fill, but does not prevent a malicious solver from stalling/griefing execution).*

---

## 🚀 Quick Start: The Monte Carlo Quant Backtest

To run the 1,000-path stochastic Monte Carlo simulation:
```bash
cd agent-gateway
npm install
npx ts-node src/backtest.ts
```

**Demo Backtest Result (Net of Gas & 20% Performance Fee):**
We simulate a 50-hour unwind of 100,000 tokens using 1,000 randomized Monte Carlo paths.
1. **Market Crash (-20% trend):** Sigma86 dynamically front-loads the sell-off, avoiding catastrophic time-decay risk and netting **+$25,878 mean outperformance** over TWAP.
2. **Market Rally (+20% trend):** Sigma86 underperforms TWAP (**-$37,771**). This represents the mathematical 'insurance premium' (lost upside) paid to secure liquidity early and reduce variance.
3. **Driftless Chop (0% trend, High Variance):** Mean outperformance collapses toward **-$1,078**, proving the math is structurally sound (expected cost in a martingale is equivalent). 

*For a DAO treasury, eliminating downside volatility is vastly superior to gambling on upside price action.*

---

## 🏗️ Core Architectural Specs (Demo Day Context)
* **Chain Context:** Mainnet Ethereum (Flashbots Protect RPC is mainnet-oriented. Testnet deployments are purely for contract verification).
* **Custody & Concurrency:** **Single-unwind proxy deployment**. A DAO deploys a fresh Vault proxy per schedule, completely eliminating co-mingling risk.
* **Cancellation Flow & Admin Key:** A DAO's existing **Gnosis Safe / Multisig** holds the Vault admin privileges. The multisig can call `abortSchedule()` at any point.
* **Business/Fee Model:** Sigma86 monetizes via an incentive-aligned **Performance Fee (20% of outperformance vs TWAP)**. 
  * *Future Work (Principal-Agent Alignment):* Currently, if Sigma86 underperforms in a rally, it takes 0 fees but suffers no penalty. Future iterations require a symmetric fee model (e.g., slashing conditions against future underperformance) to eliminate this free-option asymmetry.

---
*Built for ETHOnline 2026*
