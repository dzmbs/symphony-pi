# Symphony Pi — Service Specification

Status: Draft v1

## 1. Overview

Symphony Pi is a long-running automation service that polls Linear for work, creates isolated
per-issue workspaces, and runs `pi-coding-agent` sessions to complete that work.

This document defines Symphony Pi's runtime model, configuration, and operator-facing service
contract.

## 2. Service Contract

### 2.1 Core Behavior

These layers define the expected service behavior:

- Linear polling and issue normalization
- Issue eligibility filtering and dispatch priority
- Deterministic per-issue workspaces with sanitized identifiers
- Workspace lifecycle hooks (`after_create`, `before_run`, `after_run`, `before_remove`)
- Continuation turns while issue remains in an active state
- Retry with exponential backoff and continuation retry after normal exit
- Active-run reconciliation (stall detection, terminal/non-active state transitions)
- Startup terminal workspace cleanup
- Workflow contract (`WORKFLOW.md` front matter + prompt body)
- Dynamic workflow reload
- Dispatch preflight validation
- Dashboard / JSON API / structured logging
- Per-state concurrency limits
- `Todo` blocker gating
- SSH worker support with per-host capacity limits
- In-agent `linear_graphql` tool for Linear operations during runs

### 2.2 Pi Runtime Model

- Pi runs as `pi --mode rpc`
- Elixir communicates with Pi over JSONL RPC on stdin/stdout
- Runtime configuration lives under `pi.*`
- Session persistence uses `--session-dir`
- `linear_graphql` is provided as a Pi extension tool
- Tool calls are surfaced through Pi's extension/runtime model

### 2.3 Pi Project Context

Symphony Pi follows Pi's normal project context conventions:

- repo guidance lives in `AGENTS.md`
- reusable task workflows live in `.pi/skills/`
- project-local extension code lives in `.pi/extensions/`

The service runtime explicitly loads its bundled `linear_graphql` extension source for orchestrated
Pi sessions. Separately, the repository ships a Pi package manifest so the skill pack can be
installed into other repos with `pi install`.

### 2.4 Out of Scope

- Prescribing one approval or sandbox policy for all environments
- Non-Pi runtime protocols
- Repo-local conventions from other implementations

## 3. Configuration

### 3.1 Workflow Front Matter Schema

Symphony Pi uses `WORKFLOW.md` for policy, configuration, and prompt content.

Top-level keys:

- `tracker` — Linear project/auth config
- `polling` — poll interval
- `workspace` — workspace root path
- `hooks` — lifecycle hooks
- `agent` — concurrency, max turns, retry backoff
- `worker` — SSH worker config
- `pi` — Pi runtime settings
- `server` — optional HTTP server
- `observability` — dashboard settings

### 3.2 Pi Runtime Settings (`pi`)

| Field            | Type    | Default                    | Description                              |
|------------------|---------|----------------------------|------------------------------------------|
| `command`        | string  | `"pi"`                     | Path to pi executable                    |
| `model`          | string  | null                       | Model pattern (`provider/id`)            |
| `thinking`       | string  | null                       | Thinking level (appended as `:thinking`) |
| `session_subdir` | string  | `".symphony-pi/session"`   | Per-workspace session storage path       |
| `turn_timeout_ms`| integer | `3600000` (1h)             | Max duration for one turn                |
| `read_timeout_ms`| integer | `5000`                     | Timeout for startup RPC responses        |
| `stall_timeout_ms`| integer| `300000` (5m)              | Stall detection threshold                |
| `extension_dir`  | string  | null                       | Path to Symphony Pi extension directory  |

### 3.3 Worker Settings (`worker`)

| Field                            | Type           | Default | Description                        |
|----------------------------------|----------------|---------|------------------------------------|
| `ssh_hosts`                      | list of string | `[]`    | SSH host destinations              |
| `max_concurrent_agents_per_host` | integer        | null    | Per-host capacity cap              |

When `ssh_hosts` is empty, all work runs locally.
When populated, the orchestrator selects hosts from the pool.

## 4. Execution Model

### 4.1 Local Worker

1. Elixir spawns `pi --mode rpc --session-dir <workspace>/<session_subdir>` with
   `cwd = <workspace_path>`.
2. Elixir sends a `prompt` command over stdin.
3. Pi streams events on stdout as JSONL.
4. Elixir normalizes Pi events into Symphony runtime updates.
5. On `agent_end`, the turn is complete.
6. If the issue remains active, Elixir sends another `prompt` (continuation) to the same Pi
   process.
7. On terminal completion or failure, Elixir sends `abort` and closes the port.

### 4.2 SSH Worker

1. Elixir selects an SSH host from `worker.ssh_hosts`.
2. Remote workspace creation checks whether the directory already exists and only reports
   `created?=true` when freshly created, so `after_create` hooks run exactly once.
3. Workspace lifecycle hooks execute on the remote host via SSH.
4. Pi is launched on the remote host via `SSH.start_port/3` in RPC mode.
5. SSH reverse port forwarding (`-R`) tunnels the tool bridge from the orchestrator to the
   worker, so the remote Pi extension can reach the bridge at `127.0.0.1:<port>`.
6. Elixir communicates with the remote Pi process through SSH-backed stdio transport.
7. The same session reuse and event normalization applies.
8. Workspace cleanup runs on the correct remote host.
9. When no specific host is recorded (e.g., startup cleanup), cleanup iterates all configured
   `worker.ssh_hosts` to avoid orphaning remote workspaces.

The SSH layer is a transport concern — the orchestration model is identical for local and SSH
workers.

### 4.3 Pi Session Lifecycle

- One Pi process per issue workspace per worker run.
- The process is reused across continuation turns within the same worker lifetime.
- Session persistence uses `--session-dir` so Pi can restore context across process restarts.
- After the worker run ends, the orchestrator may schedule a continuation retry; a new Pi process
  is started reusing the same session directory.

## 5. Linear Tooling

### 5.1 Requirement

Symphony Pi provides `linear_graphql` so the agent can perform raw Linear GraphQL operations during
a run.

### 5.2 Implementation

Symphony Pi provides `linear_graphql` as a **Pi extension tool**.

Default runtime extension source: `priv/pi/extensions/symphony/index.ts`.

Developer source copy: `.pi/extensions/symphony/` (repo-local).

Since Pi runs inside the issue workspace (not the symphony-pi repo), the extension is loaded
explicitly via the `--extension` (`-e`) CLI flag. The `pi.extension_dir` config can override
the default extension source with either a file path or an extension directory.

This explicit loading is for Symphony Pi's managed runtime sessions. The repository's Pi package
manifest exports the bundled skills, not the runtime bridge extension, so installing the package
into an unrelated repo does not inject a non-functional `linear_graphql` tool outside Symphony Pi.

The extension registers a custom tool named `linear_graphql` with:

- **Input**: `query` (string, required), `variables` (object, optional)
- **Output**: GraphQL response payload or error payload

### 5.3 Bridge Architecture

The extension calls back to a local HTTP bridge owned by Elixir:

1. Elixir starts a lightweight local HTTP endpoint (the "tool bridge") on an ephemeral port.
2. The bridge URL is passed to Pi via environment variable (`SYMPHONY_TOOL_BRIDGE_URL`).
3. The extension sends GraphQL requests to the bridge.
4. Elixir executes them through the existing `Linear.Client.graphql/3`.
5. The bridge returns the GraphQL response to the extension.

For SSH workers, SSH reverse port forwarding (`-R`) ensures the remote Pi process can reach the
bridge at `127.0.0.1:<bridge_port>` on the worker, transparently forwarding to the orchestrator.

Advantages:

- Single auth source of truth (Elixir owns Linear credentials)
- No duplicated Linear client logic in TypeScript
- Keeps tracker auth and policy in one place
- Works transparently over SSH via reverse port forwarding

### 5.4 Tool Contract

- `query` must be a non-empty string
- `variables` is optional; when present, must be a JSON object
- Transport success + no top-level GraphQL `errors` → success
- Top-level GraphQL `errors` → failure (preserves response body)
- Invalid input, missing auth, transport failure → failure with error payload

## 6. Event Normalization

Pi events are normalized into the same runtime update model the orchestrator expects:

| Pi Event                 | Normalized Event         |
|--------------------------|--------------------------|
| `agent_start`            | `:session_started`       |
| `agent_end`              | `:turn_completed`        |
| `message_start/update/end` | `:notification`        |
| `turn_start/end`         | `:notification`          |
| `tool_execution_*`       | `:notification`          |
| `auto_retry_end` (fail)  | `:turn_ended_with_error` |
| `auto_compaction_*`      | `:notification`          |
| `extension_error`        | `:notification`          |

Token usage is extracted from `agent_end` message payloads and `message_end` usage fields.

## 7. Runtime Policy

Pi runtime policy is expressed through:

- `pi.command` — the executable (can point to a wrapper script)
- `pi.model` / `pi.thinking` — model and reasoning controls
- `pi.session_subdir` — session persistence location
- Timeout settings (`turn_timeout_ms`, `read_timeout_ms`, `stall_timeout_ms`)
- Pi extension loading (project-local `.pi/extensions/`)
- Host-level controls (OS user, filesystem permissions, network policy)

Pi runs in a trusted local mode by default. For constrained environments, operators can:

- Use a wrapper command that applies OS-level restrictions
- Configure Pi extensions that gate or audit tool calls
- Restrict the workspace root filesystem

## 8. Test Coverage

### 8.1 Core Conformance

- Workflow/config parsing and dynamic reload
- Workspace lifecycle and safety invariants
- Linear client (candidate fetch, state refresh, pagination, blockers)
- Orchestrator dispatch, reconciliation, retry, stall detection
- Pi RPC client (launch, JSONL framing, event classification)
- Pi RPC backend (session lifecycle, turn execution, event normalization)
- Event normalizer (all Pi event types → Symphony update format)
- Token usage extraction and aggregation

### 8.2 Extension Conformance

- Worker config schema (ssh_hosts, per-host capacity)
- SSH host selection and capacity enforcement
- Remote workspace lifecycle (create, hooks, cleanup)
- Pi over SSH transport
- `linear_graphql` tool via extension bridge
- HTTP server / dashboard / JSON API

### 8.3 Live Integration

- Local Pi live e2e (real Linear + real Pi)
- SSH worker live e2e (real Linear + real Pi over SSH)

## 9. Acceptance Criteria

Symphony Pi meets its service contract when:

1. A team can run it as a long-lived work orchestration service with Pi as the runtime.
2. The default workflow can execute without asking humans for follow-up actions.
3. The agent can perform the Linear operations required by the workflow.
4. Local worker mode works.
5. SSH worker mode works.
6. Continuation turns reuse the same Pi session per issue workspace.
7. Live e2e passes in local Pi mode.
8. Live e2e passes in SSH worker Pi mode.
9. Docs describe Pi as the runtime and document the parity boundary.
