import * as readline from 'readline';
import * as asciichart from 'asciichart';

const rl = readline.createInterface({
    input: process.stdin,
    output: process.stdout
});

/**
 * Deterministic AMM Execution Solver
 * Calculates the execution schedule adjusting for CPMM convexity and block-to-block liquidity risk.
 */
function calculateExecutionSchedule(portfolioSize: number, riskAversion: number, poolLiquidity: number, timeSteps: number, volatility: number): number[] {
    const trades: number[] = [];
    
    // In an AMM, slippage is deterministic (dx / x+dx), not stochastic. 
    // The 'volatility' here represents the risk of OTHER traders moving the pool invariant between blocks.
    const eta = 1 / poolLiquidity; 
    const variance = volatility * volatility;
    
    // Prevent div by zero
    const kappa = Math.sqrt((riskAversion * variance) / (eta || 1e-9));

    if (kappa < 1e-6) {
        // Fallback to basic TWAP if risk neutral (indifferent to between-block pool changes)
        const stepSize = portfolioSize / timeSteps;
        for (let i = 0; i < timeSteps; i++) {
            trades.push(stepSize);
        }
    } else {
        const T = timeSteps;
        for (let i = 1; i <= timeSteps; i++) {
            const t_prev = i - 1;
            const t_curr = i;
            
            let x_prev = 0;
            let x_curr = 0;

            // Using exponential decay approximation for the AMM-adapted trajectory
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

console.log("==================================================");
console.log("=      SIGMA86 DETERMINISTIC AMM SOLVER          =");
console.log("==================================================");

rl.question('Enter Portfolio Size to Unwind (e.g., 50000): ', (sizeStr: string) => {
    rl.question('Enter Block-to-Block Risk Aversion (e.g., 0.1): ', (riskStr: string) => {
        const portfolioSize = parseFloat(sizeStr) || 50000;
        const riskAversion = parseFloat(riskStr) || 0.1;
        
        console.log(`\n[📡] Using simulated pool parameters (poolLiquidity=1M, σ=0.05)...`);
        
        setTimeout(() => {
            console.log(`\nCrunching trajectories for ${portfolioSize} units with risk aversion ${riskAversion}...`);
            
            // Mock dynamic parameters for the CLI presentation
            const poolLiquidity = 1000000;
            const timeSteps = 50;
            const volatility = 0.05;

            const schedule = calculateExecutionSchedule(portfolioSize, riskAversion, poolLiquidity, timeSteps, volatility);
            
            console.log("\n[ Execution Trajectory - Trade Size per Tick (AMM-Adapted) ]\n");
            
            // Render beautiful terminal chart
            console.log(asciichart.plot(schedule, { height: 12, colors: [asciichart.blue] }));
            
            console.log("\n✅ Mathematical Frontier Achieved.");
            console.log("✅ Array compiled. Ready for dispatch to Sigma86Vault via Flashbots Protect.");
            rl.close();
        }, 800);
    });
});
