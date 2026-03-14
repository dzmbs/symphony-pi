---
name: symphony-pi-setup
description: Set up Symphony Pi for a repository by checking Pi/GitHub/Linear prerequisites, installing the Symphony Pi skill pack, and creating a correct WORKFLOW.md bootstrap. Use when a user asks to set up Symphony Pi for a repo or connect a repo to Linear for autonomous Pi runs.
---

# Symphony Pi Setup

Set up Symphony Pi for a target repository.

If the terminal `symphony` CLI is available, prefer:

```bash
./bin/symphony setup /path/to/target-repo
```

That command is the recommended onboarding path because it:

- prompts for `LINEAR_API_KEY` when missing and can save it to repo `.env`
- checks that `pi` is installed and offers to install it when missing
- fetches the real available models from Pi
- checks that the chosen Pi providers are authenticated before writing `WORKFLOW.md`
  - API-key providers can be filled during setup and saved to repo `.env`
  - OAuth providers are re-checked after `pi` -> `/login <provider>`
- tries to fetch Linear projects and lets you pick one interactively when that works
- falls back to manual project slug entry and shows the fetch error when that does not
- validates required Linear states when the project can be resolved
- installs the project-local Symphony Pi package
- writes `WORKFLOW.md`
- optionally writes a minimal `AGENTS.md`

Use this skill when you want the same setup flow from inside a Pi session or when you need to
adjust the generated files afterward.

## Preflight checks

Run these first and stop if any fail:

1. `gh auth status`
2. `ssh -T git@github.com` if the target repo uses SSH
3. `git remote get-url origin` inside the target repo

Notes:

- `./bin/symphony setup` can prompt for `LINEAR_API_KEY`; it does not have to be pre-exported.
- If `pi` is missing, `./bin/symphony setup` can offer to install it.

## Install Symphony Pi

Build the service from the Symphony Pi repo:

```bash
cd /path/to/symphony-pi
mix setup
mix build
```

## Prepare the target repo

1. Install the Symphony Pi skill pack:

```bash
cd /path/to/target-repo
pi install -l git:github.com/dzmbs/symphony-pi
```

2. Copy `WORKFLOW.md` from the Symphony Pi repo into the target repo.
3. If the repo needs project-level rules for interactive Pi work too, copy or adapt `AGENTS.md`.

## Patch WORKFLOW.md

Update at least:

- `tracker.project_slug`
- `workspace.root`
- `hooks.after_create`
- `pi.model` / `pi.thinking` if you want a non-default implementation model

Optional:

- add `auto_review` only if you want an internal review pass before human handoff
- otherwise leave it out and keep the default flow: implement, validate, hand off to `Human Review`
- use CLI runtime overrides when you want to experiment for one run without editing the committed workflow

Preferred bootstrap hook:

```yaml
hooks:
  after_create: |
    git clone --depth 1 "$SOURCE_REPO_URL" .
    # project-specific setup commands here
```

Why:

- `SOURCE_REPO_URL` is injected by Symphony Pi
- it preserves whether the target repo itself uses SSH or HTTPS
- it avoids hardcoded repo URL drift

Optional review block:

```yaml
auto_review:
  enabled: true
  model: openai/gpt-5.4
  thinking: medium
  max_rework_passes: 1
  fresh_session: true
```

Notes:

- configured implementation and review models are fetched from and validated against the local `pi` installation at startup
- the review pass is internal to Symphony Pi; it drives `Rework` vs `Human Review`, but does not yet post GitHub PR review comments automatically
- the review stage uses a fresh Pi session and a restricted review tool profile by default

## Linear workflow states

Make sure the Linear team for the target project includes:

- `Rework`
- `Human Review`
- `Merging`

## Launch

Run Symphony Pi from the Symphony Pi repo, pointing at the target repo workflow:

```bash
cd /path/to/symphony-pi
./bin/symphony /path/to/target-repo/WORKFLOW.md \
  --i-understand-that-this-will-be-running-without-the-usual-guardrails \
  --port 4050
```

Temporary runtime overrides for a single process:

```bash
./bin/symphony /path/to/target-repo/WORKFLOW.md \
  --i-understand-that-this-will-be-running-without-the-usual-guardrails \
  --pi-model anthropic/claude-opus-4-6 \
  --auto-review \
  --review-model openai/gpt-5.4
```

Use this when you want:

- normal checked-in workflow defaults for everyday runs
- a one-off stronger implementation model
- a one-off internal review pass for a risky change

## Verify

1. Open `http://127.0.0.1:4050`
2. Move one disposable Linear issue into an active state
3. Confirm:
   - a workspace is created
   - Pi launches
   - the issue appears in the dashboard
   - token/cost/runtime stats begin updating

## Notes

- If the target repo already uses SSH, that remains the best unattended push/PR setup.
- Symphony Pi stores Pi session data outside the repo clone by default, so target repos do not need `.symphony-pi/` in `.gitignore` for the standard setup.
