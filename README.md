# Sigma86: Deterministic AMM Execution Solver

**An institutional-grade liquidation solver built for Constant Product Market Makers (CPMMs) and Flashbots.**

Unlike traditional intent-based auctions (CoW Swap, UniswapX, 1inch Fusion) where DAOs pay spread fees to third-party solvers to find liquidity, Sigma86 allows a treasury to **deterministically self-execute their own mathematically optimal, multi-day unwind schedule**.

Sigma86 adapts the traditional **Almgren-Chriss (2000) Optimal Execution** mathematical frontier to the unique mechanics of on-chain AMMs. 

---

## 📐 Mathematical Proof: AMM Convexity vs. Almgren-Chriss
The original Almgren-Chriss (2000) paper assumes stochastic price impact under Brownian motion in a continuous limit-order-book market, where execution cost $E[C]$ is derived from a linear price impact coefficient $\eta$. 

Critics often argue that AMM slippage is not stochastic, but deterministic. However, our adaptation mathematically proves that for bounded block-to-block trades, the CPMM curve directly translates into the Almgren-Chriss framework:

In a Constant Product Market Maker ($x \cdot y = k$), the effective execution price for swapping $\Delta x$ tokens is derived from the curve's convexity:
$$\Delta y = \frac{y \cdot \Delta x}{x + \Delta x}$$

The price impact fraction is directly proportional to $\frac{\Delta x}{x + \Delta x}$. By taking the **first-order Taylor expansion** of this function for trades where $\Delta x \ll x$ (which is the exact premise of slicing a large order into small ticks), the convexity flattens:
$$\frac{1}{x + \Delta x} \approx \frac{1}{x} - \frac{\Delta x}{x^2}$$

This proves that for discrete, tick-based execution schedules, the AMM behaves **identically to a linear limit order book** where the linear price impact coefficient $\eta$ is exactly $\frac{1}{x}$ (the inverse of the pool's base liquidity). 

The "stochastic risk" parameter ($\sigma$) in our solver does not model the deterministic AMM curve—it models the **block-to-block volatility of other traders** moving the pool's invariant between our execution ticks. Therefore, the Almgren-Chriss exponential decay derivation mathematically holds true for on-chain AMMs.

---

## 🧠 The Architecture: TEE Secured Solver vs. Intent Auctions

We separated the heavy quantitative calculus off-chain (The Solver) from a simple, gas-efficient state-machine on-chain (The Executor).

### 1. The AMM-Adapted Solver (Off-chain TEE / SGX)
**The Differentiation:** Platforms like CoW Swap and UniswapX rely on intent auctions, which suffer from **solver oligopolies and collusion**, allowing third-party market makers to extract massive spread fees from DAO treasuries. Sigma86 runs a verifiable, open-source execution solver inside a **Trusted Execution Environment (TEE / Intel SGX)**. The DAO trusts the mathematically optimal code, entirely removing third-party rent extraction.

The Sigma86 Off-chain Solver:
* Ingests portfolio sizes, the user's block-to-block risk aversion, and live pool liquidity depths.
* Calculates the AMM-adapted exponential/hyperbolic decay trajectory.
* Submits the schedule via Viem strictly through **Flashbots Protect RPC** to prevent atomic mempool sandwich attacks.

### 2. The Sigma86Vault (On-chain Executor)
The on-chain `Sigma86Vault.sol` is a deliberately minimal execution layer.
* **Gas-Optimized Routing:** The `executeTick()` function runs in pure Yul assembly, passing raw API payloads directly into the 1inch router to minimize gas overhead, ensuring execution priority in Flashbots bundle auctions.
* **Chainlink Heartbeat:** The Vault natively implements `AutomationCompatibleInterface`. Chainlink Keepers poke the contract at precise intervals to execute the next tick in the schedule.
* **Trust Boundary (On-Chain Oracle):** The Vault physically enforces execution pricing. It queries the live Chainlink Price Feed and calculates the effective execution price of the 1inch payload. If the price breaches the DAO's `maxSlippageBps`, the Vault terminates the trade, mathematically preventing a compromised or stale off-chain schedule from draining the treasury.

---

## ⚠️ Known Limitations & Future Work
To ensure intellectual honesty, we acknowledge the following limitations in the current architecture:
1. **Statistical Pattern-Recognition MEV:** While Flashbots Protect hides individual transactions from atomic sandwich attacks, the resulting state changes on the AMM are public. A sophisticated counterparty observing the pool reserves drift over multiple hours could infer the schedule and trade ahead of the pattern.
2. **Oracle Deviation Manipulation:** The Trust Boundary relies on Chainlink feeds, which update based on heartbeat/deviation thresholds. An attacker could manufacture a transient price gap on a thin centralized exchange to trip the deviation band, freezing the Vault to force a worse execution window upon resumption.
3. **Keeper Liveness Risk:** If Chainlink Keepers fail, lag, or censor the execution, the multi-day schedule silently stalls. Future iterations will include a permissionless keep-alive function or a deadline-based Dutch auction fallback to guarantee liveness.

---

## 🚀 Quick Start: The Quant Terminal

Run the CLI Quant Terminal to generate an AMM-adapted execution curve locally:

```bash
cd agent-gateway
npm install
npx ts-node src/cli.ts
```

---
*Built for ETHOnline 2026*
