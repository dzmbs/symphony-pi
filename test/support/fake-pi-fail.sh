#!/bin/sh
# Fake Pi RPC server that simulates failure modes for integration tests.
#
# Behavior is controlled by the FAKE_PI_FAIL_MODE env var:
#   "auto_retry"     — emits auto_retry_end with success=false (retries exhausted)
#   "stream_error"   — emits message_update with assistantMessageEvent type=error
#   "crash"          — exits with status 1 mid-stream
#
# Always responds to get_state first, then fails on prompt.

trace_file="${FAKE_PI_TRACE:-}"
fail_mode="${FAKE_PI_FAIL_MODE:-auto_retry}"

log_trace() {
  if [ -n "$trace_file" ]; then
    printf '%s\n' "$1" >> "$trace_file"
  fi
}

send() {
  printf '%s\n' "$1"
  log_trace "OUT:$1"
}

log_trace "STARTED:pid=$$:fail_mode=$fail_mode"

while IFS= read -r line; do
  log_trace "IN:$line"

  cmd_type=$(echo "$line" | sed -n 's/.*"type"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')
  cmd_id=$(echo "$line" | sed -n 's/.*"id"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')

  case "$cmd_type" in
    get_state)
      if [ -n "$cmd_id" ]; then
        send "{\"type\":\"response\",\"command\":\"get_state\",\"success\":true,\"id\":\"$cmd_id\",\"data\":{\"isStreaming\":false,\"sessionId\":\"fake-fail-session\"}}"
      else
        send "{\"type\":\"response\",\"command\":\"get_state\",\"success\":true,\"data\":{\"isStreaming\":false,\"sessionId\":\"fake-fail-session\"}}"
      fi
      ;;
    prompt)
      if [ -n "$cmd_id" ]; then
        send "{\"type\":\"response\",\"command\":\"prompt\",\"success\":true,\"id\":\"$cmd_id\"}"
      else
        send "{\"type\":\"response\",\"command\":\"prompt\",\"success\":true}"
      fi

      send '{"type":"agent_start"}'
      send '{"type":"turn_start"}'

      case "$fail_mode" in
        auto_retry)
          send '{"type":"auto_retry_start","attempt":1,"maxAttempts":2,"delayMs":100,"errorMessage":"529 overloaded"}'
          send '{"type":"auto_retry_end","success":false,"attempt":2,"finalError":"529 overloaded_error: Overloaded"}'
          ;;
        stream_error)
          send '{"type":"message_start","message":{"role":"assistant"}}'
          send '{"type":"message_update","message":{"role":"assistant"},"assistantMessageEvent":{"type":"text_delta","delta":"Starting...","contentIndex":0}}'
          send '{"type":"message_update","message":{"role":"assistant"},"assistantMessageEvent":{"type":"error","reason":"error","message":"API connection lost"}}'
          ;;
        crash)
          send '{"type":"message_start","message":{"role":"assistant"}}'
          log_trace "CRASH:exit=1"
          exit 1
          ;;
      esac
      ;;
    abort)
      if [ -n "$cmd_id" ]; then
        send "{\"type\":\"response\",\"command\":\"abort\",\"success\":true,\"id\":\"$cmd_id\"}"
      else
        send "{\"type\":\"response\",\"command\":\"abort\",\"success\":true}"
      fi
      ;;
    *)
      if [ -n "$cmd_id" ]; then
        send "{\"type\":\"response\",\"command\":\"$cmd_type\",\"success\":false,\"error\":\"unsupported\",\"id\":\"$cmd_id\"}"
      fi
      ;;
  esac
done

log_trace "EXIT:0"
exit 0
