---
name: symphony-readiness
description: Make a repository more agent-friendly and Symphony Pi-friendly without forcing a rigid template. Use when asked to prepare a repo for autonomous agent work, improve repo legibility, add missing docs, or align a codebase with harness-engineering principles.
---

# Symphony Readiness

Use this skill to improve a repository so Symphony Pi and Pi agents can work in it reliably.

This skill is based on the harness-engineering principles in
`references/openai-harness-engineering.md`:

- humans steer, agents execute
- repository knowledge should be the system of record
- give agents a map, not a giant manual
- prefer progressive disclosure over one huge instruction file
- enforce invariants mechanically where possible
- improve legibility of product, architecture, validation, and observability

The goal is not to force every repo into the same shape. The goal is to make the repo easier for
agents to understand and operate in.

## Default posture

- Prefer additive, minimal improvements over sweeping rewrites.
- Do not replace good existing docs just to match Symphony Pi conventions.
- Reuse existing docs, commands, and repo structure when they are already clear.
- If the repo already has strong guidance, tighten gaps instead of generating boilerplate.
- Favor short, high-signal docs over large generic manuals.

## What “good enough” looks like

A repo is Symphony-friendly when an agent can discover, in-repo:

- what the system is
- how the repo is organized
- how to validate a change
- where dangerous or special areas are
- what standards must be preserved
- where product/domain knowledge lives

## First pass checklist

Inspect these before editing anything:

1. Root docs:
   - `README.md`
   - `AGENTS.md`
   - `WORKFLOW.md`
   - `docs/`
2. Validation surface:
   - `Makefile`
   - package/build scripts
   - CI workflow files
3. Repo structure:
   - main app directories
   - test directories
   - generated/vendor/third-party code
4. Existing agent resources:
   - `.pi/skills/`
   - `.pi/extensions/`
   - repo-local templates/checklists

## What to improve first

Prioritize the smallest changes with the biggest effect on agent reliability:

### 1. AGENTS.md as a map

If `AGENTS.md` is missing or weak, create or improve it so it acts as a table of contents, not an
encyclopedia.

It should answer:

- what this repo is
- major directories and domains
- required validation commands
- important invariants
- where deeper docs live

Avoid:

- giant policy dumps
- duplicated README content
- stale commands copied from old workflows

### 2. Validation clarity

Agents need one obvious way to prove work.

If validation is unclear, add or tighten:

- `make test`, `make lint`, or equivalent
- README validation instructions
- AGENTS.md references to the main validation commands
- short notes for slow, flaky, or optional validation paths

### 3. Architecture map

If the repo is non-trivial and lacks structure docs, add a short architecture map or point to an
existing source of truth.

Good targets:

- root `ARCHITECTURE.md`
- `docs/ARCHITECTURE.md`
- domain index in `docs/`

Keep it short and navigational.

### 4. Product/domain legibility

If important product or workflow knowledge only lives in chat/history/human heads, create small
repo-local docs that make the system legible to future agent runs.

Examples:

- onboarding flow
- state machine description
- deployment expectations
- domain glossary
- critical business rules

### 5. Mechanical guardrails

If the repo depends on important invariants, prefer enforcing them in code/tooling rather than only
describing them in prose.

Examples:

- lint rules
- CI checks
- schema/type checks
- file size or layering checks
- generated-file protections

Do not invent heavy tooling unless the repo clearly benefits from it.

## Suggested output changes

Depending on what is missing, good outputs from this skill are:

- create or improve `AGENTS.md`
- add a short architecture doc
- add a focused repo-map doc in `docs/`
- tighten README run/validation instructions
- add missing validation targets/scripts
- add small repo-specific skills for repeated tasks
- document dangerous/generated/non-editable paths

## What not to do

- Do not generate a giant doc tree just because the repo has a `docs/` folder.
- Do not replace existing good docs with Symphony-flavored boilerplate.
- Do not force OpenAI’s exact repository layout onto unrelated projects.
- Do not add “AI slop” documents with generic advice and no repo-specific value.
- Do not create fake architecture certainty; if something is unclear, say so and document only what
  you can verify from the codebase.

## Recommended workflow

1. Inspect current docs and validation surface.
2. Identify the 2-4 highest-value gaps.
3. Make minimal, concrete repo-local improvements.
4. Keep changes verifiable and specific to the actual codebase.
5. Summarize:
   - what was already good
   - what was added or tightened
   - what still requires human judgment or product knowledge

## Completion bar

This skill is successful when the repo becomes easier for an agent to navigate and validate without
becoming cluttered with generic documentation.
