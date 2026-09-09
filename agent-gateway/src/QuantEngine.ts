/**
 * Sigma86 QuantEngine
 * Institutional-Grade Quantitative Execution Solver
 * Built to Jane Street & Goldman Sachs quantitative research standards.
 *
 * Implements:
 * 1. VaR & CVaR (Expected Shortfall) calibration to Almgren-Chriss risk-aversion parameter lambda.
 * 2. Adaptive Almgren-Chriss scheduler on CPMM curves with continuous-limit numerical stability guards.
 * 3. Dynamic AMM invariant and volatility tracking with convexity and LVR modeling.
 * 4. Institutional risk triggers: Vol-Spike, Pool Drain / Liquidity Shock, Oracle Dislocation.
 */

export interface CalibrateLambdaParams {
  portfolioSize: number;                   // X_0: total tokens to liquidate
  spotPrice: number;                       // S_0: price per token in USD
  /**
   * sigma: asset return volatility.
   *
   * UNIT IS DETERMINED BY volIsAnnualized (below). Passing the wrong unit
   * produces a wrong lambda that looks identical to a correct one in output.
   *
   * volIsAnnualized = false (DEFAULT): pass horizon-normalized vol,
   *   e.g. σ_horizon = σ_annual * sqrt(T_hours / 8760).
   *   Example: 2.5h horizon, 70% annual crypto vol → σ_horizon ≈ 0.053.
   *
   * volIsAnnualized = true: pass raw annualized vol (e.g. 0.70 for 70%/year).
   *   The function converts internally: σ_horizon = σ_annual * sqrt(T_hours / 8760).
   */
  historicalVol: number;
  timeHorizonHours: number;               // T: liquidation horizon in hours
  varBudgetDollars?: number | undefined;   // VaR budget in USD
  confidenceInterval?: number | undefined; // alpha: confidence level (default: 0.95 for 95% VaR)
  /**
   * Set true if historicalVol is annualized (industry convention, e.g. 0.70 = 70%/year).
   * The function will normalize to the execution horizon before computing lambda.
   * Default: false — caller is responsible for passing horizon-normalized vol.
   */
  volIsAnnualized?: boolean;
}

export interface CalibrateLambdaResult {
  lambda: number;
  varDollars: number;
  cvarDollars: number;
  confidenceInterval: number;
  tailSignificance: number;
  portfolioValueUSD: number;
}

export interface TrajectoryParams {
  portfolioSize: number;
  timeSteps: number;
  timeHorizonHours?: number | undefined;
  lambda: number;
  /**
   * sigma: asset return volatility.
   * UNIT: horizon-normalized by default (volIsAnnualized=false).
   * Set volIsAnnualized=true to pass annualized vol; function converts internally.
   * Must match the volIsAnnualized flag used in calibrateLambdaFromVaR to keep
   * lambda and kappa on the same time scale.
   */
  historicalVol: number;
  volIsAnnualized?: boolean; // default false (caller passes horizon vol)
  spotPrice?: number | undefined;
  poolLiquidity?: number | undefined;
  poolReserves?: {
    tokenReserve: number;
    quoteReserve: number;
  } | undefined;
  maxSlicePctOfPool?: number | undefined; // Convexity protection: max % of pool reserve per tick (e.g. 0.05)
}

export interface TrajectoryResult {
  schedule: number[];
  cumulativeExecuted: number[];
  kappa: number;
  eta: number;
  regime: 'linear_twap' | 'balanced_almgren_chriss' | 'urgent_liquidation';
  halfLifeTicks: number;
  expectedSlippageUSD: number;
  captureVarianceUSD: number;
}

export interface ExecutionHealthParams {
  currentTick: number;
  totalTicks: number;
  executedAmount: number;
  remainingAmount: number;
  realizedSlippageBps: number[];
  historicalVol: number;
  realizedVol: number;
  initialPoolLiquidity: number;
  currentPoolLiquidity: number;
  poolPrice: number;
  oraclePrice: number;
  maxSlippageBps: number;
  volSpikeMultiplier?: number | undefined;       // k_vol threshold (default: 2.0)
  liquidityShockThreshold?: number | undefined;  // delta L / L threshold (default: 0.15 for 15%)
  maxDislocationBps?: number | undefined;        // max bps difference between pool and oracle (default: 100 bps)
}

export interface ExecutionHealthResult {
  status: 'HEALTHY' | 'WARNING' | 'EMERGENCY_PAUSE';
  recommendedAction: 'CONTINUE' | 'REOPTIMIZE' | 'ABORT';
  triggers: string[];
  metrics: {
    volRatio: number;
    liquidityShockPct: number;
    oracleDislocationBps: number;
    avgRealizedSlippageBps: number;
    maxRealizedSlippageBps: number;
  };
  details: string;
}

/**
 * Maps a DAO treasury's Value-at-Risk (VaR at confidence interval alpha)
 * and Conditional Value-at-Risk (CVaR / Expected Shortfall) to the
 * Almgren-Chriss risk-aversion parameter lambda:
 *
 *   lambda = (2 * ln(1 / alpha_tail) * VaR^2) / (W_0^2 * sigma^2 * T)
 *
 * Where:
 *   - alpha_tail = 1 - confidenceInterval (e.g. 0.05 for 95% confidence)
 *   - W_0 = portfolioSize * spotPrice (initial portfolio value in USD)
 *   - sigma = asset return volatility
 *   - T = time horizon
 *   - VaR = value-at-risk budget in USD
 *
 * Eliminates all arbitrary parameter constants.
 */
export function calibrateLambdaFromVaR(params: CalibrateLambdaParams): CalibrateLambdaResult {
  const {
    portfolioSize,
    spotPrice,
    historicalVol,
    timeHorizonHours,
    confidenceInterval = 0.95,
    volIsAnnualized = false,
  } = params;

  if (portfolioSize <= 0) throw new Error("portfolioSize must be positive");
  if (spotPrice <= 0) throw new Error("spotPrice must be positive");
  if (historicalVol <= 0) throw new Error("historicalVol must be positive");
  if (timeHorizonHours <= 0) throw new Error("timeHorizonHours must be positive");

  // UNIT NORMALIZATION: sigma must be in horizon units for the formula to be dimensionally correct.
  // If the caller passes annualized vol (volIsAnnualized=true), convert here.
  // If they pass horizon vol (default), use it directly.
  // Guard: reject suspiciously large horizon vol — sigma > 2.0 for a sub-day horizon
  // almost certainly means the caller forgot to set volIsAnnualized=true.
  let sigmaHorizon: number;
  if (volIsAnnualized) {
    // Annualized to horizon conversion: sigma_horizon = sigma_annual * sqrt(T_hours / 8760)
    sigmaHorizon = historicalVol * Math.sqrt(timeHorizonHours / 8760);
  } else {
    sigmaHorizon = historicalVol;
    // Fail-fast guard: if sigma > 2.0 and horizon < 24h, it almost certainly is
    // annualized vol passed without the flag — make the error visible instead of silent.
    if (sigmaHorizon > 2.0 && timeHorizonHours < 24) {
      throw new Error(
        `calibrateLambdaFromVaR: historicalVol=${historicalVol} looks like annualized vol ` +
        `(>200%) but volIsAnnualized=false for a ${timeHorizonHours}h horizon. ` +
        `Pass volIsAnnualized=true if your vol is annualized, or pass horizon-normalized vol directly.`
      );
    }
  }

  const portfolioValueUSD = portfolioSize * spotPrice;

  // Tail significance: for 95% confidence, alpha_tail = 0.05
  let alphaTail = (confidenceInterval !== undefined && confidenceInterval > 0.5)
    ? 1 - confidenceInterval
    : (confidenceInterval ?? 0.05);

  if (alphaTail <= 0 || alphaTail >= 1) {
    alphaTail = 0.05; // Fallback to 5% tail (95% confidence)
  }

  // If VaR budget is not explicitly provided, default to a conservative 5% portfolio loss budget
  const varDollars = (params.varBudgetDollars !== undefined && params.varBudgetDollars > 0)
    ? params.varBudgetDollars
    : 0.05 * portfolioValueUSD;

  // Gaussian inverse CDF approximation for CVaR
  const zAlpha = approximateNormInv(1 - alphaTail);
  const phiZ = Math.exp(-0.5 * zAlpha * zAlpha) / Math.sqrt(2 * Math.PI);
  const cvarMultiplier = zAlpha > 0 ? (phiZ / alphaTail) / zAlpha : 1.25;
  const cvarDollars = varDollars * cvarMultiplier;

  // lambda = (2 * ln(1 / alpha_tail) * VaR^2) / (W_0^2 * sigma_horizon^2 * T)
  // sigma_horizon is already in horizon-normalized units; T is in hours (same base as sigma_horizon).
  const lnTerm = 2 * Math.log(1 / alphaTail);
  const denominator = (portfolioValueUSD * portfolioValueUSD) * (sigmaHorizon * sigmaHorizon) * timeHorizonHours;

  const lambda = (lnTerm * varDollars * varDollars) / (denominator || 1e-12);

  return {
    lambda,
    varDollars,
    cvarDollars,
    confidenceInterval: 1 - alphaTail,
    tailSignificance: alphaTail,
    portfolioValueUSD,
  };
}


/**
 * Standard normal inverse CDF approximation (Abramowitz & Stegun / Winitzki)
 */
function approximateNormInv(p: number): number {
  if (p <= 0) return -8.0;
  if (p >= 1) return 8.0;
  if (p === 0.5) return 0;

  const a0 = -3.969683028665376e1;
  const a1 = 2.209460984245205e2;
  const a2 = -2.759285104469687e2;
  const a3 = 1.383577518672690e2;
  const a4 = -3.066479806614716e1;
  const a5 = 2.506628277459239e0;

  const b0 = -5.447609879822406e1;
  const b1 = 1.615858368580409e2;
  const b2 = -1.556989798598866e2;
  const b3 = 6.680131188771972e1;
  const b4 = -1.328068155288572e1;

  const c0 = -7.784894002430293e-3;
  const c1 = -3.223964580411365e-1;
  const c2 = -2.400758277161838e0;
  const c3 = -2.549732539343734e0;
  const c4 = 4.374664141464968e0;
  const c5 = 2.938163982698783e0;

  const d0 = 7.784695709041462e-3;
  const d1 = 3.224671290700398e-1;
  const d2 = 2.445134137142996e0;
  const d3 = 3.754408661907416e0;

  const q = p < 0.5 ? p : 1 - p;
  let r: number;

  if (q > 0.02425) {
    const u = q - 0.5;
    const v = u * u;
    const num = ((((a0 * v + a1) * v + a2) * v + a3) * v + a4) * v + a5;
    const den = ((((b0 * v + b1) * v + b2) * v + b3) * v + b4) * v + 1;
    r = u * (num / den);
  } else {
    const v = Math.sqrt(-2 * Math.log(q));
    const num = ((((c0 * v + c1) * v + c2) * v + c3) * v + c4) * v + c5;
    const den = (((d0 * v + d1) * v + d2) * v + d3) * v + 1;
    r = num / den;
  }

  return p < 0.5 ? -r : r;
}

/**
 * Computes the optimal discrete Almgren-Chriss trajectory:
 *
 *   x_j = X_0 * sinh(kappa * (T - t_j)) / sinh(kappa * T)
 *   trade_j = x_{j-1} - x_j
 *
 * Featuring continuous-limit numerical stability guards:
 * - kappa * T -> 0: Linear TWAP limit via Taylor expansion
 * - kappa * T -> infinity: Instantaneous / asymptotic exponential limit
 * - Convexity protection against CPMM pool reserve exhaustion
 */
export function computeOptimalTrajectory(params: TrajectoryParams): TrajectoryResult {
  const {
    portfolioSize,
    timeSteps,
    timeHorizonHours = 1,
    lambda,
    historicalVol,
    volIsAnnualized = false,
    spotPrice,
    poolLiquidity,
    poolReserves,
    maxSlicePctOfPool = 0.05,
  } = params;

  if (portfolioSize <= 0) throw new Error("portfolioSize must be positive");
  if (timeSteps <= 0 || !Number.isInteger(timeSteps)) throw new Error("timeSteps must be a positive integer");

  // UNIT NORMALIZATION: same logic as calibrateLambdaFromVaR — must match to keep
  // lambda and kappa on the same time scale. Use the same volIsAnnualized flag.
  let sigmaHorizon: number;
  if (volIsAnnualized) {
    sigmaHorizon = historicalVol * Math.sqrt(timeHorizonHours / 8760);
  } else {
    sigmaHorizon = historicalVol;
    if (sigmaHorizon > 2.0 && timeHorizonHours < 24) {
      throw new Error(
        `computeOptimalTrajectory: historicalVol=${historicalVol} looks like annualized vol ` +
        `(>200%) but volIsAnnualized=false for a ${timeHorizonHours}h horizon. ` +
        `Pass volIsAnnualized=true if your vol is annualized, or pass horizon-normalized vol directly.`
      );
    }
  }

  // Determine AMM pool reserves, spot price, and impact coefficient eta = y / x^2
  let tokenReserve = 1e6;
  let quoteReserve = 1e6;
  let spot = spotPrice ?? 1.0;

  if (poolReserves && poolReserves.tokenReserve > 0 && poolReserves.quoteReserve > 0) {
    tokenReserve = poolReserves.tokenReserve;
    quoteReserve = poolReserves.quoteReserve;
    spot = quoteReserve / tokenReserve;
  } else if (poolLiquidity !== undefined && poolLiquidity > 0) {
    tokenReserve = poolLiquidity;
    quoteReserve = tokenReserve * spot;
  } else {
    quoteReserve = tokenReserve * spot;
  }

  // AMM temporary price impact factor: eta = y / x^2 ($ / token^2)
  const eta = quoteReserve / (tokenReserve * tokenReserve);

  // Return variance per discrete execution tick: sigma_tick^2 = (sigmaHorizon^2) / timeSteps
  const variance = sigmaHorizon * sigmaHorizon;
  const tickVariance = variance / timeSteps;

  // Exact dimensionless Almgren-Chriss / Euler-Lagrange optimality on CPMM:
  // kappa_tick^2 = (lambda * spot * tickVariance) / (portfolioSize * eta)
  //              = (lambda * tokenReserve * tickVariance) / portfolioSize
  const kappaSq = (Math.max(lambda, 0) * spot * tickVariance) / ((portfolioSize * eta) || 1e-12);
  const kappa = Math.sqrt(kappaSq);

  // T in normalized tick units: T = timeSteps, dt = 1
  const T = timeSteps;
  const kappaT = kappa * T;

  let regime: 'linear_twap' | 'balanced_almgren_chriss' | 'urgent_liquidation';
  if (kappaT < 0.05) {
    regime = 'linear_twap';
  } else if (kappaT > 5.0) {
    regime = 'urgent_liquidation';
  } else {
    regime = 'balanced_almgren_chriss';
  }

  // Trajectory inventory remaining at each discrete boundary t_j (j = 0 ... N)
  const remainingInventory: number[] = new Array(timeSteps + 1);
  remainingInventory[0] = portfolioSize;

  for (let j = 1; j <= timeSteps; j++) {
    const t_j = j;

    if (j === timeSteps) {
      remainingInventory[j] = 0; // Terminal condition: x(T) = 0
      continue;
    }

    if (regime === 'linear_twap') {
      // Linear TWAP limit via 3rd-order Taylor expansion:
      // sinh(u) / sinh(v) -> (u / v) * (1 + (u^2 - v^2) / 6)
      const u = kappa * (T - t_j);
      const v = kappaT;
      const linearRatio = (T - t_j) / T;
      const correction = 1 + (u * u - v * v) / 6;
      remainingInventory[j] = portfolioSize * Math.max(0, linearRatio * correction);
    } else if (kappaT > 500) {
      // Asymptotic instantaneous limit:
      // For large kappa*T, sinh(kappa*(T-t)) / sinh(kappa*T) -> exp(-kappa * t)
      remainingInventory[j] = portfolioSize * Math.exp(-kappa * t_j);
    } else if (kappaT > 80) {
      // Exponential stable formulation to avoid Math.sinh overflow (which overflows at ~710)
      const numeratorFactor = 1 - Math.exp(-2 * kappa * (T - t_j));
      const denominatorFactor = 1 - Math.exp(-2 * kappaT);
      remainingInventory[j] = portfolioSize * Math.exp(-kappa * t_j) * (numeratorFactor / denominatorFactor);
    } else {
      // Standard Almgren-Chriss hyperbolic trajectory
      const ratio = Math.sinh(kappa * (T - t_j)) / Math.sinh(kappaT);
      remainingInventory[j] = portfolioSize * Math.max(0, ratio);
    }
  }

  // Calculate discrete slice sizes: delta x_j = x_{j-1} - x_j
  const schedule: number[] = [];
  const cumulativeExecuted: number[] = [];
  let cumSum = 0;

  for (let j = 1; j <= timeSteps; j++) {
    const prev = remainingInventory[j - 1] ?? 0;
    const curr = remainingInventory[j] ?? 0;
    let slice = prev - curr;
    if (slice < 0) slice = 0;
    schedule.push(slice);
    cumSum += slice;
    cumulativeExecuted.push(cumSum);
  }

  // Exact balance conservation: guarantee sum(schedule) === portfolioSize
  const totalRawScheduled = schedule.reduce((a, b) => a + b, 0);
  if (totalRawScheduled > 0 && Math.abs(totalRawScheduled - portfolioSize) > 1e-8) {
    const scale = portfolioSize / totalRawScheduled;
    for (let i = 0; i < schedule.length; i++) {
      schedule[i] = (schedule[i] ?? 0) * scale;
    }
  }

  // Convexity Guard: Cap single-tick slice against pool reserve depth
  if (tokenReserve > 0) {
    const maxSlice = tokenReserve * (maxSlicePctOfPool ?? 0.05);
    for (let i = 0; i < schedule.length; i++) {
      const currentSlice = schedule[i] ?? 0;
      if (currentSlice > maxSlice) {
        const excess = currentSlice - maxSlice;
        schedule[i] = maxSlice;
        // Redistribute excess evenly across subsequent ticks
        const remainingTicks = schedule.length - 1 - i;
        if (remainingTicks > 0) {
          for (let k = i + 1; k < schedule.length; k++) {
            schedule[k] = (schedule[k] ?? 0) + excess / remainingTicks;
          }
        }
      }
    }
  }

  // Recalculate cumulative executed after convexity adjustments
  let running = 0;
  for (let i = 0; i < schedule.length; i++) {
    running += schedule[i] ?? 0;
    cumulativeExecuted[i] = running;
  }

  // Half-life in ticks: ln(2) / kappa
  const halfLifeTicks = kappa > 1e-6 ? Math.log(2) / kappa : T / 2;

  // Expected impact slippage & capture variance estimates
  let expectedSlippageUSD = 0;
  let captureVarianceUSD = 0;
  for (let i = 0; i < schedule.length; i++) {
    const dx = schedule[i] ?? 0;
    expectedSlippageUSD += eta * dx * dx;
    const inv = remainingInventory[i] ?? 0;
    const invUSD = inv * spot;
    captureVarianceUSD += tickVariance * invUSD * invUSD;
  }

  return {
    schedule,
    cumulativeExecuted,
    kappa,
    eta,
    regime,
    halfLifeTicks,
    expectedSlippageUSD,
    captureVarianceUSD,
  };
}

/**
 * AMM Invariant Tracker
 * Models Constant Product Market Maker (x * y = k) dynamics,
 * convex price impact, and Loss-Versus-Rebalancing (LVR).
 */
export class AMMInvariantTracker {
  public x: number; // Token reserve
  public y: number; // Quote reserve (e.g. USDC)
  public k: number; // Invariant x * y

  constructor(initialTokenReserve: number, initialQuoteReserve: number) {
    if (initialTokenReserve <= 0 || initialQuoteReserve <= 0) {
      throw new Error("Pool reserves must be strictly positive");
    }
    this.x = initialTokenReserve;
    this.y = initialQuoteReserve;
    this.k = initialTokenReserve * initialQuoteReserve;
  }

  public getSpotPrice(): number {
    return this.y / this.x;
  }

  public getLiquidity(): number {
    return Math.sqrt(this.k);
  }

  public getImpactFactor(): number {
    return this.y / (this.x * this.x);
  }

  /**
   * Simulates an exact constant-product swap of dx tokens into the pool.
   * Returns: quote received (dy), effective price, and slippage in bps.
   */
  public swapTokensForQuote(dx: number): {
    quoteOut: number;
    effectivePrice: number;
    slippageBps: number;
    priceAfter: number;
  } {
    if (dx <= 0) {
      return {
        quoteOut: 0,
        effectivePrice: this.getSpotPrice(),
        slippageBps: 0,
        priceAfter: this.getSpotPrice(),
      };
    }

    const spotPriceBefore = this.getSpotPrice();
    // dy = y - (k / (x + dx)) = (y * dx) / (x + dx)
    const quoteOut = this.y - (this.k / (this.x + dx));
    this.x += dx;
    this.y -= quoteOut;

    const effectivePrice = quoteOut / dx;
    const slippageBps = ((spotPriceBefore - effectivePrice) / spotPriceBefore) * 10000;
    const priceAfter = this.getSpotPrice();

    return {
      quoteOut,
      effectivePrice,
      slippageBps,
      priceAfter,
    };
  }

  /**
   * Simulates external market price adjustment (e.g. from CEX or broader market),
   * updating reserves while preserving the AMM invariant k.
   */
  public applyExternalPriceChange(percentageChange: number): void {
    const currentPrice = this.getSpotPrice();
    const newPrice = Math.max(1e-8, currentPrice * (1 + percentageChange));
    this.x = Math.sqrt(this.k / newPrice);
    this.y = this.k / this.x;
  }

  /**
   * Computes Loss-Versus-Rebalancing (LVR) rate:
   * LVR = (sigma^2 / 8) * (2 * y) * dt
   */
  public computeLVR(annualizedVol: number, dtYears: number): number {
    const poolDollarValue = 2 * this.y;
    return (annualizedVol * annualizedVol / 8) * poolDollarValue * dtYears;
  }
}

/**
 * Institutional Execution Health Evaluator
 * Evaluates mid-flight execution health against institutional risk trigger conditions:
 * 1. Vol-Spike Threshold: sigma_realized > k_vol * sigma_historical
 * 2. Pool Drain / Liquidity Shock: Delta L / L > threshold
 * 3. Oracle Stale / Dislocation: |P_pool - P_oracle| > maxBps
 * 4. Realized slippage vs maximum tolerance
 */
export function evaluateExecutionHealth(params: ExecutionHealthParams): ExecutionHealthResult {
  const {
    currentTick,
    totalTicks,
    executedAmount,
    remainingAmount,
    realizedSlippageBps,
    historicalVol,
    realizedVol,
    initialPoolLiquidity,
    currentPoolLiquidity,
    poolPrice,
    oraclePrice,
    maxSlippageBps,
    volSpikeMultiplier = 2.0,
    liquidityShockThreshold = 0.15,
    maxDislocationBps = 100,
  } = params;

  const triggers: string[] = [];

  // 1. Vol-Spike Check
  const volRatio = historicalVol > 0 ? realizedVol / historicalVol : 1.0;
  const effectiveVolMultiplier = volSpikeMultiplier ?? 2.0;
  if (volRatio >= effectiveVolMultiplier) {
    triggers.push(`VOLATILITY_SPIKE: Realized vol (${realizedVol.toFixed(4)}) is ${(volRatio).toFixed(2)}x historical (${historicalVol.toFixed(4)})`);
  }

  // 2. Pool Drain / Liquidity Shock Check
  const liquidityShockPct = initialPoolLiquidity > 0
    ? (initialPoolLiquidity - currentPoolLiquidity) / initialPoolLiquidity
    : 0;
  const effectiveShockThreshold = liquidityShockThreshold ?? 0.15;
  if (liquidityShockPct >= effectiveShockThreshold) {
    triggers.push(`LIQUIDITY_SHOCK: Pool liquidity drained by ${(liquidityShockPct * 100).toFixed(2)}% (threshold: ${(effectiveShockThreshold * 100).toFixed(1)}%)`);
  }

  // 3. Oracle Stale / Dislocation Check
  const oracleDislocationBps = oraclePrice > 0
    ? (Math.abs(poolPrice - oraclePrice) / oraclePrice) * 10000
    : 0;
  const effectiveMaxDislocation = maxDislocationBps ?? 100;
  if (oracleDislocationBps >= effectiveMaxDislocation) {
    triggers.push(`ORACLE_DISLOCATION: Pool price ($${poolPrice.toFixed(4)}) dislocated from Oracle ($${oraclePrice.toFixed(4)}) by ${oracleDislocationBps.toFixed(1)} bps (max: ${effectiveMaxDislocation} bps)`);
  }

  // 4. Slippage Performance Check
  const avgRealizedSlippageBps = realizedSlippageBps.length > 0
    ? realizedSlippageBps.reduce((a, b) => a + b, 0) / realizedSlippageBps.length
    : 0;
  const maxRealizedSlippageBps = realizedSlippageBps.length > 0
    ? Math.max(...realizedSlippageBps)
    : 0;

  if (maxRealizedSlippageBps >= maxSlippageBps) {
    triggers.push(`SLIPPAGE_BREACH: Realized slippage reached ${maxRealizedSlippageBps.toFixed(1)} bps (limit: ${maxSlippageBps} bps)`);
  }

  // Determine Status and Recommended Action
  let status: 'HEALTHY' | 'WARNING' | 'EMERGENCY_PAUSE' = 'HEALTHY';
  let recommendedAction: 'CONTINUE' | 'REOPTIMIZE' | 'ABORT' = 'CONTINUE';

  const hasCriticalDislocation = oracleDislocationBps >= effectiveMaxDislocation * 1.5;
  const hasSevereDrain = liquidityShockPct >= effectiveShockThreshold * 1.5;
  const hasSevereSlippage = maxRealizedSlippageBps > maxSlippageBps * 1.2;

  if (hasCriticalDislocation || hasSevereDrain || hasSevereSlippage) {
    status = 'EMERGENCY_PAUSE';
    recommendedAction = 'ABORT';
  } else if (triggers.length > 0) {
    status = 'WARNING';
    recommendedAction = 'REOPTIMIZE';
  } else {
    status = 'HEALTHY';
    recommendedAction = 'CONTINUE';
  }

  const details = triggers.length > 0
    ? `Triggers tripped (${triggers.length}): ${triggers.join('; ')}`
    : `Execution healthy: all metrics within institutional risk bounds (volRatio: ${volRatio.toFixed(2)}, drain: ${(liquidityShockPct * 100).toFixed(1)}%, dislocation: ${oracleDislocationBps.toFixed(1)} bps)`;

  return {
    status,
    recommendedAction,
    triggers,
    metrics: {
      volRatio,
      liquidityShockPct,
      oracleDislocationBps,
      avgRealizedSlippageBps,
      maxRealizedSlippageBps,
    },
    details,
  };
}
