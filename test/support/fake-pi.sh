#!/bin/sh
# Fake Pi RPC mode server for integration tests.
# Speaks the Pi JSONL protocol: reads commands from stdin, writes events+responses to stdout.
#
# Behavior:
#   1. Waits for a "prompt" command
#   2. Sends a response acknowledging the prompt
#   3. Streams agent_start, message_update, tool_execution, agent_end events
#   4. Exits cleanly
#
# Optional env vars:
#   FAKE_PI_TRACE    — file to log all stdin/stdout for test assertions
#   FAKE_PI_DELAY_MS — milliseconds to sleep between events (default: 0)

trace_file="${FAKE_PI_TRACE:-}"
delay_s="0"
if [ -n "${FAKE_PI_DELAY_MS:-}" ]; then
  # Convert ms to seconds (integer division, good enough for tests)
  delay_s=$(echo "scale=3; ${FAKE_PI_DELAY_MS}/1000" | bc 2>/dev/null || echo "0")
fi

log_trace() {
  if [ -n "$trace_file" ]; then
    printf '%s\n' "$1" >> "$trace_file"
  fi
}

send() {
  printf '%s\n' "$1"
  log_trace "OUT:$1"
  if [ "$delay_s" != "0" ]; then
    sleep "$delay_s"
  fi
}

log_trace "STARTED:pid=$$:cwd=$(pwd):args=$*"

# Read commands line by line
while IFS= read -r line; do
  log_trace "IN:$line"

  # Extract the command type using simple pattern matching
  cmd_type=$(echo "$line" | sed -n 's/.*"type"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')
  cmd_id=$(echo "$line" | sed -n 's/.*"id"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')

  case "$cmd_type" in
    prompt)
      # Extract the message for tracing
      prompt_msg=$(echo "$line" | sed -n 's/.*"message"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')
      log_trace "PROMPT:$prompt_msg"

      # Send prompt acknowledgment response
      if [ -n "$cmd_id" ]; then
        send "{\"type\":\"response\",\"command\":\"prompt\",\"success\":true,\"id\":\"$cmd_id\"}"
      else
        send "{\"type\":\"response\",\"command\":\"prompt\",\"success\":true}"
      fi

      # Stream agent events
      send '{"type":"agent_start"}'
      send '{"type":"turn_start"}'
      send '{"type":"message_start","message":{"role":"assistant"}}'
      send '{"type":"message_update","message":{"role":"assistant"},"assistantMessageEvent":{"type":"text_delta","delta":"I will help with that.","contentIndex":0}}'
      send '{"type":"message_update","message":{"role":"assistant"},"assistantMessageEvent":{"type":"toolcall_start","partial":{"name":"bash"}}}'
      send '{"type":"message_update","message":{"role":"assistant"},"assistantMessageEvent":{"type":"toolcall_end","toolCall":{"id":"call_1","name":"bash","arguments":"{\"command\":\"echo hello\"}"}}}'
      send '{"type":"message_end","message":{"role":"assistant","usage":{"input":500,"output":200,"cacheRead":100,"cacheWrite":50}}}'
      send '{"type":"tool_execution_start","toolCallId":"call_1","toolName":"bash","args":{"command":"echo hello"}}'
      send '{"type":"tool_execution_end","toolCallId":"call_1","toolName":"bash","result":{"content":[{"type":"text","text":"hello"}]},"isError":false}'
      send '{"type":"turn_end","message":{"role":"assistant"},"toolResults":[{"toolCallId":"call_1","content":[{"type":"text","text":"hello"}]}]}'
      send "{\"type\":\"agent_end\",\"messages\":[{\"role\":\"assistant\",\"usage\":{\"input\":500,\"output\":200,\"cacheRead\":100,\"cacheWrite\":50}}]}"
      ;;
    abort)
      if [ -n "$cmd_id" ]; then
        send "{\"type\":\"response\",\"command\":\"abort\",\"success\":true,\"id\":\"$cmd_id\"}"
      else
        send "{\"type\":\"response\",\"command\":\"abort\",\"success\":true}"
      fi
      ;;
    get_state)
      if [ -n "$cmd_id" ]; then
        send "{\"type\":\"response\",\"command\":\"get_state\",\"success\":true,\"id\":\"$cmd_id\",\"data\":{\"isStreaming\":false,\"sessionId\":\"fake-session-1\"}}"
      else
        send "{\"type\":\"response\",\"command\":\"get_state\",\"success\":true,\"data\":{\"isStreaming\":false,\"sessionId\":\"fake-session-1\"}}"
      fi
      ;;
    get_session_stats)
      if [ -n "$cmd_id" ]; then
        send "{\"type\":\"response\",\"command\":\"get_session_stats\",\"success\":true,\"id\":\"$cmd_id\",\"data\":{\"sessionId\":\"fake-session-1\",\"tokens\":{\"input\":500,\"output\":200,\"cacheRead\":100,\"cacheWrite\":50,\"total\":850},\"cost\":0.001}}"
      else
        send "{\"type\":\"response\",\"command\":\"get_session_stats\",\"success\":true,\"data\":{\"sessionId\":\"fake-session-1\",\"tokens\":{\"input\":500,\"output\":200,\"cacheRead\":100,\"cacheWrite\":50,\"total\":850},\"cost\":0.001}}"
      fi
      ;;
    get_available_models)
      if [ -n "$cmd_id" ]; then
        send "{\"type\":\"response\",\"command\":\"get_available_models\",\"success\":true,\"id\":\"$cmd_id\",\"data\":{\"models\":[{\"provider\":\"anthropic\",\"id\":\"claude-sonnet-4-5\"},{\"provider\":\"openai\",\"id\":\"gpt-5\"}]}}"
      else
        send "{\"type\":\"response\",\"command\":\"get_available_models\",\"success\":true,\"data\":{\"models\":[{\"provider\":\"anthropic\",\"id\":\"claude-sonnet-4-5\"},{\"provider\":\"openai\",\"id\":\"gpt-5\"}]}}"
      fi
      ;;
    *)
      log_trace "UNKNOWN_CMD:$cmd_type"
      if [ -n "$cmd_id" ]; then
        send "{\"type\":\"response\",\"command\":\"$cmd_type\",\"success\":false,\"error\":\"unsupported command\",\"id\":\"$cmd_id\"}"
      fi
      ;;
  esac
done

log_trace "EXIT:0"
exit 0
