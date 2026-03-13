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
import { isToolCallEventType } from "@mariozechner/pi-coding-agent";
import { Type } from "@sinclair/typebox";
import { readFile } from "node:fs/promises";
import { homedir } from "node:os";
import { basename, isAbsolute, join, normalize, relative, resolve, sep } from "node:path";

const LINEAR_GRAPHQL_PARAMS = Type.Object({
	query: Type.String({ description: "GraphQL query or mutation document to execute against Linear." }),
	variables: Type.Optional(
		Type.Record(Type.String(), Type.Unknown(), {
			description: "Optional GraphQL variables object.",
		}),
	),
});

const SYNC_WORKPAD_PARAMS = Type.Object({
	issue_id: Type.String({
		description: "Linear internal issue id for the workpad comment.",
	}),
	file_path: Type.String({
		description: "Path to a local markdown file whose contents become the workpad comment body.",
	}),
	comment_id: Type.Optional(
		Type.String({
			description: "Existing Linear comment id to update. Omit to create the workpad comment.",
		}),
	),
});

const DANGEROUS_BASH_PATTERNS = [
	/\brm\s+(-[A-Za-z]*[rRfF][A-Za-z]*|--recursive|--force)\b/i,
	/\bsudo\b/i,
	/\b(chmod|chown)\b[^\n\r]*\b777\b/i,
	/\bmkfs(?:\.\w+)?\b/i,
	/\bdd\b[^\n\r]*\bof=/i,
	/\b(shutdown|reboot|poweroff|halt)\b/i,
];

const SECRET_HOME_PATHS = [".ssh", ".aws", ".gnupg"];
const PROTECTED_BASENAMES = [".env", ".npmrc", ".pypirc"];
const PROTECTED_EXTENSIONS = [".pem", ".key"];

function expandHomePath(value: string): string {
	if (value === "~") return homedir();
	if (value.startsWith("~/")) return join(homedir(), value.slice(2));
	return value;
}

function normalizeToolPath(candidate: string, cwd: string): string {
	const cleaned = candidate.startsWith("@") ? candidate.slice(1) : candidate;
	const expanded = expandHomePath(cleaned);
	return isAbsolute(expanded) ? normalize(expanded) : resolve(cwd, expanded);
}

function isWithinWorkspace(candidate: string, cwd: string): boolean {
	const relativePath = relative(cwd, candidate);
	return relativePath === "" || (!relativePath.startsWith("..") && !isAbsolute(relativePath));
}

function hasProtectedBasename(candidate: string): boolean {
	const base = basename(candidate);
	return (
		PROTECTED_BASENAMES.includes(base) ||
		base.startsWith(".env.") ||
		PROTECTED_EXTENSIONS.some((suffix) => base.endsWith(suffix))
	);
}

function isProtectedPath(candidate: string): boolean {
	const normalizedPath = normalize(candidate);
	const home = homedir();
	const gitSegment = `${sep}.git${sep}`;

	if (normalizedPath === join(home, ".ssh") || normalizedPath.startsWith(join(home, ".ssh") + sep)) return true;
	if (normalizedPath === join(home, ".aws") || normalizedPath.startsWith(join(home, ".aws") + sep)) return true;
	if (normalizedPath === join(home, ".gnupg") || normalizedPath.startsWith(join(home, ".gnupg") + sep)) return true;

	if (normalizedPath.includes(gitSegment) || normalizedPath.endsWith(`${sep}.git`) || basename(normalizedPath) === ".git") return true;

	return hasProtectedBasename(normalizedPath);
}

function commandTouchesSecretHomePath(command: string): boolean {
	return SECRET_HOME_PATHS.some((segment) => command.includes(`~/${segment}`) || command.includes(`/${segment}`));
}

export default function symphonyExtension(pi: ExtensionAPI) {
	const bridgeUrl = process.env.SYMPHONY_TOOL_BRIDGE_URL;
	const safetyDisabled = process.env.SYMPHONY_PI_DISABLE_SAFETY === "1";

	if (!safetyDisabled) {
		pi.on("tool_call", async (event, ctx) => {
			if (isToolCallEventType("bash", event)) {
				const command = event.input.command ?? "";

				if (DANGEROUS_BASH_PATTERNS.some((pattern) => pattern.test(command))) {
					return {
						block: true,
						reason: "Blocked dangerous bash command by Symphony Pi safety policy.",
					};
				}

				if (commandTouchesSecretHomePath(command)) {
					return {
						block: true,
						reason: "Blocked bash command touching protected home-directory secrets.",
					};
				}
			}

			if (isToolCallEventType("read", event) || isToolCallEventType("write", event) || isToolCallEventType("edit", event)) {
				const resolvedPath = normalizeToolPath(event.input.path, ctx.cwd);

				if ((isToolCallEventType("write", event) || isToolCallEventType("edit", event)) && !isWithinWorkspace(resolvedPath, ctx.cwd)) {
					return {
						block: true,
						reason: "Blocked write outside the current workspace.",
					};
				}

				if (isProtectedPath(resolvedPath)) {
					return {
						block: true,
						reason: "Blocked access to a protected path by Symphony Pi safety policy.",
					};
				}
			}

			return undefined;
		});
	}

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

	pi.registerTool({
		name: "sync_workpad",
		label: "Sync Workpad",
		description:
			"Create or update the Linear workpad comment from a local markdown file. " +
			"Use this to keep large workpad bodies out of the active model context.",
		promptSnippet: "Sync the current Agent Workpad comment from a file in the workspace",
		promptGuidelines: [
			"Write or update the workpad in a local markdown file first, then call sync_workpad.",
			"Pass the Linear internal issue id as issue_id.",
			"If updating an existing workpad comment, also pass comment_id.",
		],
		parameters: SYNC_WORKPAD_PARAMS,

		async execute(_toolCallId, params, ctx) {
			if (!bridgeUrl) {
				throw new Error(
					"Symphony tool bridge not available. SYMPHONY_TOOL_BRIDGE_URL environment variable is not set.",
				);
			}

			const issueId = params.issue_id?.trim();
			const filePath = params.file_path?.trim();
			const commentId = params.comment_id?.trim();

			if (!issueId) {
				throw new Error("sync_workpad requires a non-empty `issue_id`.");
			}

			if (!filePath) {
				throw new Error("sync_workpad requires a non-empty `file_path`.");
			}

			const resolvedPath = normalizeToolPath(filePath, ctx.cwd);
			const body = (await readFile(resolvedPath, "utf8")).trimEnd();

			if (!body) {
				throw new Error(`sync_workpad file is empty: ${resolvedPath}`);
			}

			try {
				const response = await fetch(`${bridgeUrl}/sync_workpad`, {
					method: "POST",
					headers: { "Content-Type": "application/json" },
					body: JSON.stringify({
						issue_id: issueId,
						body,
						comment_id: commentId || undefined,
					}),
				});

				const bridgeBody = await response.json();

				if (!bridgeBody.success) {
					const errorMsg = bridgeBody.error || `Bridge returned HTTP ${response.status}`;
					throw new Error(errorMsg);
				}

				return {
					content: [{ type: "text" as const, text: JSON.stringify({ success: true }, null, 2) }],
					details: { success: true },
				};
			} catch (err: unknown) {
				const message = err instanceof Error ? err.message : String(err);
				throw new Error(`sync_workpad bridge request failed: ${message}`);
			}
		},
	});
}
