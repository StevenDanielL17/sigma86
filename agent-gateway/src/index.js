import { Server } from "@modelcontextprotocol/sdk/server/index.js";
import { StdioServerTransport } from "@modelcontextprotocol/sdk/server/stdio.js";
import { CallToolRequestSchema, ListToolsRequestSchema, } from "@modelcontextprotocol/sdk/types.js";
const server = new Server({
    name: "sigma86-agent-gateway",
    version: "1.0.0",
}, {
    capabilities: {
        tools: {},
    },
});
server.setRequestHandler(ListToolsRequestSchema, async () => {
    return {
        tools: [
            {
                name: "calculate_liquidation_schedule",
                description: "Calculates an Almgren-Chriss liquidation schedule for a given portfolio.",
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
                    },
                    required: ["portfolioSize"],
                },
            },
        ],
    };
});
server.setRequestHandler(CallToolRequestSchema, async (request) => {
    if (request.params.name === "calculate_liquidation_schedule") {
        // Dummy implementation to be replaced with Almgren-Chriss quantitative math
        return {
            content: [
                {
                    type: "text",
                    text: JSON.stringify({ status: "dummy schedule generated" }),
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
//# sourceMappingURL=index.js.map