---
name: pull
description: Sync the current branch with the latest upstream branch using a merge-based update and resolve conflicts carefully. Use when the branch must catch up with origin/main or a push is rejected.
---

# Pull

Use this skill when the current branch needs to absorb remote changes without rebasing away history.

## Workflow

1. Confirm the current branch and inspect `git status`.
2. If the tree is dirty, either commit intended work first or stop and explain why the merge is unsafe.
3. Enable rerere if it is not already enabled:

```bash
git config rerere.enabled true
git config rerere.autoupdate true
```

4. Fetch latest refs:

```bash
git fetch origin
```

5. Fast-forward the remote feature branch if needed:

```bash
git pull --ff-only origin "$(git branch --show-current)"
```

6. Merge `origin/main` with clear conflict markers:

```bash
git -c merge.conflictstyle=zdiff3 merge origin/main
```

7. If conflicts occur:
   - inspect both sides before editing
   - resolve one file at a time
   - preserve intended behavior, not just syntax
   - verify no conflict markers remain with `git diff --check`
8. Stage the resolved files and complete the merge.
9. Run the repository’s required validation command from `AGENTS.md` or `README.md`.
10. Summarize the merge, especially any risky conflict decisions.
