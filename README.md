# Sigma86: Deterministic AMM Execution Solver

**An institutional-grade liquidation solver built for Constant Product Market Makers (CPMMs) and Flashbots.**

Unlike traditional intent-based auctions (CoW Swap, UniswapX, 1inch Fusion) where DAOs pay spread fees to third-party solvers to find liquidity, Sigma86 allows a treasury to **deterministically self-execute their own mathematically optimal, multi-day unwind schedule**.

Sigma86 adapts the traditional **Almgren-Chriss (2000) Optimal Execution** mathematical frontier to the unique mechanics of on-chain AMMs. 

---

## 🧠 The Architecture (Solver vs. Executor)

We separated the heavy quantitative calculus off-chain (The Solver) from a simple, gas-efficient state-machine on-chain (The Executor).

### 1. The AMM-Adapted Solver (Off-chain Node.js)
Traditional Almgren-Chriss assumes stochastic price impact in a continuous Limit Order Book. However, an AMM's slippage is a deterministic function of trade size ($dx / (x+dx)$). The only "stochastic risk" is what *other* traders do to the pool invariant between your trades (block-to-block risk). 

The Sigma86 Off-chain Solver:
* Ingests portfolio sizes, the user's block-to-block risk aversion, and live pool liquidity depths.
* Calculates an AMM-adapted exponential/hyperbolic decay trajectory. 
* Outputs a deterministic array of exact trade sizes per block/tick.
* Submits the schedule via Viem strictly through **Flashbots Protect RPC** to completely shield the initial scheduling transaction from MEV front-runners.

### 2. The Sigma86Vault (On-chain Executor)
The on-chain `Sigma86Vault.sol` is a deliberately minimal execution layer.
* **Gas-Optimized Routing:** The `executeTick()` function runs in pure Yul assembly, passing raw API payloads directly into the 1inch router to minimize gas overhead (acknowledging that on-chain latency is bounded by 12s block times, making gas efficiency the true optimization metric).
* **Chainlink Heartbeat:** The Vault natively implements `AutomationCompatibleInterface`. Chainlink Keepers poke the contract at precise intervals to execute the next tick in the schedule.
* **State Reconciliation:** If a tick reverts due to temporary liquidity droughts, the Vault catches the failure natively without reverting the transaction, accumulating the un-swapped amount for the off-chain solver to reconcile.

> **Security & Trust Boundary:** How do we prevent a manipulated off-chain schedule from draining the vault at bad prices? Sigma86 assumes the Vault Owner (the DAO/Treasury) must cryptographically sign the generated schedule before submission. Additionally, the Vault's integration with 1inch enforces strict `minReturnAmount` checks within the router calldata to guarantee a global price floor.

---

## 🚀 Quick Start: The Quant Terminal

Run the CLI Quant Terminal to generate an AMM-adapted execution curve locally:

```bash
cd agent-gateway
npm install
npx ts-node src/cli.ts
```

The terminal will prompt you for a portfolio size and block-to-block risk aversion parameter, crunch the calculus, and plot an ASCII visual representation of the trade execution schedule.

---

## 📁 Repository Structure

*   `/contracts/` - Foundry workspace containing `Sigma86Vault.sol` (Gas-optimized execution logic) and the test suite.
*   `/agent-gateway/` - Node.js workspace containing the MCP Server boilerplate, the `cli.ts` Quant Terminal, and the `deploySchedule.ts` Flashbots pipeline.

---
*Built for ETHOnline 2026*
