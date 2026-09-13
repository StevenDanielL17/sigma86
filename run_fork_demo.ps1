$ErrorActionPreference = "Stop"

Write-Host "[*] Initializing Sigma86 Execution Environment..." -ForegroundColor Gray
$MAINNET_RPC = "https://ethereum.publicnode.com"
$ANVIL_URL   = "http://127.0.0.1:8545"

Write-Host "[*] Bootstrapping Mainnet Fork (Anvil)..." -ForegroundColor Gray
$anvil = Start-Process -FilePath "anvil" -ArgumentList "--fork-url", $MAINNET_RPC, "--chain-id", "1", "--silent" -NoNewWindow -PassThru
Start-Sleep -Seconds 4

if ($anvil.HasExited) {
    Write-Host "[!] FATAL: Anvil fork failed to start." -ForegroundColor Red
    exit 1
}

Write-Host "[*] Executing Almgren-Chriss Quantitative Backtest..." -ForegroundColor Gray
Set-Location agent-gateway
npm run backtest 2>&1 | Select-String "REGIME|Outperformance|Standard Deviation|Information Ratio|PASS|FAIL|λ|Lambda|TWAP|Sigma86"
Set-Location ..

Write-Host "[*] Broadcasting Vault Transaction (Uniswap V3 Mainnet Route)..." -ForegroundColor Gray
Set-Location contracts
forge script script/ForkDemo.s.sol --rpc-url $ANVIL_URL --broadcast -vvvv 2>&1
Set-Location ..

Write-Host "[*] Tearing down environment..." -ForegroundColor Gray
Stop-Process -Id $anvil.Id -Force -ErrorAction SilentlyContinue

Write-Host "[+] Sigma86 execution suite completed successfully." -ForegroundColor Green
