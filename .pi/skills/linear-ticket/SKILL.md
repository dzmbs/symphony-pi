---
name: linear-ticket
description: Turn rough user input into a high-quality Linear issue that Symphony Pi can execute reliably. Use when asked to draft, refine, or create Linear tickets from loose product or engineering requests.
---

# Linear Ticket

Use this skill to produce Linear issues that are clear, bounded, and agent-executable.

The goal is not just to write a nicer ticket. The goal is to write a ticket that Symphony Pi can
pick up and execute with minimal ambiguity.

## Default posture

- Prefer clarity over completeness theater.
- Keep scope narrow enough that one agent run can finish it.
- Separate implementation work from follow-up ideas.
- Add explicit validation requirements whenever they are known.
- If the request is too vague, turn it into a smaller, concrete issue instead of fabricating detail.

## Ticket quality bar

A strong Symphony-ready Linear issue should include:

- a concrete title
- the problem or intent
- clear scope
- explicit non-goals when useful
- acceptance criteria
- validation or test plan
- references, links, screenshots, or examples when available

## Recommended ticket structure

Use this shape unless the repo/team already has a stronger issue template:

```md
## Problem
<what is wrong or what needs to exist>

## Scope
- <in scope>
- <in scope>

## Non-goals
- <out of scope>

## Acceptance Criteria
- [ ] <observable outcome>
- [ ] <observable outcome>

## Validation
- [ ] <test command>
- [ ] <manual flow>

## References
- <PR, doc, screenshot, issue, error log, etc.>
```

## How to derive a good ticket from rough input

### If the input is feature-like

Capture:

- user-visible behavior
- constraints
- rollout assumptions
- how to know it works

### If the input is bug-like

Capture:

- current bad behavior
- expected behavior
- reproduction signal
- validation that proves the fix

### If the input is refactor-like

Capture:

- motivation
- exact target area
- invariants that must not change
- proof of no regression

### If the input is research-like

Do not disguise research as implementation.

Write a research ticket with output expectations like:

- decision memo
- comparison table
- prototype
- follow-up implementation ticket(s)

## Scope control rules

- One ticket should generally map to one coherent change.
- If the request obviously contains multiple deliverables, split it.
- If there are meaningful follow-ups, create separate follow-up tickets instead of hiding them in
  the same scope.
- If a detail is unknown but necessary, record it as a question or assumption instead of inventing
  certainty.

## Validation rules

Validation should be as concrete as possible.

Good examples:

- `mix test test/foo/bar_test.exs`
- `cargo test crate_name::specific_case`
- `npm test -- checkout-summary`
- manual flow: “Create an order with tax and verify total matches line items”

Weak examples:

- “test it”
- “make sure it works”
- “QA”

## When creating the issue in Linear

If Linear access is available through `linear_graphql` or Linear MCP:

1. Draft the ticket text first.
2. Review for scope tightness and missing validation.
3. Create the issue only after the text is strong.
4. Put the issue into the correct project/team.
5. Prefer `Backlog` or `Todo` unless the user explicitly wants another state.

## Questions to resolve before creation

If the user input is underspecified, try to resolve these:

- what is the actual problem?
- what is the exact outcome?
- what is in scope vs out of scope?
- how will we validate it?
- are there links or existing incidents/PRs/docs to attach?

If answers are unavailable, write a smaller, more honest ticket instead of padding with guesses.

## Completion bar

This skill is successful when the resulting issue is something Symphony Pi can execute without
needing a human to reinterpret the task halfway through.
