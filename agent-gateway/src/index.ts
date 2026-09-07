import { Server } from "@modelcontextprotocol/sdk/server/index.js";
import { StdioServerTransport } from "@modelcontextprotocol/sdk/server/stdio.js";
import {
  CallToolRequestSchema,
  ListToolsRequestSchema,
} from "@modelcontextprotocol/sdk/types.js";

const server = new Server(
  {
    name: "sigma86-agent-gateway",
    version: "1.0.0",
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
        description: "Calculates an Almgren-Chriss liquidation schedule for a given portfolio adjusted for CPMM convex slippage.",
        inputSchema: {
          type: "object",
          properties: {
            portfolioSize: {
              type: "number",
              description: "The total size of the portfolio to liquidate.",
            },
            riskAversion: {
              type: "number",
              description: "The risk aversion parameter.",
            },
            poolLiquidity: {
              type: "number",
              description: "The pool liquidity parameter (x).",
            },
            timeSteps: {
              type: "number",
              description: "The number of time steps (N).",
            },
            volatility: {
              type: "number",
              description: "The price volatility.",
            }
          },
          required: ["portfolioSize", "riskAversion", "poolLiquidity", "timeSteps", "volatility"],
        },
      },
    ],
  };
});

server.setRequestHandler(CallToolRequestSchema, async (request) => {
  if (request.params.name === "calculate_liquidation_schedule") {
    const args = request.params.arguments as any;
    const { portfolioSize, riskAversion, poolLiquidity, timeSteps, volatility } = args;

    // Almgren-Chriss math adjusted for DeFi AMMs using CPMM convex slippage (dx / (x + dx))
    // We approximate the trade sizes over the time steps.
    const trades: number[] = [];
    let remaining = portfolioSize;
    
    // Simplistic discrete approximation for the schedule:
    // We want to balance risk (volatility * time) against slippage (dx / (x+dx)).
    // For a rigorous approach, we typically define a decay schedule based on hyperbolic sine (sinh).
    // kappa = sqrt( riskAversion * volatility^2 / (liquidity_impact_factor) )
    // In CPMM, price impact is convex. We approximate the linear impact coefficient eta ~ 1 / poolLiquidity.
    const eta = 1 / poolLiquidity; 
    
    // Prevent division by zero
    const variance = volatility * volatility;
    const kappa = Math.sqrt((riskAversion * variance) / (eta || 1e-9));

    // If kappa is extremely small (risk neutral), we just divide evenly (TWAP).
    if (kappa < 1e-6) {
        const stepSize = portfolioSize / timeSteps;
        for (let i = 0; i < timeSteps; i++) {
            trades.push(stepSize);
        }
    } else {
        // Almgren-Chriss optimal trajectory:
        // x_j = X * sinh(kappa * (T - t_j)) / sinh(kappa * T)
        // trade_j = x_{j-1} - x_j
        const T = timeSteps;
        for (let i = 1; i <= timeSteps; i++) {
            const t_prev = i - 1;
            const t_curr = i;
            let x_prev = 0, x_curr = 0;
            // Overflow guard: sinh(kappa*T) -> Infinity for large kappa*T, switch to exp decay
            if (kappa * T > 500) {
                x_prev = portfolioSize * Math.exp(-kappa * t_prev);
                x_curr = portfolioSize * Math.exp(-kappa * t_curr);
            } else {
                x_prev = portfolioSize * (Math.sinh(kappa * (T - t_prev)) / Math.sinh(kappa * T));
                x_curr = portfolioSize * (Math.sinh(kappa * (T - t_curr)) / Math.sinh(kappa * T));
            }
            let tradeSize = x_prev - x_curr;
            trades.push(tradeSize);
        }
    }

    return {
      content: [
        {
          type: "text",
          text: JSON.stringify({ status: "success", schedule: trades }),
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
