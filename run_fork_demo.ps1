#!/usr/bin/env pwsh
# run_fork_demo.ps1
# 
# SIGMA86 — MAINNET FORK EXECUTION DEMO
# Runs a complete end-to-end execution of the Sigma86Vault against a local
# fork of Ethereum mainnet. Uses real 1inch v6 router + real Chainlink oracle.
#
# HOW TO RUN:
#   1. Open a terminal in D:\Dansprojects\sigma86
#   2. Run:  .\run_fork_demo.ps1

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

Write-Host ""
Write-Host "==========================================================" -ForegroundColor Cyan
Write-Host "  SIGMA86 — MAINNET FORK EXECUTION DEMO" -ForegroundColor Cyan  
Write-Host "==========================================================" -ForegroundColor Cyan
Write-Host "NOTE: This demo runs against a local fork of Ethereum"
Write-Host "mainnet via Anvil. Real 1inch v6 router. Real Chainlink"
Write-Host "oracle. No live capital at risk."
Write-Host ""
Write-Host "Sepolia deployment: https://sepolia.etherscan.io/address/0xc23696731758a4510e908416d2862633147eba7c"
Write-Host ""

$MAINNET_RPC = "https://ethereum.publicnode.com"
$ANVIL_URL   = "http://127.0.0.1:8545"

# Step 1: Start Anvil fork in background
Write-Host "[1/3] Starting Anvil mainnet fork..." -ForegroundColor Yellow
$anvil = Start-Process -FilePath "anvil" `
    -ArgumentList "--fork-url", $MAINNET_RPC, "--chain-id", "1", "--silent" `
    -NoNewWindow -PassThru
Start-Sleep -Seconds 4

if ($anvil.HasExited) {
    Write-Host "ERROR: Anvil failed to start. Is foundry installed?" -ForegroundColor Red
    exit 1
}
Write-Host "    Anvil fork running (PID: $($anvil.Id)) at $ANVIL_URL" -ForegroundColor Green

# Step 2: Run the backtest to confirm math (shown before the onchain demo)
Write-Host ""
Write-Host "[2/3] Running backtest to show the AC schedule math..." -ForegroundColor Yellow
Set-Location agent-gateway
npm run backtest 2>&1 | Select-String "REGIME|Outperformance|Standard Deviation|Information Ratio|PASS|FAIL|λ|Lambda|TWAP|Sigma86"
Set-Location ..
Write-Host "" 

# Step 3: Execute the vault fork demo
Write-Host "[3/3] Executing vault against mainnet fork..." -ForegroundColor Yellow
Write-Host "    Vault -> 1inch v6 router -> WETH->USDC swap -> Chainlink trust boundary"
Write-Host ""

Set-Location contracts
forge script script/ForkDemo.s.sol `
    --rpc-url $ANVIL_URL `
    --broadcast `
    -vvvv 2>&1

Set-Location ..

# Cleanup
Write-Host ""
Write-Host "[DONE] Stopping Anvil..." -ForegroundColor Yellow
Stop-Process -Id $anvil.Id -Force -ErrorAction SilentlyContinue
Write-Host "==========================================================" -ForegroundColor Cyan
Write-Host "  DEMO COMPLETE" -ForegroundColor Cyan
Write-Host "==========================================================" -ForegroundColor Cyan
