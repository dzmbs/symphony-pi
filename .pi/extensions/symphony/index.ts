/**
 * Symphony Pi Extension
 *
 * Provides the `linear_graphql` tool so the agent can perform raw Linear
 * GraphQL operations during a run, matching upstream Symphony behavior.
 *
 * The tool calls back to a local HTTP bridge owned by Elixir rather than
 * managing Linear credentials directly. The bridge URL is passed via the
 * SYMPHONY_TOOL_BRIDGE_URL environment variable.
 */

import type { ExtensionAPI } from "@mariozechner/pi-coding-agent";
import { Type } from "@sinclair/typebox";

const LINEAR_GRAPHQL_PARAMS = Type.Object({
	query: Type.String({ description: "GraphQL query or mutation document to execute against Linear." }),
	variables: Type.Optional(
		Type.Record(Type.String(), Type.Unknown(), {
			description: "Optional GraphQL variables object.",
		}),
	),
});

export default function symphonyExtension(pi: ExtensionAPI) {
	const bridgeUrl = process.env.SYMPHONY_TOOL_BRIDGE_URL;

	pi.registerTool({
		name: "linear_graphql",
		label: "Linear GraphQL",
		description:
			"Execute a raw GraphQL query or mutation against Linear using Symphony's configured auth. " +
			"Use this tool to read or write Linear data (issues, comments, state transitions, etc.).",
		promptSnippet: "Execute raw GraphQL queries/mutations against the Linear API",
		promptGuidelines: [
			"Use linear_graphql for any Linear data operations (reading issues, posting comments, transitioning states).",
			"Always provide a single GraphQL operation per call.",
			"Variables are optional but recommended for parameterized queries.",
		],
		parameters: LINEAR_GRAPHQL_PARAMS,

		async execute(_toolCallId, params) {
			if (!bridgeUrl) {
				throw new Error(
					"Symphony tool bridge not available. " + "SYMPHONY_TOOL_BRIDGE_URL environment variable is not set.",
				);
			}

			const query = params.query?.trim();
			if (!query) {
				throw new Error("linear_graphql requires a non-empty `query` string.");
			}

			const variables = params.variables ?? {};

			try {
				const response = await fetch(`${bridgeUrl}/linear_graphql`, {
					method: "POST",
					headers: { "Content-Type": "application/json" },
					body: JSON.stringify({ query, variables }),
				});

				const body = await response.json();

				if (!body.success) {
					const errorMsg = body.error || `Bridge returned HTTP ${response.status}`;
					return {
						content: [
							{
								type: "text" as const,
								text: JSON.stringify({ success: false, error: errorMsg, data: body.data ?? null }, null, 2),
							},
						],
						details: { success: false },
					};
				}

				return {
					content: [{ type: "text" as const, text: JSON.stringify(body.data, null, 2) }],
					details: { success: true },
				};
			} catch (err: unknown) {
				const message = err instanceof Error ? err.message : String(err);
				throw new Error(`linear_graphql bridge request failed: ${message}`);
			}
		},
	});
}
