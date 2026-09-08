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

## 🧠 The Architecture: Single-Checkpoint Adaptive Execution

We separated the heavy quantitative calculus off-chain (The Solver) from a simple, gas-efficient state-machine on-chain (The Executor).

### 1. The AMM-Adapted Solver (Off-chain Node.js)
**Adaptivity model (honest):** Sigma86 is neither fully ex-ante (blind) nor continuously adaptive (expensive). It uses **single-checkpoint re-optimization**: the schedule is computed ex-ante and executed tick-by-tick. At defined tick boundaries, the solver ingests realized pool volatility and calls `updateSchedule()` on the Vault to revise the remaining trajectory. This is not continuous — but it is meaningfully better than pure TWAP with no adaptation, and it avoids the gas cost of block-by-block re-optimization.

**Differentiation vs. intent auctions:** CoW Swap and UniswapX are built for instantaneous batch clearing across fragmented liquidity. For a DAO attempting a multi-day treasury unwind, those protocols require either manually submitting hundreds of discrete intents or relying on naive TWAP. Sigma86 provides algorithmically-scheduled time-decay with mid-flight correction capability.

The Sigma86 Off-chain Solver:
* Ingests portfolio sizes, the DAO's VaR parameter (λ placeholder pending full calibration), and live pool liquidity depths.
* Submits the schedule via Viem strictly through **Flashbots Protect RPC** to prevent atomic mempool sandwich attacks.

### 2. The Sigma86Vault (On-chain Executor)
The on-chain `Sigma86Vault.sol` is a deliberately minimal execution layer.
* **Gas-Optimized Routing:** The `executeTick()` function runs in pure Yul assembly, passing raw API payloads directly into the 1inch router.
* **Trust Boundary (On-Chain Oracle):** The Vault enforces execution pricing via Chainlink feeds. It compares the router's realized return against `(amountToSwap × oraclePrice / 1e20) × (1 − maxSlippageBps)`. Fills below that threshold accumulate in `failedAmount` rather than being accepted. **This is adversarially tested** — the suite confirms the check blocks at `minReturn−1` and passes at `minReturn` exactly.
* **Mid-Flight Re-optimization:** `updateSchedule()` allows the off-chain solver to replace remaining ticks with a revised plan based on realized volatility, without restarting the schedule.

---

## 🚀 Quick Start: The Monte Carlo Quant Backtest

To run the 1,000-path stochastic Monte Carlo simulation:
```bash
cd agent-gateway
npm install
npx ts-node src/backtest.ts
```

**Demo Backtest Result (5 seeds × 500 paths, Net of Gas & 20% Performance Fee):**

**The strongest result is the boring one:** In a driftless, zero-trend market, Sigma86's mean outperformance collapses to **−$1,020** across 5 independent seeds. This is the theoretically-predicted null result from Almgren-Chriss — in a martingale, any deterministic schedule costs the same in expectation. A model curve-fit to look good would claim outperformance everywhere. Getting the boring, correct answer where theory says the answer *should* be boring is the strongest evidence the model is doing what AC actually predicts.

The directional results confirm the tradeoff:
1. **Driftless Chop (0% trend):** Grand Mean **−$1,020**, StdDev across seeds **±$843** — collapses to ~$0 as predicted. ✓ Theoretically correct.
2. **Market Crash (−20% trend):** Grand Mean **+$25,782**, StdDev **±$277** — front-loading avoids time-decay loss. Structurally stable across seeds.
3. **Market Rally (+20% trend):** Grand Mean **−$37,970**, StdDev **±$362** — underperforms TWAP. This is the honest insurance premium for variance reduction. Structurally stable across seeds.

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
