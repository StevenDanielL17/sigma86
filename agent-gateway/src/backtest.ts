import * as asciichart from 'asciichart';

// Simple CPMM Simulator with external price drift
class AMMSimulator {
    public k: number;
    
    constructor(public x: number, public y: number) {
        this.k = x * y;
    }

    // Apply external market drift to the pool (arbitrageurs sync the pool to Binance/Oracle price)
    public applyExternalPriceDrop(percentageDrop: number) {
        const currentPrice = this.y / this.x;
        const newPrice = currentPrice * (1 - percentageDrop);
        
        // x * y = k  --> y = k / x
        // price = y / x --> price = k / x^2 --> x^2 = k / price --> x = sqrt(k / price)
        this.x = Math.sqrt(this.k / newPrice);
        this.y = this.k / this.x;
    }

    public swapTokensForUSDC(dx: number): number {
        // Path independence applies to the curve, but we execute against a shifting curve
        const dy = this.y - (this.k / (this.x + dx));
        this.x += dx;
        this.y -= dy;
        return dy; // USDC realized
    }
}

function calculateAlmgrenChriss(portfolioSize: number, riskAversion: number, poolLiquidity: number, timeSteps: number, volatility: number): number[] {
    const trades: number[] = [];
    const eta = 1 / poolLiquidity; 
    const variance = volatility * volatility;
    const kappa = Math.sqrt((riskAversion * variance) / (eta || 1e-9));

    if (kappa < 1e-6) {
        const stepSize = portfolioSize / timeSteps;
        for (let i = 0; i < timeSteps; i++) { trades.push(stepSize); }
    } else {
        const T = timeSteps;
        for (let i = 1; i <= timeSteps; i++) {
            const t_prev = i - 1;
            const t_curr = i;
            let x_prev = 0, x_curr = 0;
            if (kappa * T > 500) {
                x_prev = portfolioSize * Math.exp(-kappa * t_prev);
                x_curr = portfolioSize * Math.exp(-kappa * t_curr);
            } else {
                x_prev = portfolioSize * (Math.sinh(kappa * (T - t_prev)) / Math.sinh(kappa * T));
                x_curr = portfolioSize * (Math.sinh(kappa * (T - t_curr)) / Math.sinh(kappa * T));
            }
            trades.push(x_prev - x_curr);
        }
    }
    return trades;
}

async function runBacktest() {
    console.log("==================================================");
    console.log("=    SIGMA86 EMPIRICAL BACKTEST (TWAP vs AC)     =");
    console.log("==================================================\n");

    const totalTokens = 100000;
    const ticks = 50;
    
    console.log("Scenario: A DAO needs to unwind 100,000 tokens over 50 hours.");
    console.log("Market Condition: The broader market is crashing, token price drops 20% over the window.\n");

    // 1. Generate Schedules
    const twapSchedule = calculateAlmgrenChriss(totalTokens, 1e-9, 1000000, ticks, 0.05); // Risk neutral = TWAP
    const acSchedule = calculateAlmgrenChriss(totalTokens, 0.05, 1000000, ticks, 0.5);   // High risk aversion = Front-loaded

    // 2. Execute TWAP Simulation
    const twapSim = new AMMSimulator(1000000, 10000000); // 1M tokens, $10M USDC ($10 price)
    let twapRealized = 0;
    for (let i = 0; i < ticks; i++) {
        twapRealized += twapSim.swapTokensForUSDC(twapSchedule[i] || 0);
        twapSim.applyExternalPriceDrop(0.004); // 0.4% drop per tick (~20% total)
    }

    // 3. Execute Sigma86 Simulation
    const acSim = new AMMSimulator(1000000, 10000000); 
    let acRealized = 0;
    for (let i = 0; i < ticks; i++) {
        acRealized += acSim.swapTokensForUSDC(acSchedule[i] || 0);
        acSim.applyExternalPriceDrop(0.004); // Same market conditions
    }

    console.log(`[RESULTS]`);
    console.log(`Vanilla TWAP Realized:     $${twapRealized.toFixed(2)}`);
    console.log(`Sigma86 (AC) Realized:     $${acRealized.toFixed(2)}`);
    console.log(`--------------------------------------------------`);
    const difference = acRealized - twapRealized;
    console.log(`Sigma86 Outperformance:    +$${difference.toFixed(2)} (${((difference / twapRealized) * 100).toFixed(2)}% better)\n`);

    console.log("Explanation:");
    console.log("Because CPMM slippage is path-independent, splitting trades mathematically yields the exact same realized value IF the pool is isolated.");
    console.log("However, in the real world, arbitrageurs sync the pool to external market drops. Sigma86's risk-averse trajectory front-loads the sell-off, securing liquidity BEFORE the price crashes, mathematically outperforming TWAP by avoiding time-decay risk.");
}

runBacktest();
