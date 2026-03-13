---
name: linear
description: Query or mutate Linear data during a Symphony Pi run. Use when a task requires raw Linear reads or writes such as comments, state transitions, attachments, or issue metadata.
---

# Linear

Use this skill for raw Linear operations during a Symphony Pi session.

## Primary tool

Prefer `linear_graphql` when Symphony Pi is managing the agent session. Symphony Pi injects that tool automatically for orchestrated runs and it reuses the service’s configured Linear credentials.

Prefer `sync_workpad` for large workpad comment updates. It lets the agent write the workpad to a local file and then create or update the Linear comment without pasting the full body back into prompt context.

If `linear_graphql` is unavailable, fall back to a configured Linear MCP server if the environment provides one.

## Tool input

```json
{
  "query": "query or mutation document",
  "variables": {
    "optional": "graphql variables object"
  }
}
```

## Rules

- Send one GraphQL operation per tool call.
- Treat a top-level `errors` array as a failed operation.
- Query only the fields you need.
- Resolve the internal issue id before broader follow-up mutations when possible.

## Common workflows

### Read an issue by id or identifier

```graphql
query IssueDetails($id: String!) {
  issue(id: $id) {
    id
    identifier
    title
    url
    description
    state {
      id
      name
      type
    }
    project {
      id
      name
    }
  }
}
```

### Inspect team states before changing status

```graphql
query IssueTeamStates($id: String!) {
  issue(id: $id) {
    team {
      states {
        nodes {
          id
          name
          type
        }
      }
    }
  }
}
```

### Update a comment

```graphql
mutation UpdateComment($id: String!, $body: String!) {
  commentUpdate(id: $id, input: { body: $body }) {
    success
  }
}
```
