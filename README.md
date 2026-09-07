# Sigma86: Deterministic AMM Execution Solver

**An institutional-grade liquidation solver built for Constant Product Market Makers (CPMMs) and Flashbots.**

Unlike traditional intent-based auctions (CoW Swap, UniswapX, 1inch Fusion) where DAOs pay spread fees to third-party solvers to find liquidity, Sigma86 allows a treasury to **deterministically self-execute their own mathematically optimal, multi-day unwind schedule**.

Sigma86 adapts the traditional **Almgren-Chriss (2000) Optimal Execution** mathematical frontier to the unique mechanics of on-chain AMMs. 

---

## 📐 Mathematical Proof: Bounding CPMM Convexity for Almgren-Chriss
The original Almgren-Chriss (2000) paper derives optimal execution assuming a linear price impact coefficient $\eta$. 
To adapt this for a Constant Product Market Maker ($x \cdot y = k$), we analyze the effective execution price: $\frac{x + \Delta x}{y}$.

Taking the Taylor expansion of the price impact fractional term:
$$\frac{1}{x + \Delta x} = \frac{1}{x} - \frac{\Delta x}{x^2} + \frac{(\Delta x)^2}{x^3} - \mathcal{O}((\Delta x)^3)$$

For infinitesimal trades, the quadratic and higher-order terms vanish, leaving a linear limit-order-book equivalent where $\eta = \frac{1}{x}$. However, for massive treasury unwinds, these non-linear terms cause significant convexity error. 

**The Bounding Constraint:**
To ensure the Almgren-Chriss trajectory remains mathematically optimal on an AMM, the solver must dynamically bound the discrete slice size (tick size) $v_i$. The quadratic error term must remain below the DAO's accepted slippage tolerance $\epsilon$:
$$\frac{v_i^2}{x^3} < \epsilon \implies v_i < x \sqrt{\epsilon \cdot x}$$

The Sigma86 solver restricts execution block-sizes to satisfy this exact bound, ensuring the linear approximation of the CPMM curve holds true throughout the multi-day schedule. The stochastic risk parameter ($\sigma$) models the block-to-block volatility of the pool invariant caused by external traders.

---

## 🧠 The Architecture: Algorithmic Time-Decay vs Intent Auctions

We separated the heavy quantitative calculus off-chain (The Solver) from a simple, gas-efficient state-machine on-chain (The Executor).

### 1. The AMM-Adapted Solver (Off-chain Node.js)
**The Differentiation:** Protocols like CoW Swap and UniswapX are incredibly effective at finding best-price execution for *instantaneous batch clearing* across fragmented liquidity. However, for a DAO attempting a multi-day treasury unwind, they must either manually submit hundreds of discrete intents over time, or rely on naive TWAP order types. Sigma86 provides **dynamic algorithmic time-decay**. The DAO runs its own solver infrastructure to continuously calculate a mathematically optimal execution curve that dynamically adjusts to live pool liquidity and volatility, dispatching slices block-by-block.

The Sigma86 Off-chain Solver:
* Ingests portfolio sizes, the user's block-to-block risk aversion, and live pool liquidity depths.
* Calculates the AMM-adapted exponential/hyperbolic decay trajectory, bounding slice sizes to the CPMM convexity constraint.
* Submits the schedule via Viem strictly through **Flashbots Protect RPC** to prevent atomic mempool sandwich attacks.

### 2. The Sigma86Vault (On-chain Executor)
The on-chain `Sigma86Vault.sol` is a deliberately minimal execution layer.
* **Gas-Optimized Routing:** The `executeTick()` function runs in pure Yul assembly, passing raw API payloads directly into the 1inch router to minimize gas overhead, ensuring execution priority in Flashbots bundle auctions.
* **Chainlink Heartbeat:** The Vault natively implements `AutomationCompatibleInterface`. Chainlink Keepers poke the contract at precise intervals to execute the next tick in the schedule.
* **Trust Boundary (On-Chain Oracle):** The Vault physically enforces execution pricing. It queries the live Chainlink Price Feed and calculates the effective execution price of the 1inch payload. If the price breaches the DAO's `maxSlippageBps`, the Vault terminates the trade. **Note:** This stops the Vault from accepting a bad fill, but it does not prevent a malicious or compromised off-chain solver from griefing the execution (e.g., stalling, or intentionally executing at the worst allowable edge of the tolerance band).

---

## ⚠️ Known Limitations & Future Work
To ensure intellectual honesty, we acknowledge the following limitations in the current architecture:
1. **Statistical Pattern-Recognition MEV:** While Flashbots Protect hides individual transactions from atomic sandwich attacks, the resulting state changes on the AMM are public. A sophisticated counterparty observing the pool reserves drift over multiple hours could infer the schedule and trade ahead of the pattern.
2. **Oracle Deviation Manipulation:** The Trust Boundary relies on Chainlink feeds, which update based on heartbeat/deviation thresholds. An attacker could manufacture a transient price gap on a thin centralized exchange to trip the deviation band, freezing the Vault to force a worse execution window upon resumption.
3. **Solver Griefing / Liveness Risk:** While the on-chain oracle prevents bad fills, a compromised off-chain solver can still harm the DAO by refusing to submit schedules (stalling), or leaking the schedule to a colluding searcher before submission. 
4. **Keeper Liveness Risk:** If Chainlink Keepers fail, lag, or censor the execution, the multi-day schedule silently stalls. Future iterations will include a permissionless keep-alive function or a deadline-based Dutch auction fallback to guarantee liveness.

---

## 🚀 Quick Start: The Quant Terminal & Empirical Backtest

To run the local empirical backtest proving Sigma86's financial execution profiles:
```bash
cd agent-gateway
npm install
npx ts-node src/backtest.ts
```

**Demo Backtest Result (Net of Gas & Fees):**
We simulate a 50-hour unwind of 100,000 tokens across three distinct stochastic price paths:
1. **Market Crash (-20% trend):** Sigma86 dynamically front-loads the sell-off, avoiding catastrophic time-decay risk and netting **+$62,600** outperformance over TWAP.
2. **Market Rally (+20% trend):** Sigma86 underperforms TWAP. This represents the Almgren-Chriss "insurance premium" (lost upside) paid to secure liquidity early and reduce variance.
3. **High-Volatility Chop (0% trend):** Sigma86 underperforms slightly, strictly bounding downside risk at the cost of expected value.

*For a DAO treasury, eliminating downside volatility is vastly superior to gambling on upside price action. Sigma86 mathematically bounds the worst-case scenario.*

---

## 🏗️ Core Architectural Specs (Demo Day Context)
* **Chain Context:** Mainnet Ethereum (Flashbots Protect RPC is entirely mainnet-oriented. Testnet deployments are purely for contract verification, as MEV protection is meaningless on testnets).
* **Custody & Concurrency:** Sigma86 does *not* pool funds. It operates as a **single-unwind proxy deployment**. A DAO deploys a fresh Vault proxy per schedule, completely eliminating co-mingling risk and complex ERC-4626 accounting.
* **Cancellation Flow & Admin Key:** A DAO's existing **Gnosis Safe / Multisig** holds the Vault admin privileges. The multisig can call `abortSchedule()` at any point mid-execution, freezing the Vault and allowing the immediate withdrawal of remaining funds back to the treasury.
* **Business/Fee Model:** Sigma86 monetizes via an incentive-aligned **Performance Fee (20% of outperformance vs TWAP)**. If Sigma86 does not mathematically beat the TWAP baseline benchmark in realized USDC, the protocol takes 0 fees.

---
*Built for ETHOnline 2026*
