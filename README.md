# Symphony Pi

This repository contains the current Elixir/OTP implementation of Symphony Pi: Symphony orchestration with `pi-coding-agent` as the runtime.

> [!WARNING]
> Symphony Pi is prototype software intended for evaluation only and is presented as-is.
> We recommend implementing your own hardened version based on `SPEC.md`.

Symphony Pi is derived from OpenAI Symphony and adapted to use `pi-coding-agent`.

Pi automatically reads project guidance from `AGENTS.md`, discovers project-local skills from
`.pi/skills/`, and auto-discovers project-local extensions from `.pi/extensions/`. Symphony Pi
ships all three so the repo works naturally with Pi tooling instead of relying on older harness
conventions.

## How it works

1. Polls Linear for candidate work
2. Creates a workspace per issue
3. Launches Pi in RPC mode inside the workspace
4. Sends a workflow prompt to Pi
5. Keeps Pi working on the issue until the work is done

If a claimed issue moves to a terminal state (`Done`, `Closed`, `Cancelled`, or `Duplicate`),
Symphony stops the active agent for that issue and cleans up matching workspaces.

## Before you start

For normal use, you need these tools on your machine:

- `git`
- `pi`

## Quick Start

For a new repository, the recommended path is:

```bash
curl -fsSL https://raw.githubusercontent.com/dzmbs/symphony-pi/main/install.sh | sh
symphony-pi setup /path/to/your-repo
```

This install path downloads a packaged Symphony Pi release with the Erlang runtime bundled, so end
users do not need to install Elixir, Erlang, or `mix`.

If you prefer to pin a specific release version, set `SYMPHONY_PI_VERSION` first:

```bash
export SYMPHONY_PI_VERSION=v0.1.0
curl -fsSL https://raw.githubusercontent.com/dzmbs/symphony-pi/main/install.sh | sh
```

The setup command does the first-pass onboarding for you:

- checks that the target path is a git repo with an `origin`
- prompts for `LINEAR_API_KEY` if it is missing and can save it to the repo `.env`
- checks that `pi` is installed and offers to install it when it is missing
- fetches the actual available models from your local Pi installation
- checks that the chosen Pi providers are actually authenticated before writing `WORKFLOW.md`
  - API-key providers can be filled in during setup and saved to repo `.env`
  - OAuth providers are re-checked after you complete `pi` -> `/login <provider>`
- tries to fetch Linear projects and lets you pick one interactively when that succeeds
- falls back to manual project slug entry with the fetch error shown when it does not
- validates required Linear states when the project can be resolved
- installs the Symphony Pi project-local Pi package into the target repo
- writes a working `WORKFLOW.md`
- optionally creates a minimal `AGENTS.md`
- prints the exact command to start Symphony Pi for that repo

The installed Pi package also includes reusable skills such as:

- `symphony-readiness` to improve a repo's agent legibility without forcing boilerplate
- `linear-ticket` to turn rough user input into Symphony-friendly Linear issues
- `linear`, `pull`, `push`, `commit`, and `land` for common orchestration tasks

Then start the service with the command it prints, create one small Linear issue in the configured
project, move it to `Todo`, and watch the dashboard at `http://127.0.0.1:4050`.

## How to use it

1. Make sure your codebase is set up to work well with agents: see
   [Harness engineering](https://openai.com/index/harness-engineering/).
2. Get a new personal token in Linear via Settings → Security & access → Personal API keys.
   If `LINEAR_API_KEY` is not already set, `symphony-pi setup` will prompt for it.
3. Run onboarding:

```bash
symphony-pi setup /path/to/your-repo
```

4. Customize the generated `WORKFLOW.md` only if your project needs something beyond the detected defaults.
   - When creating a workflow based on this repo, note that it depends on non-standard Linear
     issue statuses: "Rework", "Human Review", and "Merging". You can customize them in
     Team Settings → Workflow in Linear.
5. Follow the instructions below to install the required runtime dependencies and start the service.

## Install From Source

Use this path if you want to develop Symphony Pi itself.

You need Elixir `1.19.5` with OTP `28`.

We recommend using [mise](https://mise.jdx.dev/) to manage those versions. `mix` ships with
Elixir, so once Elixir is installed, `mix` is available too.

```bash
git clone https://github.com/dzmbs/symphony-pi
cd symphony-pi
mise trust
mise install
mise exec -- elixir --version
mise exec -- mix setup
mise exec -- mix build
mise exec -- mix install_cli
```

## Run

If you installed Symphony Pi with the release installer, run:

```bash
symphony-pi setup /path/to/your-repo
symphony-pi /path/to/your-repo/WORKFLOW.md \
  --i-understand-that-this-will-be-running-without-the-usual-guardrails \
  --port 4050
```

If you are running from source instead:

```bash
mise exec -- ./bin/symphony-pi ./WORKFLOW.md
```

## Configuration

Pass a custom workflow file path to `symphony-pi` when starting the service:

```bash
symphony-pi /path/to/custom/WORKFLOW.md
```

If no path is passed, Symphony defaults to `./WORKFLOW.md`.

Symphony Pi also auto-loads `.env` files from:

- the directory containing the active `WORKFLOW.md`
- the current working directory

Loaded values only fill missing environment variables; they do not override values already set in
the shell.

Optional flags:

- `--logs-root` tells Symphony to write logs under a different directory (default: `./log`)
- `--port` also starts the Phoenix observability service (default: disabled)
- `--pi-model` temporarily overrides `pi.model` for this Symphony Pi process
- `--pi-thinking` temporarily overrides `pi.thinking` for this Symphony Pi process
- `--auto-review` temporarily enables `auto_review`
- `--no-auto-review` temporarily disables `auto_review`
- `--review-model` temporarily overrides `auto_review.model`
- `--review-thinking` temporarily overrides `auto_review.thinking`

If you pass a repo path instead of a workflow file path and that repo does not contain
`WORKFLOW.md`, Symphony Pi will tell you to run `symphony-pi setup /path/to/repo` first.

The `WORKFLOW.md` file uses YAML front matter for configuration, plus a Markdown body used as the
agent session prompt.

Minimal example:

```md
---
tracker:
  kind: linear
  project_slug: "..."
workspace:
  root: ~/code/workspaces
hooks:
  after_create: |
    git clone --depth 1 "$SOURCE_REPO_URL" .
agent:
  max_concurrent_agents: 10
  max_turns: 20
agent_runtime:
  backend: pi
pi:
  command: pi
---

You are working on a Linear issue {{ issue.identifier }}.

Title: {{ issue.title }} Body: {{ issue.description }}
```

Notes:

- If a value is missing, defaults are used.
- `agent_runtime.backend` is Pi-only in this repo and defaults to `pi`.
- `pi.command` defaults to `pi`.
- `pi.session_subdir` defaults to `.symphony-pi/session`, but Symphony stores that default in a
  sidecar directory next to the workspace clones instead of inside the repo checkout itself, so
  target repos do not need `.symphony-pi/` in `.gitignore` just to stay clean.
- `pi.extension_dir` optionally overrides the shipped Symphony Pi extension source. By default,
  Symphony loads its bundled `linear_graphql` extension automatically.
- `auto_review` is optional and disabled by default.
- When enabled, Symphony Pi runs a fresh review pass after the issue is
  moved to `Human Review`. If the reviewer asks for changes, Symphony Pi moves the issue back to
  `Rework`, performs a focused rework pass, and can review again before final handoff.
- `auto_review.model` and `auto_review.thinking` override the base `pi` runtime for the review
  stage only. Configured implementation and review models are validated against the local `pi`
  installation at CLI startup.
- `auto_review.max_rework_passes` limits how many automated fix/review loops Symphony Pi will do
  before leaving the issue in `Rework`.
- CLI runtime overrides take precedence over `WORKFLOW.md` for the current process only. This is
  useful for experimentation or one-off higher-quality runs without editing committed workflow files.
- The review stage uses a fresh Pi session by default and a restricted review tool profile instead
  of a full-power implementation session.
- The bundled extension also provides `sync_workpad`, which updates the Linear workpad comment
  from a local markdown file so large workpad bodies do not need to be pasted back into model
  context every turn. If the current `## Agent Workpad` comment already exists, Symphony Pi will
  update it automatically; otherwise it creates one.
- Symphony Pi applies a default extension safety policy during orchestrated runs:
  - blocks obviously dangerous bash commands such as `rm -rf`, `sudo`, `mkfs`, and `dd ... of=`
  - blocks writes outside the current workspace
  - blocks access to protected paths such as `.git/`, `.env`, `~/.ssh`, `~/.aws`, and key files
- Set `SYMPHONY_PI_DISABLE_SAFETY=1` only if you intentionally want to disable those guardrails.
- `agent.max_turns` caps how many back-to-back Pi prompts Symphony will run in a single agent
  invocation when a turn completes normally but the issue is still in an active state. Default: `20`.
- If the Markdown body is blank, Symphony uses a default prompt template that includes the issue
  identifier, title, and body.
- Use `hooks.after_create` to bootstrap a fresh workspace. For a Git-backed repo, you can run
  `git clone ... .` there, along with any other setup commands you need.
- Workspace hooks automatically receive:
  - `SOURCE_REPO_URL` as the target repo's current `origin` URL
  - `SOURCE_REPO_SSH_URL` as an SSH form when it can be derived
  - `SOURCE_REPO_HTTPS_URL` as an HTTPS form when it can be derived
- The clean default is `git clone --depth 1 "$SOURCE_REPO_URL" .`, which preserves whether the
  target repo itself uses SSH or HTTPS and avoids manual remote surgery in generated workspaces.
- If a hook needs `mise exec` inside a freshly cloned workspace, trust the repo config and fetch
  the project dependencies in `hooks.after_create` before invoking `mise` later from other hooks.
- `tracker.api_key` reads from `LINEAR_API_KEY` when unset or when value is `$LINEAR_API_KEY`.
- For path values, `~` is expanded to the home directory.
- For env-backed path values, use `$VAR`. `workspace.root` resolves `$VAR` before path handling.

```yaml
tracker:
  api_key: $LINEAR_API_KEY
workspace:
  root: $SYMPHONY_WORKSPACE_ROOT
hooks:
  after_create: |
    git clone --depth 1 "$SOURCE_REPO_URL" .
pi:
  command: $PI_BIN
  model: anthropic/claude-sonnet-4-5
  thinking: high
  extension_dir: $SYMPHONY_PI_EXTENSION_DIR
```

- If `WORKFLOW.md` is missing or has invalid YAML at startup, Symphony does not boot.
- If a later reload fails, Symphony keeps running with the last known good workflow and logs the
  reload error until the file is fixed.
- `server.port` or CLI `--port` enables the optional Phoenix LiveView dashboard and JSON API at
  `/`, `/api/v1/state`, `/api/v1/<issue_identifier>`, and `/api/v1/refresh`.

## Pi Project Context

Symphony Pi uses Pi's normal project discovery model:

- `AGENTS.md` for repo-specific coding rules and conventions
- `.pi/skills/` for reusable task workflows such as `commit`, `pull`, `push`, `land`, and `linear`
- `.pi/extensions/` for project-local extensions

This repo ships:

- `AGENTS.md` for contributor and agent rules
- `.pi/skills/` for Pi-native skill definitions
- `.pi/extensions/symphony/index.ts` for the development copy of the `linear_graphql` extension used by Symphony Pi
- `.pi/skills/symphony-pi-setup/` for guided onboarding into another repo

The runtime service itself loads the bundled extension source from `priv/pi/extensions/symphony/`
when launching Pi in orchestration mode. Installing the Pi package from this repo is mainly for
sharing the skills, not for injecting the runtime bridge into unrelated interactive sessions.

## Optional Auto Review

By default, Symphony Pi runs this flow:

- pick a Linear issue
- implement and validate
- hand off to `Human Review`

That default flow uses the implementation runtime configured under `pi:` in `WORKFLOW.md`.

If you want an extra internal quality gate before the human sees the handoff, enable
`auto_review` in `WORKFLOW.md`:

```yaml
auto_review:
  enabled: true
  model: openai/gpt-5.4
  thinking: medium
  max_rework_passes: 1
  fresh_session: true
```

Behavior:

- implementation still runs with the base `pi` config
- once work reaches `Human Review`, Symphony Pi runs a fresh internal review pass
- if review passes, the ticket stays in `Human Review`
- if review requests changes, Symphony Pi moves the ticket to `Rework`, performs a focused rework pass, and can review again
- the review verdict currently drives Symphony Pi's internal `Rework`/`Human Review` loop; it does
  not yet post formal GitHub PR review comments on your behalf

If you want to experiment without editing `WORKFLOW.md`, use process-level overrides:

```bash
symphony-pi /path/to/WORKFLOW.md \
  --pi-model anthropic/claude-opus-4-6 \
  --auto-review \
  --review-model openai/gpt-5.4
```

Those flags only affect the current Symphony Pi process.

## Runtime Safety

Symphony Pi enables a minimal default safety layer in its bundled Pi extension:

- blocks obviously dangerous bash commands
- blocks writes outside the active workspace
- blocks access to common secret and protected paths

This is intentionally simple and non-interactive. It is meant to prevent the most common foot-guns
in unattended runs without introducing approval prompts.

If you explicitly need unrestricted behavior for debugging, set:

```bash
export SYMPHONY_PI_DISABLE_SAFETY=1
```

### Install Skills Into Another Repo

Recommended:

```bash
cd /path/to/your-repo
pi install -l git:github.com/dzmbs/symphony-pi
```

That adds Symphony Pi's skill pack to the project's Pi settings, using the `package.json` manifest
in this repo.

Alternative:

- copy `.pi/skills/` into your target repo
- copy or adapt `AGENTS.md` if you want the same repo-level instructions

As with any Pi skills package, review the skill contents before installing them into a trusted repo.

Pi discovers project-local skills from `.pi/skills/` and project `AGENTS.md` automatically.

## Web dashboard

The observability UI now runs on a minimal Phoenix stack:

- LiveView for the dashboard at `/`
- JSON API for operational debugging under `/api/v1/*`
- Bandit as the HTTP server
- Phoenix dependency static assets for the LiveView client bootstrap

## Project Layout

- `lib/`: application code and Mix tasks
- `test/`: ExUnit coverage for runtime behavior
- `docs/`: public and development documentation
- `.pi/skills/`: Pi skill pack shipped with the repo
- `.pi/extensions/`: development copy of the Symphony Pi extension source
- `AGENTS.md`: repo-level guidance automatically loaded by Pi
- `package.json`: Pi package manifest for installing the skill pack into other repos
- `WORKFLOW.md`: in-repo workflow contract used by local runs

## Testing

```bash
make all
```

Run the real external end-to-end test only when you want Symphony to create disposable Linear
resources and launch a real Pi RPC session:

```bash
export LINEAR_API_KEY=...
make e2e
```

Optional environment variables:

- `SYMPHONY_LIVE_LINEAR_TEAM_KEY` defaults to `SYME2E`
- `SYMPHONY_LIVE_PI_COMMAND` defaults to `pi`
- `SYMPHONY_LIVE_SSH_WORKER_HOST` enables the real SSH-worker live test
- `SYMPHONY_LIVE_REMOTE_PI_COMMAND` overrides the Pi command on the remote worker
- `SYMPHONY_LIVE_SSH_WORKSPACE_ROOT` overrides the default remote workspace root

`make e2e` covers up to three live scenarios:

- one local Pi turn
- one real continuation/session-reuse flow
- one SSH worker flow when `SYMPHONY_LIVE_SSH_WORKER_HOST` is set

Unlike upstream Symphony, Symphony Pi does not ship a Docker-backed SSH worker fallback. The SSH
live test targets a real host with `pi` installed.

## Git Auth

The clean default is to let Symphony Pi preserve whatever remote style the target repo already
uses:

- use `git clone --depth 1 "$SOURCE_REPO_URL" .` in `hooks.after_create`
- Symphony Pi injects `SOURCE_REPO_URL`, `SOURCE_REPO_SSH_URL`, and `SOURCE_REPO_HTTPS_URL`
- workspaces inherit the target repo's current `origin` instead of hardcoding a separate clone URL

If your target repo already uses SSH, that remains the best unattended push/PR setup because it
avoids HTTPS credential drift inside per-issue workspaces. If the repo uses HTTPS, Symphony Pi
will preserve that too; you no longer need to rewrite workspace remotes manually just to match the
bootstrap clone.

The live test creates a temporary Linear project and issue, writes a temporary `WORKFLOW.md`,
runs a real agent turn, verifies the workspace side effect, requires Pi to comment on and close
the Linear issue, then marks the project completed so the run remains visible in Linear.
`make e2e` fails fast with a clear error if `LINEAR_API_KEY` is unset.

## FAQ

### Why Elixir?

Elixir is built on Erlang/BEAM/OTP, which is great for supervising long-running processes. It has an
active ecosystem of tools and libraries. It also supports hot code reloading without stopping
actively running subagents, which is very useful during development.

### What's the easiest way to set this up for my own codebase?

Run:

```bash
symphony-pi setup /path/to/your-repo
```

That is the recommended onboarding path now.

## License

This project is licensed under the [Apache License 2.0](LICENSE).
