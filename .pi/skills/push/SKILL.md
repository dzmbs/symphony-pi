---
name: push
description: Push the current branch safely and create or update the matching pull request. Use when asked to publish branch changes or open/update a PR.
---

# Push

Use this skill when the current branch is ready to publish.

## Prerequisites

- `gh` is installed.
- `gh auth status` succeeds for this repository.

## Workflow

1. Identify the current branch:

```bash
git branch --show-current
```

2. Run the repository’s required validation command from `AGENTS.md` or `README.md`.
   - In Symphony Pi itself, that is usually `make all` or a narrower command justified by scope.
3. Push the branch to `origin`:

```bash
git push -u origin HEAD
```

4. If the push is rejected because the remote moved:
   - use the `pull` skill
   - rerun validation
   - push again
5. Only use `--force-with-lease` when history was intentionally rewritten.
6. Ensure a PR exists:
   - create one if missing
   - update title/body if one already exists
   - if the branch is tied to a closed PR, create a new branch instead
7. If the repo has a PR template or validation command for PR bodies, follow it before finishing.
8. Return the PR URL.

## Notes

- Do not rewrite remotes or switch protocols to work around auth failures.
- Surface auth and permission errors directly.
