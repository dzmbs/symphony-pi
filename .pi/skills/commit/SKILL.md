---
name: commit
description: Create a clean git commit for the current change set. Use when asked to commit, prepare a commit message, or finalize already-reviewed work.
---

# Commit

Use this skill when the task is to create one intentional commit from the current worktree.

## Goals

- Match the commit message to the actual staged diff.
- Summarize both what changed and why.
- Avoid staging unrelated files.

## Workflow

1. Review the session context to understand the intended change.
2. Inspect the worktree with `git status`, `git diff`, and `git diff --staged`.
3. Stage only the intended files.
   - Do not use `git add -A` or `git add .`.
   - If unrelated files are present, leave them unstaged or ask before including them.
4. Check for junk files before committing:
   - build outputs
   - logs
   - temp files
   - editor artifacts
5. Follow repo-specific commit conventions from `AGENTS.md` if present.
6. Write a concise imperative subject line.
7. Add a short body covering:
   - summary of changes
   - rationale or trade-offs
   - validation run, or why validation was not run
8. Use `git commit -F <file>` or a here-doc so the message formatting stays intact.

## Template

```text
<type>(<scope>): <short summary>

Summary:
- <what changed>
- <what changed>

Rationale:
- <why>
- <why>

Validation:
- <command or "not run (reason)">
```
