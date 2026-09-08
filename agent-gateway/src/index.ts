import { Server } from "@modelcontextprotocol/sdk/server/index.js";
import { StdioServerTransport } from "@modelcontextprotocol/sdk/server/stdio.js";
import {
  CallToolRequestSchema,
  ListToolsRequestSchema,
} from "@modelcontextprotocol/sdk/types.js";
import {
  calibrateLambdaFromVaR,
  computeOptimalTrajectory,
  evaluateExecutionHealth,
} from "./QuantEngine.js";

const server = new Server(
  {
    name: "sigma86-agent-gateway",
    version: "2.0.0",
  },
  {
    capabilities: {
      tools: {},
    },
  }
);

server.setRequestHandler(ListToolsRequestSchema, async () => {
  return {
    tools: [
      {
        name: "calculate_liquidation_schedule",
        description: "Calculates an institutional Almgren-Chriss liquidation schedule calibrated against a DAO's Value-at-Risk (VaR) budget and AMM CPMM convexity.",
        inputSchema: {
          type: "object",
          properties: {
            portfolioSize: {
              type: "number",
              description: "The total token size of the portfolio to liquidate (X_0).",
            },
            spotPrice: {
              type: "number",
              description: "Current token spot price in USD (S_0). Defaults to 1.0.",
            },
            varBudgetDollars: {
              type: "number",
              description: "Maximum dollar loss budget at the specified confidence interval (VaR). Defaults to 5% of portfolio value.",
            },
            confidenceInterval: {
              type: "number",
              description: "Confidence interval for VaR calibration (e.g. 0.95 for 95%). Defaults to 0.95.",
            },
            timeHorizonHours: {
              type: "number",
              description: "Total execution time horizon in hours. Defaults to 1.0.",
            },
            timeSteps: {
              type: "number",
              description: "The total number of discrete execution ticks (N).",
            },
            historicalVolWindow: {
              type: "number",
              description: "Trailing price volatility (sigma) measured over historical window.",
            },
            poolReserves: {
              type: "object",
              properties: {
                tokenReserve: { type: "number", description: "Base token reserve in CPMM pool (x)." },
                quoteReserve: { type: "number", description: "Quote token (USD) reserve in CPMM pool (y)." },
              },
              required: ["tokenReserve", "quoteReserve"],
              description: "Live AMM pool reserves (x and y) for invariant tracking.",
            },
            poolLiquidity: {
              type: "number",
              description: "Alternative single-value pool base liquidity depth (x). Used if poolReserves is omitted.",
            },
            riskAversion: {
              type: "number",
              description: "Optional explicit risk-aversion parameter (lambda). If omitted, lambda is calibrated from VaR.",
            },
            maxSlicePctOfPool: {
              type: "number",
              description: "Max percentage of pool reserve allowed in a single tick (convexity guard). Defaults to 0.05 (5%).",
            },
          },
          required: ["portfolioSize", "timeSteps", "historicalVolWindow"],
        },
      },
      {
        name: "evaluate_execution_health",
        description: "Evaluates mid-flight execution health against institutional risk triggers (Vol-Spike, Pool Drain, Oracle Dislocation, Slippage Breach) and recommends re-optimization or emergency pause.",
        inputSchema: {
          type: "object",
          properties: {
            currentTick: {
              type: "number",
              description: "Current discrete execution tick index (0-indexed).",
            },
            totalTicks: {
              type: "number",
              description: "Total scheduled ticks in execution plan.",
            },
            executedAmount: {
              type: "number",
              description: "Cumulative tokens executed so far.",
            },
            remainingAmount: {
              type: "number",
              description: "Remaining tokens to execute.",
            },
            realizedSlippageBps: {
              type: "array",
              items: { type: "number" },
              description: "Array of realized slippages (in basis points) for completed ticks.",
            },
            historicalVol: {
              type: "number",
              description: "Ex-ante baseline historical volatility (sigma_historical).",
            },
            realizedVol: {
              type: "number",
              description: "Realized trailing volatility over recent blocks (sigma_realized).",
            },
            initialPoolLiquidity: {
              type: "number",
              description: "Pool liquidity (L = sqrt(k)) at schedule inception.",
            },
            currentPoolLiquidity: {
              type: "number",
              description: "Current live pool liquidity (L = sqrt(k)).",
            },
            poolPrice: {
              type: "number",
              description: "Live internal AMM pool price (y / x).",
            },
            oraclePrice: {
              type: "number",
              description: "External live Chainlink oracle price.",
            },
            maxSlippageBps: {
              type: "number",
              description: "Maximum permissible slippage in basis points.",
            },
            volSpikeMultiplier: {
              type: "number",
              description: "Multiplier trigger for volatility spike (default: 2.0).",
            },
            liquidityShockThreshold: {
              type: "number",
              description: "Percentage drop trigger for pool drain (default: 0.15 for 15%).",
            },
            maxDislocationBps: {
              type: "number",
              description: "Max permissible oracle dislocation in basis points (default: 100 bps).",
            },
          },
          required: [
            "currentTick",
            "totalTicks",
            "executedAmount",
            "remainingAmount",
            "realizedSlippageBps",
            "historicalVol",
            "realizedVol",
            "initialPoolLiquidity",
            "currentPoolLiquidity",
            "poolPrice",
            "oraclePrice",
            "maxSlippageBps",
          ],
        },
      },
    ],
  };
});

server.setRequestHandler(CallToolRequestSchema, async (request) => {
  if (request.params.name === "calculate_liquidation_schedule") {
    const args = request.params.arguments as any;
    const portfolioSize = Number(args.portfolioSize);
    const spotPrice = Number(args.spotPrice || 1.0);
    const confidenceInterval = Number(args.confidenceInterval || 0.95);
    const timeHorizonHours = Number(args.timeHorizonHours || 1.0);
    const timeSteps = Number(args.timeSteps);
    const historicalVol = Number(args.historicalVolWindow ?? args.volatility ?? 0.05);
    const poolLiquidity = args.poolLiquidity !== undefined ? Number(args.poolLiquidity) : undefined;
    const poolReserves = args.poolReserves ? {
      tokenReserve: Number(args.poolReserves.tokenReserve),
      quoteReserve: Number(args.poolReserves.quoteReserve),
    } : undefined;
    const maxSlicePctOfPool = args.maxSlicePctOfPool !== undefined ? Number(args.maxSlicePctOfPool) : 0.05;

    let lambda: number;
    let varDollars = 0;
    let cvarDollars = 0;

    if (args.riskAversion !== undefined && Number(args.riskAversion) > 0) {
      lambda = Number(args.riskAversion);
    } else {
      const varCalib = calibrateLambdaFromVaR({
        portfolioSize,
        spotPrice,
        historicalVol,
        timeHorizonHours,
        varBudgetDollars: args.varBudgetDollars !== undefined ? Number(args.varBudgetDollars) : undefined,
        confidenceInterval,
      });
      lambda = varCalib.lambda;
      varDollars = varCalib.varDollars;
      cvarDollars = varCalib.cvarDollars;
    }

    const trajectory = computeOptimalTrajectory({
      portfolioSize,
      timeSteps,
      timeHorizonHours,
      lambda,
      historicalVol,
      spotPrice,
      poolLiquidity,
      poolReserves,
      maxSlicePctOfPool,
    });

    return {
      content: [
        {
          type: "text",
          text: JSON.stringify(
            {
              status: "success",
              schedule: trajectory.schedule,
              cumulativeExecuted: trajectory.cumulativeExecuted,
              calibratedLambda: lambda,
              kappa: trajectory.kappa,
              eta: trajectory.eta,
              regime: trajectory.regime,
              halfLifeTicks: trajectory.halfLifeTicks,
              expectedSlippageUSD: trajectory.expectedSlippageUSD,
              captureVarianceUSD: trajectory.captureVarianceUSD,
              riskMetrics: {
                varDollars,
                cvarDollars,
                confidenceInterval,
              },
            },
            null,
            2
          ),
        },
      ],
    };
  }

  if (request.params.name === "evaluate_execution_health") {
    const args = request.params.arguments as any;
    const healthResult = evaluateExecutionHealth({
      currentTick: Number(args.currentTick),
      totalTicks: Number(args.totalTicks),
      executedAmount: Number(args.executedAmount),
      remainingAmount: Number(args.remainingAmount),
      realizedSlippageBps: Array.isArray(args.realizedSlippageBps) ? args.realizedSlippageBps.map(Number) : [],
      historicalVol: Number(args.historicalVol),
      realizedVol: Number(args.realizedVol),
      initialPoolLiquidity: Number(args.initialPoolLiquidity),
      currentPoolLiquidity: Number(args.currentPoolLiquidity),
      poolPrice: Number(args.poolPrice),
      oraclePrice: Number(args.oraclePrice),
      maxSlippageBps: Number(args.maxSlippageBps),
      volSpikeMultiplier: args.volSpikeMultiplier !== undefined ? Number(args.volSpikeMultiplier) : undefined,
      liquidityShockThreshold: args.liquidityShockThreshold !== undefined ? Number(args.liquidityShockThreshold) : undefined,
      maxDislocationBps: args.maxDislocationBps !== undefined ? Number(args.maxDislocationBps) : undefined,
    });

    // If re-optimization is recommended, compute revised remaining schedule
    let reoptimizedSchedule: number[] | undefined = undefined;
    const remainingTicks = Number(args.totalTicks) - Number(args.currentTick);
    if (healthResult.recommendedAction === 'REOPTIMIZE' && remainingTicks > 0 && Number(args.remainingAmount) > 0) {
      const revisedCalib = calibrateLambdaFromVaR({
        portfolioSize: Number(args.remainingAmount),
        spotPrice: Number(args.oraclePrice),
        historicalVol: Number(args.realizedVol),
        timeHorizonHours: Math.max(0.1, remainingTicks * 0.05),
      });

      const revisedTrajectory = computeOptimalTrajectory({
        portfolioSize: Number(args.remainingAmount),
        timeSteps: remainingTicks,
        lambda: revisedCalib.lambda,
        historicalVol: Number(args.realizedVol),
        spotPrice: Number(args.oraclePrice),
        poolLiquidity: Number(args.currentPoolLiquidity),
      });
      reoptimizedSchedule = revisedTrajectory.schedule;
    }

    return {
      content: [
        {
          type: "text",
          text: JSON.stringify(
            {
              status: healthResult.status,
              recommendedAction: healthResult.recommendedAction,
              triggers: healthResult.triggers,
              metrics: healthResult.metrics,
              details: healthResult.details,
              reoptimizedSchedule,
            },
            null,
            2
          ),
        },
      ],
    };
  }

  throw new Error(`Tool not found: ${request.params.name}`);
});

async function main() {
  const transport = new StdioServerTransport();
  await server.connect(transport);
  console.error("Agent Gateway MCP server running on stdio");
}

main().catch((error) => {
  console.error("Server error:", error);
});
