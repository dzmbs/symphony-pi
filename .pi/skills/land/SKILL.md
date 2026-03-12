---
name: land
description: Merge a PR end to end by watching feedback, fixing failures, and squash-merging when checks are green. Use when a ticket is in Merging or a PR must be shepherded to completion.
---

# Land

Use this skill when the branch already has a PR and the goal is to get it merged safely.

## Goals

- Keep the PR conflict-free with `main`.
- Ensure required checks and validation are green.
- Resolve or explicitly answer review feedback before merging.
- Stay on the task until the PR is merged or a real blocker is found.

## Workflow

1. Identify the PR for the current branch:

```bash
gh pr view --json number,title,body,url,state
```

2. Confirm the working tree is clean.
3. If local changes are present, use the `commit` skill and then the `push` skill before continuing.
4. Check mergeability and review status:

```bash
gh pr view --json mergeable,reviews
gh pr checks
```

5. If the branch is stale or conflicting, use the `pull` skill, rerun validation, and publish again with the `push` skill.
6. Review all actionable feedback:
   - top-level PR comments
   - inline review comments
   - automated review comments if your repo uses them
7. For each actionable comment, choose one of:
   - accept and fix
   - clarify
   - push back with a concrete rationale
8. If checks fail:
   - inspect the failing logs
   - fix the problem
   - rerun validation
   - commit and push
9. When checks are green and feedback is resolved, squash-merge the PR:

```bash
gh pr merge --squash --delete-branch
```

10. Confirm the PR merged successfully and report the result.

## Guardrails

- Do not merge while unresolved review feedback remains.
- Do not enable auto-merge unless the user explicitly asks for it.
- If feedback conflicts with the user’s intent and the correct choice is unclear, stop and ask.
