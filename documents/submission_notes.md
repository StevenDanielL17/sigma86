# SIGMA86 - Submission Disclosure Notes

## 1. Execution Simulation vs. Live Pipeline
The core smart contracts (Sigma86Vault) are deployed live to Sepolia (0xc236...). However, the end-to-end execution pipeline demonstrated in the video is executed using Foundry against a live **Mainnet fork**.

**Architecture Notes (Uniswap V3):**
- The deployed production contract `Sigma86Vault.sol` routes swaps directly through the Uniswap V3 Mainnet Router via raw Yul assembly to maximize execution priority.
- A minor bug fix (`approveRouter()`) was added locally to the Vault to allow it to grant ERC20 allowance to the UniV3 router. This fix is in the local codebase but absent from the initial Sepolia deployment.
- The `amountOutMinimum: 0` parameter in the UniV3 payload is intentional; the Vault relies entirely on the post-trade Chainlink Oracle atomic revert to enforce slippage and sandwich-attack protection.

## 2. Git History Rewriting
The repository history was rewritten using git filter-branch prior to submission.
- **Reason:** A stale commit message referenced "SwapVM", a product name from an early architecture draft that was completely excised in favor of Uniswap V3.
- **Impact:** No code was modified in the rewrite, and timestamps were preserved, but commit hashes downstream of cd1d9fa were altered, resulting in a force-push to the remote origin.

## 3. Forfeiture of Sponsor Tracks
- **Bazantic:** We formally forfeit the Bazantic prize track. The agent gateway was implemented locally to test the MCP server schema (openapi.json), but we do not have a live Bazantic account or a live Recipe executing on their dashboard. The URL in our spec is explicitly mocked to https://httpbin.org/anything.
- **Chainlink:** We are not pursuing the Chainlink track. Oracles are used strictly as infrastructure.
- **1inch:** We are not pursuing the 1inch track.
