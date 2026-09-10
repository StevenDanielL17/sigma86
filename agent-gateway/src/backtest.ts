/**
 * Sigma86 Institutional Monte Carlo Backtest
 * Quantitative Execution Solver Benchmark
 * Built to Jane Street & Goldman Sachs quantitative research standards.
 *
 * Simulates 1,000 stochastic paths across three market regimes:
 * 1. Market Crash (-20% trend)
 * 2. Market Rally (+20% trend)
 * 3. Driftless Martingale (0% drift, high variance chop)
 *
 * Evaluates:
 * - Mean Net Outperformance vs. Vanilla TWAP
 * - Standard Deviation of Return
 * - Information Ratio (IR = Mean Delta / StdDev Delta)
 * - Maximum Adverse Excursion (MAE / Max Intraday Drawdown)
 * - VaR / CVaR Calibration Integrity
 */

import {
  calibrateLambdaFromVaR,
  computeOptimalTrajectory,
  AMMInvariantTracker,
} from "./QuantEngine.js";

// Deterministic RNG (Multiply-With-Carry) for reproducible backtests
let m_w = 123456789;
let m_z = 987654321;
const mask = 0xffffffff;

let setSeed = function(seed: number) {
  m_w = (123456789 + seed) & mask;
  m_z = (987654321 - seed) & mask;
};

let seededRandom = function() {
  m_z = (36969 * (m_z & 65535) + (m_z >> 16)) & mask;
  m_w = (18000 * (m_w & 65535) + (m_w >> 16)) & mask;
  let result = ((m_z << 16) + (m_w & 65535)) >>> 0;
  return result / 4294967296;
};

interface PathResult {
  twapRealized: number;
  acRealized: number;
  fee: number;
  delta: number;
  maeTwap: number;
  maeAc: number;
}

interface RegimeStatistics {
  name: string;
  totalPaths: number;
  grandMeanDelta: number;
  stdDevDelta: number;
  informationRatio: number;
  twapMeanRealized: number;
  acMeanRealized: number;
  avgMaeTwap: number;
  avgMaeAc: number;
  maeImprovementPct: number;
  seedMeanStdev: number;
}

/**
 * Runs a single simulation path comparing TWAP vs. VaR-Calibrated Almgren-Chriss
 */
function runSinglePath(
  twapSchedule: number[],
  acSchedule: number[],
  priceDriftPerTick: number,
  chopVolatility: number,
  ticks: number,
  gasCostPerTick: number,
  initialSpotPrice: number,
  initialPortfolioTokens: number
): PathResult {
  // Initialize two identical AMM pools ($10 spot price: 1,000,000 tokens, 10,000,000 USDC)
  const twapAMM = new AMMInvariantTracker(1000000, 10000000);
  const acAMM = new AMMInvariantTracker(1000000, 10000000);

  const initialPortfolioUSD = initialPortfolioTokens * initialSpotPrice;

  let twapRealizedCash = 0;
  let acRealizedCash = 0;

  let twapInventory = initialPortfolioTokens;
  let acInventory = initialPortfolioTokens;

  let twapWorstDrawdown = 0;
  let acWorstDrawdown = 0;

  for (let i = 0; i < ticks; i++) {
    // Gaussian Brownian motion increment: drift + N(0, chopVolatility^2) per tick.
    // Box-Muller transform: produces a standard normal variate Z from two uniform samples.
    const u1 = seededRandom();
    const u2 = seededRandom();
    const gaussian = Math.sqrt(-2 * Math.log(Math.max(u1, 1e-15))) * Math.cos(2 * Math.PI * u2);
    const randomShock = gaussian * chopVolatility;
    const tickDrift = priceDriftPerTick + randomShock;

    // 1. Execute TWAP slice
    const twapSlice = twapSchedule[i] ?? 0;
    if (twapSlice > 0) {
      const swapRes = twapAMM.swapTokensForQuote(twapSlice);
      twapRealizedCash += swapRes.quoteOut - gasCostPerTick;
      twapInventory -= twapSlice;
    }

    // Apply external market drift to TWAP pool
    twapAMM.applyExternalPriceChange(tickDrift);

    // 2. Execute Almgren-Chriss slice
    const acSlice = acSchedule[i] ?? 0;
    if (acSlice > 0) {
      const swapRes = acAMM.swapTokensForQuote(acSlice);
      acRealizedCash += swapRes.quoteOut - gasCostPerTick;
      acInventory -= acSlice;
    }

    // Apply external market drift to AC pool
    acAMM.applyExternalPriceChange(tickDrift);

    // 3. Track Maximum Adverse Excursion (MAE)
    // Mark-to-market portfolio value = realized cash + remaining inventory * current spot
    const twapCurrentM2M = twapRealizedCash + (twapInventory * twapAMM.getSpotPrice());
    const twapDrawdown = (initialPortfolioUSD - twapCurrentM2M) / initialPortfolioUSD;
    if (twapDrawdown > twapWorstDrawdown) twapWorstDrawdown = twapDrawdown;

    const acCurrentM2M = acRealizedCash + (acInventory * acAMM.getSpotPrice());
    const acDrawdown = (initialPortfolioUSD - acCurrentM2M) / initialPortfolioUSD;
    if (acDrawdown > acWorstDrawdown) acWorstDrawdown = acDrawdown;
  }

  // 20% performance fee on positive outperformance vs TWAP
  let fee = 0;
  let netAcRealized = acRealizedCash;
  if (netAcRealized > twapRealizedCash) {
    fee = (netAcRealized - twapRealizedCash) * 0.20;
    netAcRealized -= fee;
  }

  const delta = netAcRealized - twapRealizedCash;

  return {
    twapRealized: twapRealizedCash,
    acRealized: netAcRealized,
    fee,
    delta,
    maeTwap: twapWorstDrawdown,
    maeAc: acWorstDrawdown,
  };
}

/**
 * Runs multi-seed Monte Carlo batch for a given market regime
 */
function runMonteCarloRegime(
  name: string,
  driftPerTick: number,
  volPerTick: number,
  seeds: number,
  pathsPerSeed: number,
  twapSchedule: number[],
  acSchedule: number[],
  ticks: number,
  gasCost: number,
  initialSpotPrice: number,
  totalTokens: number
): RegimeStatistics {
  // Set seed based on regime name to ensure deterministic but varied sequences per regime
  setSeed(name.charCodeAt(0) + name.length);

  const seedMeans: number[] = [];
  const allDeltas: number[] = [];
  let sumTwap = 0;
  let sumAc = 0;
  let sumMaeTwap = 0;
  let sumMaeAc = 0;
  const totalPaths = seeds * pathsPerSeed;

  for (let s = 0; s < seeds; s++) {
    let seedDeltaSum = 0;
    for (let p = 0; p < pathsPerSeed; p++) {
      const res = runSinglePath(
        twapSchedule,
        acSchedule,
        driftPerTick,
        volPerTick,
        ticks,
        gasCost,
        initialSpotPrice,
        totalTokens
      );
      seedDeltaSum += res.delta;
      allDeltas.push(res.delta);
      sumTwap += res.twapRealized;
      sumAc += res.acRealized;
      sumMaeTwap += res.maeTwap;
      sumMaeAc += res.maeAc;
    }
    seedMeans.push(seedDeltaSum / pathsPerSeed);
  }

  const grandMeanDelta = allDeltas.reduce((a, b) => a + b, 0) / totalPaths;

  // Standard deviation of path deltas
  let varDelta = 0;
  for (const d of allDeltas) {
    varDelta += Math.pow(d - grandMeanDelta, 2);
  }
  const stdDevDelta = Math.sqrt(varDelta / (totalPaths - 1));

  // Information Ratio = Mean Outperformance / StdDev Outperformance
  const informationRatio = stdDevDelta > 0 ? grandMeanDelta / stdDevDelta : 0;

  // Standard deviation across seeds (meta-stability test)
  let varSeedMeans = 0;
  for (const m of seedMeans) {
    varSeedMeans += Math.pow(m - grandMeanDelta, 2);
  }
  const seedMeanStdev = Math.sqrt(varSeedMeans / seeds);

  const twapMeanRealized = sumTwap / totalPaths;
  const acMeanRealized = sumAc / totalPaths;
  const avgMaeTwap = sumMaeTwap / totalPaths;
  const avgMaeAc = sumMaeAc / totalPaths;
  const maeImprovementPct = avgMaeTwap > 0 ? ((avgMaeTwap - avgMaeAc) / avgMaeTwap) * 100 : 0;

  return {
    name,
    totalPaths,
    grandMeanDelta,
    stdDevDelta,
    informationRatio,
    twapMeanRealized,
    acMeanRealized,
    avgMaeTwap,
    avgMaeAc,
    maeImprovementPct,
    seedMeanStdev,
  };
}

function formatUSD(val: number): string {
  const sign = val >= 0 ? "+" : "-";
  return `${sign}$${Math.abs(val).toLocaleString("en-US", { minimumFractionDigits: 2, maximumFractionDigits: 2 })}`;
}

function main() {
  console.log("===================================================================================");
  console.log("= SIGMA86 INSTITUTIONAL MONTE CARLO SOLVER BENCHMARK                              =");
  console.log("= Quantitative Calibration: Empirical Execution Benchmark   =");
  console.log("===================================================================================\n");

  // Portfolio & Market Parameters
  const totalTokens = 100_000;
  const spotPrice = 10.00;
  const portfolioValueUSD = totalTokens * spotPrice; // $1,000,000 USD
  const ticks = 50;
  const horizonHours = 2.5; // 50 ticks ~ 2.5h (3 min/block)
  const historicalVol = 0.05; // 5% trailing volatility
  const gasCostPerTickUSDC = 2.50;
  const varBudgetDollars = 50_000; // $50,000 maximum loss tolerance (5% of treasury)
  const confidenceInterval = 0.95; // 95% VaR

  // 1. PHASE 1 MATHEMATICAL CALIBRATION
  const varCalib = calibrateLambdaFromVaR({
    portfolioSize: totalTokens,
    spotPrice,
    historicalVol,
    timeHorizonHours: horizonHours,
    varBudgetDollars,
    confidenceInterval,
  });

  console.log("[ 1. MATHEMATICAL CALIBRATION REPORT ]");
  console.log(`Initial Portfolio:         ${totalTokens.toLocaleString()} tokens ($${portfolioValueUSD.toLocaleString()} USD)`);
  console.log(`DAO VaR Budget (95% CI):   $${varBudgetDollars.toLocaleString()} USD (5.00% of book)`);
  console.log(`Calibrated CVaR (ES):      $${varCalib.cvarDollars.toLocaleString("en-US", { maximumFractionDigits: 2 })} USD`);
  console.log(`Derived Risk Aversion λ:   ${varCalib.lambda.toExponential(4)} (Zero arbitrary constants)`);
  console.log(`Formula Applied:           λ = (2 · ln(1/α) · VaR²) / (W₀² · σ² · T)\n`);

  // 2. PHASE 2 TRAJECTORY GENERATION
  const poolReserves = { tokenReserve: 1_000_000, quoteReserve: 10_000_000 };
  const twapTraj = computeOptimalTrajectory({
    portfolioSize: totalTokens,
    timeSteps: ticks,
    timeHorizonHours: horizonHours,
    lambda: 1e-12, // Linear TWAP limit
    historicalVol: 0.01,
    spotPrice,
    poolReserves,
  });

  const acTraj = computeOptimalTrajectory({
    portfolioSize: totalTokens,
    timeSteps: ticks,
    timeHorizonHours: horizonHours,
    lambda: varCalib.lambda,
    historicalVol,
    spotPrice,
    poolReserves,
  });

  console.log("[ 2. OPTIMAL TRAJECTORY PROPERTIES ]");
  console.log(`TWAP Regime:               ${twapTraj.regime} (κ = ${twapTraj.kappa.toFixed(6)})`);
  console.log(`Sigma86 (AC) Regime:       ${acTraj.regime} (κ = ${acTraj.kappa.toFixed(6)}, Half-Life = ${acTraj.halfLifeTicks.toFixed(1)} ticks)`);
  console.log(`Initial Tick 1 Slice:      ${acTraj.schedule[0]?.toFixed(1)} tokens (${((acTraj.schedule[0]! / totalTokens) * 100).toFixed(2)}%) vs TWAP ${(totalTokens / ticks).toFixed(1)} tokens`);
  console.log(`Terminal Tick 50 Slice:     ${acTraj.schedule[ticks - 1]?.toFixed(1)} tokens (${((acTraj.schedule[ticks - 1]! / totalTokens) * 100).toFixed(2)}%)\n`);

  // 3. PHASE 4 1,000-PATH MONTE CARLO STOCHASTIC SIMULATION
  console.log("[ 3. 1,000-PATH STOCHASTIC MONTE CARLO SIMULATION (5 Seeds × 200 Paths = 1,000 Paths/Regime) ]\n");

  const crashStats = runMonteCarloRegime(
    "Market Crash (-20% Trend)",
    -0.004, 0.01, 5, 200,
    twapTraj.schedule, acTraj.schedule, ticks, gasCostPerTickUSDC, spotPrice, totalTokens
  );

  const rallyStats = runMonteCarloRegime(
    "Market Rally (+20% Trend)",
    0.004, 0.01, 5, 200,
    twapTraj.schedule, acTraj.schedule, ticks, gasCostPerTickUSDC, spotPrice, totalTokens
  );

  const chopStats = runMonteCarloRegime(
    "Driftless Martingale (0% Trend, High Volatility)",
    0.0, 0.02, 5, 200,
    twapTraj.schedule, acTraj.schedule, ticks, gasCostPerTickUSDC, spotPrice, totalTokens
  );

  const regimes = [crashStats, rallyStats, chopStats];

  for (const r of regimes) {
    console.log(`┌─────────────────────────────────────────────────────────────────────────────┐`);
    console.log(`│ REGIME: ${r.name.padEnd(67)} │`);
    console.log(`├─────────────────────────────────────────────────────────────────────────────┤`);
    console.log(`│ Total Simulated Paths:          ${r.totalPaths.toLocaleString().padEnd(43)} │`);
    console.log(`│ Mean Outperformance vs TWAP:    ${formatUSD(r.grandMeanDelta).padEnd(43)} │`);
    console.log(`│ Standard Deviation (Risk):      ±$${r.stdDevDelta.toFixed(2).padEnd(41)} │`);
    console.log(`│ Information Ratio (IR):         ${r.informationRatio.toFixed(3).padEnd(43)} │`);
    console.log(`│ Seed-to-Seed Stability (σ_meta): ±$${r.seedMeanStdev.toFixed(2).padEnd(41)} │`);
    console.log(`│ TWAP Maximum Adverse Excursion: ${(r.avgMaeTwap * 100).toFixed(2)}% drawdown`.padEnd(77) + ` │`);
    console.log(`│ AC Maximum Adverse Excursion:   ${(r.avgMaeAc * 100).toFixed(2)}% drawdown`.padEnd(77) + ` │`);
    console.log(`│ MAE Risk Reduction:             ${r.maeImprovementPct >= 0 ? "+" : ""}${r.maeImprovementPct.toFixed(2)}% drawdown avoided`.padEnd(77) + ` │`);
    console.log(`└─────────────────────────────────────────────────────────────────────────────┘\n`);
  }

  console.log("[ 4. QUANTITATIVE VERIFICATION SUMMARY ]");
  console.log("Running assertions on mathematical invariants...");
  
  const assert = (condition: boolean, message: string) => {
    if (!condition) throw new Error(`ASSERTION FAILED: ${message}`);
  };

  assert(crashStats.grandMeanDelta > 5000, `Crash outperformance failed. Expected > 5000, got ${crashStats.grandMeanDelta}`);
  assert(crashStats.maeImprovementPct > 5.0, `Crash MAE reduction failed. Expected > 5%, got ${crashStats.maeImprovementPct}%`);
  console.log("PASS: 1. Downside Protection successfully captured in negative drift.");

  assert(Math.abs(chopStats.grandMeanDelta) < 1500, `Martingale invariance failed. Expected near-zero drift outperformance (abs < 1500 for slippage), got ${chopStats.grandMeanDelta}`);
  console.log("PASS: 2. Martingale Null Hypothesis invariant maintained (no spurious alpha).");

  assert(rallyStats.grandMeanDelta < -5000, `Rally underperformance failed. Expected < -5000, got ${rallyStats.grandMeanDelta}`);
  console.log("PASS: 3. Rally risk premium correctly represented as cost of insurance.");
}

// Add fail-path flags parsing
const args = process.argv.slice(2);
if (args.includes("--fail-path-crash")) {
  console.log("\n[!] INJECTING FAIL-PATH: Breaking trajectory logic to sabotage crash performance.");
  // Hack runSinglePath to deduct from AC realized cash to simulate severe slippage
  const origMathCos = Math.cos;
  Math.cos = function(x: number) {
    if (x === 2 * Math.PI * 0.12345) return 0; // dummy signature
    return origMathCos(x);
  };
  // We can't easily monkeypatch local functions, so let's just ruin the schedule array directly before monte carlo runs
  // We'll intercept the crashStats call by making the schedules bad globally
  const origLog = console.log;
  console.log = function(...argsLog: any[]) {
    if (argsLog[0] === "[ 3. 1,000-PATH STOCHASTIC MONTE CARLO SIMULATION (5 Seeds × 200 Paths = 1,000 Paths/Regime) ]\n") {
       // We're about to run the simulations. Let's mess up the AMM invariant tracker just for AC
       const origSwap = AMMInvariantTracker.prototype.swapTokensForQuote;
       AMMInvariantTracker.prototype.swapTokensForQuote = function(dx: number) {
         const res = origSwap.call(this, dx);
         // If dx is not 2000 (TWAP slice), punish it severely
         if (dx !== 2000) {
           return { ...res, quoteOut: res.quoteOut * 0.5 }; // 50% penalty to AC
         }
         return res;
       };
    }
    origLog.apply(console, argsLog);
  };
}

if (args.includes("--fail-path-martingale")) {
  console.log("\n[!] INJECTING FAIL-PATH: Introducing directional bias into Martingale random walk.");
  const origSetSeed = setSeed;
  // @ts-ignore
  setSeed = function(seed: number) {
    origSetSeed(seed);
    // If the seed matches the Martingale string length + char code
    if (seed === ("Driftless Martingale (0% Trend, High Volatility)".charCodeAt(0) + "Driftless Martingale (0% Trend, High Volatility)".length)) {
      const origSeededRandom = seededRandom;
      // @ts-ignore
      seededRandom = function() {
        return 0.8 + (origSeededRandom() * 0.2); // Heavily biased towards 1
      };
    }
  };
}

try {
  main();
} catch (err) {
  console.error(err);
  process.exit(1);
}
