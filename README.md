# Sigma86 

**An institutional-grade, hyper-latency liquidation vault built on 1inch SwapVM and Chainlink.**

Sigma86 executes massive token unwinds using the **Almgren-Chriss (2000) Optimal Execution** mathematical frontier. It minimizes market impact (slippage) and completely eliminates MEV front-running by replacing predictable linear TWAP with volatility-adjusted hyperbolic execution curves.

---

## 🧠 The Architecture (Brain vs. Brawn)

We separated the heavy quantitative calculus from the on-chain execution to bypass EVM gas limitations.

### 1. The Brain (Bazantic Agent / Node.js)
The off-chain Bazantic MCP Agent acts as the Quant Sandbox. 
* It ingests live portfolio sizes, risk aversion parameters, and real-time Chainlink volatility data.
* It calculates the exact **hyperbolic sine (`sinh`) trajectory** adjusted for CPMM convex slippage (`dx / (x+dx)`).
* The resulting schedule array is dispatched directly to the Vault via MEV-Share / Flashbots RPC using a hyper-optimized Viem pipeline (`deploySchedule.ts`).

### 2. The Brawn (SwapVM + Chainlink Automation)
The on-chain `Sigma86Vault.sol` is a ruthless state machine.
* **Hyper-Latency Yul:** We ripped out the standard Solidity ABI encoder. The `executeTick()` function runs in pure Yul assembly, passing raw API payloads directly into the 1inch router for absolute minimum gas and latency.
* **Chainlink Heartbeat:** The Vault natively implements `AutomationCompatibleInterface`. Chainlink Keepers poke the contract at precise intervals to execute the next tick in the schedule.
* **State Reconciliation:** If a tick reverts due to temporary liquidity droughts, the Vault catches the failure natively without reverting the transaction, accumulating the un-swapped amount for the off-chain Agent to recalculate.

---

## 🚀 Quick Start: The Quant Terminal

Want to see the math in action? Run the CLI Quant Terminal to generate an Almgren-Chriss execution curve in your terminal.

```bash
cd agent-gateway
npm install
npx ts-node src/cli.ts
```

The terminal will prompt you for a portfolio size and risk aversion parameter, crunch the calculus, and plot an ASCII visual representation of the trade execution schedule.

---

## 📁 Repository Structure

*   `/contracts/` - Foundry workspace containing `Sigma86Vault.sol` (Pure Yul execution logic) and the test suite.
*   `/agent-gateway/` - Node.js workspace containing the Bazantic MCP Server, the `cli.ts` Quant Terminal, and the `deploySchedule.ts` Viem pipeline.
*   `/documents/` - Red-Team architectural teardowns and quant math theory.

---
*Built for ETHOnline 2026*
