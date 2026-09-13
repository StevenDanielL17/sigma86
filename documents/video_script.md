# Sigma86 — 3-Minute Winning Demo Video Script
**Event:** ETHOnline 2026  
**Target Duration:** Exactly 3 minutes (180 seconds)  
**Format:** Screen recording + voiceover with live terminal, Foundry tests, and visual charts.

---

## Storyboard Timeline & Cues

```
[0:00 - 0:40] Part 1: The Trillion-Dollar DAO Problem (Linear TWAP vs AMM Convexity)
[0:40 - 1:20] Part 2: The Quantitative Breakthrough (Closed-Form VaR -> λ Calibration)
[1:20 - 2:10] Part 3: On-Chain Trust Boundary & Yul Core (35 Passing Foundry Tests)
[2:10 - 2:45] Part 4: Empirical Proof (1,000-Path Monte Carlo Verification)
[2:45 - 3:00] Part 5: The Bazantic Autonomous Agent Copilot & Closing
```

---

### [0:00 – 0:40] Part 1: The Trillion-Dollar Problem
**Visual Cue:** Screen shows Uniswap / CoW Swap / LlamaNodes charts of large DAO treasury unwinds experiencing massive price impact. Cut to title slide: **"Sigma86: Deterministic AMM Execution Solver"**.

**Speaker (Clear, authoritative, professional tone):**
> "DAOs manage over twenty billion dollars in native token treasuries. But when a DAO needs to liquidate five million dollars of tokens over 48 hours to fund operations, they face an impossible choice:
> 
> If they dump it in blocks, automated MEV sandwich bots drain up to fifteen percent of their capital.
> 
> If they use traditional linear TWAP, they bleed continuously to AMM pool convexity ($dx / (x + dx)$) and external drift.
> 
> Intent-based auctions like CoW Swap and UniswapX are brilliant for instant batch clearing, but they offer zero automated multi-day time-decay scheduling.
> 
> Enter **Sigma86**: an institutional-grade liquidation solver that adapts Almgren-Chriss optimal execution model specifically to the mathematics of decentralized AMMs."

---

### [0:40 – 1:20] Part 2: The Quantitative Breakthrough
**Visual Cue:** Switch to terminal. Run `node dist/cli.js`. The beautiful ASCIIChart appears, showing the smooth hyperbolic curve decaying from 3.6% down to 1.2% per tick. Cut to the LaTeX equation on the README.

**Speaker:**
> "In traditional quantitative finance, optimal execution trades off expected market impact against volatility variance risk.
> 
> But until now, crypto projects either guessed arbitrary risk constants or used naive linear schedules.
> 
> Sigma86 eliminates arbitrary constants. In `QuantEngine.ts`, we derived the closed-form mapping from a DAO's actual Value-at-Risk budget into the Almgren-Chriss risk aversion parameter $\lambda$:
> 
> $$\lambda = \frac{2 \ln(1 / \alpha) \cdot \text{VaR}^2}{W_0^2 \cdot \sigma^2 \cdot T}$$
> 
> The DAO simply states: *'We have a fifty-thousand-dollar maximum loss budget at a ninety-five percent confidence interval.'* 
> 
> Our solver mathematically determines the exact Euler-Lagrange trajectory—front-loading execution just enough to outrun adverse volatility without overwhelming the AMM's reserve depth."

---

### [1:20 – 2:10] Part 3: On-Chain Trust Boundary & Yul Execution Core
**Visual Cue:** Open terminal inside `contracts/`. Run `forge test -vvv`. The test suite flies by, showing **35 passed, 0 failed** across 4 test suites. Highlight `Sigma86AdversarialTest` and `Sigma86InstitutionalTest`.

**Speaker:**
> "An off-chain brain is useless if the smart contract can be manipulated or drained.
> 
> In `Sigma86Vault.sol`, we built an unassailable on-chain trust boundary. Swaps are executed via raw Yul assembly directly into the Uniswap V3 Mainnet Router, zeroing EVM scratch space to guarantee zero memory expansion overhead. 
> 
> After every tick, the Vault cross-checks the realized execution price against live Chainlink Oracles. Because we set `amountOutMinimum: 0` at the DEX routing layer, we rely entirely on this atomic post-trade oracle check to catch bad fills. If slippage breaches the DAO's threshold, or if the oracle feed is stale, the transaction intentionally reverts entirely, providing absolute protection against sandwich attacks.
> 
> Third, custody is never pooled. The DAO's dedicated treasury wallet retains exclusive ownership, with timelocked emergency recovery functions.
> 
> Thirty-five Foundry tests pass with zero compiler warnings, proving adversarial resistance against oracle manipulation, reentrancy, and front-running."

---

### [2:10 – 2:45] Part 4: Empirical Proof (1,000-Path Monte Carlo)
**Visual Cue:** Switch to terminal inside `agent-gateway/`. Run `npm run backtest`. The benchmark output streams live, showing the tables for Market Crash, Market Rally, and Driftless Martingale.

**Speaker:**
> "To prove Sigma86 isn't curve-fitted to a cherry-picked scenario, we built a 1,000-path stochastic Monte Carlo simulator across five independent random seeds:
> 
> In a severe market crash (-20% trend), Sigma86 outperforms vanilla TWAP by over **$12,321** on a one-million-dollar unwind, and reduces Maximum Adverse Excursion (MAE) by **9.09%**.
> 
> In a market rally, it predictably underperforms TWAP by **-$18,003**, precisely quantifying the honest 'insurance premium' paid to eliminate catastrophic downside tail risk.
> 
> And most importantly: in a driftless martingale (0% trend), outperformance collapses to **-$737 (-0.07%)**—the exact penalty predicted by CPMM convexity for front-loading volume, confirming the theoretical null hypothesis without spurious directional bias."

---

### [2:45 – 3:00] Part 5: The Bazantic Autonomous Agent Copilot
**Visual Cue:** Run `npm run test:recipe`. The terminal displays the 4-step Bazantic Recipe: polling Chainlink, solving with Sigma86, fetching Uniswap V3 route, and verifying the on-chain trust boundary for Flashbots dispatch. Show the `bazantic.config.json` MPP gateway.

**Speaker:**
> "Finally, we exposed this solver as a Model Context Protocol server integrated into the **Bazantic Platform**.
> 
> Our **Institutional Treasury Copilot Recipe** autonomous chains Chainlink Data Feeds, Sigma86 Quant Math, Uniswap V3 Routing, and Flashbots private mempool dispatch into a single click. **In this demo, Bazantic's agent plans the schedule and we simulate the end-to-end execution against a live Mainnet fork using Foundry.**
> 
> Institutional mathematics. On-chain trust boundaries. Autonomous end-to-end execution.
> 
> This is **Sigma86**."
