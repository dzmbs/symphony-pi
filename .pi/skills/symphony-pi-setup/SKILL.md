---
name: symphony-pi-setup
description: Set up Symphony Pi for a repository by checking Pi/GitHub/Linear prerequisites, installing the Symphony Pi skill pack, and creating a correct WORKFLOW.md bootstrap. Use when a user asks to set up Symphony Pi for a repo or connect a repo to Linear for autonomous Pi runs.
---

# Symphony Pi Setup

Set up Symphony Pi for a target repository.

## Preflight checks

Run these first and stop if any fail:

1. `pi --version`
2. `gh auth status`
3. `ssh -T git@github.com` if the target repo uses SSH
4. `test -n "$LINEAR_API_KEY" && echo set || echo missing`
5. `git remote get-url origin` inside the target repo

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

## Verify

1. Open `http://127.0.0.1:4050`
2. Move one disposable Linear issue into an active state
3. Confirm:
   - a workspace is created
   - Pi launches
   - the issue appears in the dashboard
   - token/cost/runtime stats begin updating

## Notes

- Prefer SSH remotes for unattended push/PR workflows.
- Symphony Pi stores Pi session data outside the repo clone by default, so target repos do not need `.symphony-pi/` in `.gitignore` for the standard setup.
