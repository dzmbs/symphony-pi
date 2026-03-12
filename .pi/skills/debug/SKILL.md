---
name: debug
description: Investigate Symphony Pi runs that stall, retry repeatedly, or fail unexpectedly by tracing issue and session identifiers through the logs.
---

# Debug

Use this skill when Symphony Pi itself is misbehaving.

## Main log sources

- `log/symphony.log`
- rotated files under `log/symphony.log*`

## Correlation keys

- `issue_identifier`
- `issue_id`
- `session_id`

## Quick triage

1. Search by ticket key first:

```bash
rg -n "issue_identifier=ABC-123" log/symphony.log*
```

2. If needed, narrow by Linear UUID:

```bash
rg -n "issue_id=<uuid>" log/symphony.log*
```

3. Trace one session end to end:

```bash
rg -n "session_id=<session-id>" log/symphony.log*
```

4. Focus on retries, stalls, and abnormal exits:

```bash
rg -n "stalled|retry|turn_failed|turn_timeout|ended with error|Agent task exited" log/symphony.log*
```

## Notes

- Prefer `rg` over `grep`.
- Check rotated logs before assuming the evidence is missing.
- Capture the exact failing stage before suggesting a fix.
