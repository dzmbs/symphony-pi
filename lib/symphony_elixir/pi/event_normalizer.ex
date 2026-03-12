defmodule SymphonyElixir.Pi.EventNormalizer do
  @moduledoc """
  Translates raw Pi RPC events into the update format consumed by
  the Orchestrator's `{:runtime_worker_update, issue_id, update}` handler.

  The Orchestrator expects updates with at minimum:
    - `:event` — an atom identifying the event kind
    - `:timestamp` — a `DateTime`

  Optional fields consumed by the Orchestrator:
    - `:session_id` — string, used for tracking
    - `:runtime_pid` — string, maps to Pi OS pid
    - `:usage` — token usage map
    - `:payload` / `:raw` — for summary/display

  This module keeps all Pi-specific payload handling isolated from
  the orchestrator.
  """

  @doc """
  Normalize a raw Pi RPC event map into the update format expected
  by the Orchestrator.

  Returns a map with at least `:event` and `:timestamp`.
  """
  @spec normalize(map(), keyword()) :: map()
  def normalize(raw_event, context \\ []) do
    pi_pid = Keyword.get(context, :pi_pid)

    base = %{
      timestamp: DateTime.utc_now(),
      runtime_pid: pi_pid
    }

    case raw_event do
      %{"type" => "agent_start"} ->
        session_id = Keyword.get(context, :session_id)

        Map.merge(base, %{
          event: :session_started,
          session_id: session_id
        })

      %{"type" => "agent_end"} = event ->
        usage = extract_usage_from_agent_end(event)

        Map.merge(base, %{
          event: :turn_completed,
          payload: event,
          usage: usage
        })

      %{"type" => "message_start"} = event ->
        Map.merge(base, %{
          event: :notification,
          payload: event,
          raw: summarize_message_start(event)
        })

      %{"type" => "message_update"} = event ->
        Map.merge(base, %{
          event: :notification,
          payload: event,
          raw: summarize_message_update(event)
        })

      %{"type" => "message_end"} = event ->
        usage = extract_usage_from_message(event)

        update = %{
          event: :notification,
          payload: event,
          raw: "message complete"
        }

        update = if usage, do: Map.put(update, :usage, usage), else: update
        Map.merge(base, update)

      %{"type" => "turn_start"} ->
        Map.merge(base, %{
          event: :notification,
          raw: "turn started"
        })

      %{"type" => "turn_end"} = event ->
        Map.merge(base, %{
          event: :notification,
          payload: event,
          raw: "turn ended"
        })

      %{"type" => "tool_execution_start"} = event ->
        tool_name = Map.get(event, "toolName", "unknown")

        Map.merge(base, %{
          event: :notification,
          payload: event,
          raw: "tool: #{tool_name}"
        })

      %{"type" => "tool_execution_update"} = event ->
        tool_name = Map.get(event, "toolName", "unknown")

        Map.merge(base, %{
          event: :notification,
          payload: event,
          raw: "tool running: #{tool_name}"
        })

      %{"type" => "tool_execution_end"} = event ->
        tool_name = Map.get(event, "toolName", "unknown")
        is_error = Map.get(event, "isError", false)
        status = if is_error, do: "failed", else: "done"

        Map.merge(base, %{
          event: :notification,
          payload: event,
          raw: "tool #{status}: #{tool_name}"
        })

      %{"type" => "auto_compaction_start"} ->
        Map.merge(base, %{
          event: :notification,
          raw: "auto-compaction started"
        })

      %{"type" => "auto_compaction_end"} ->
        Map.merge(base, %{
          event: :notification,
          raw: "auto-compaction complete"
        })

      %{"type" => "auto_retry_start"} = event ->
        attempt = Map.get(event, "attempt", "?")

        Map.merge(base, %{
          event: :notification,
          raw: "auto-retry attempt #{attempt}"
        })

      %{"type" => "auto_retry_end", "success" => false} = event ->
        error = Map.get(event, "finalError", "unknown")

        Map.merge(base, %{
          event: :turn_ended_with_error,
          payload: event,
          raw: "auto-retry failed: #{error}"
        })

      %{"type" => "auto_retry_end"} ->
        Map.merge(base, %{
          event: :notification,
          raw: "auto-retry succeeded"
        })

      %{"type" => "extension_error"} = event ->
        error_msg = Map.get(event, "error", "unknown extension error")

        Map.merge(base, %{
          event: :notification,
          payload: event,
          raw: "extension error: #{error_msg}"
        })

      %{"type" => "response"} = event ->
        # Responses are not agent events; pass through as-is for debugging
        if event["success"] == false do
          Map.merge(base, %{
            event: :turn_ended_with_error,
            payload: event,
            raw: "command failed: #{event["error"] || "unknown"}"
          })
        else
          Map.merge(base, %{
            event: :notification,
            payload: event,
            raw: "response: #{event["command"] || "unknown"}"
          })
        end

      _ ->
        Map.merge(base, %{
          event: :notification,
          payload: raw_event,
          raw: "pi event: #{Map.get(raw_event, "type", "unknown")}"
        })
    end
  end

  # ---------------------------------------------------------------------------
  # Usage extraction
  # ---------------------------------------------------------------------------

  defp extract_usage_from_agent_end(%{"messages" => messages}) when is_list(messages) do
    # Sum usage across all assistant messages in the agent_end payload
    messages
    |> Enum.filter(&is_map/1)
    |> Enum.reduce(%{}, fn msg, acc ->
      case msg do
        %{"usage" => usage} when is_map(usage) -> merge_usage(acc, usage)
        _ -> acc
      end
    end)
    |> case do
      empty when map_size(empty) == 0 -> nil
      usage -> normalize_usage(usage)
    end
  end

  defp extract_usage_from_agent_end(_event), do: nil

  defp extract_usage_from_message(%{"message" => %{"usage" => usage}}) when is_map(usage) do
    normalize_usage(usage)
  end

  defp extract_usage_from_message(_event), do: nil

  defp merge_usage(acc, usage) do
    Enum.reduce(usage, acc, fn
      {key, value}, merged when is_integer(value) ->
        Map.update(merged, key, value, fn existing ->
          if is_integer(existing), do: existing + value, else: value
        end)

      {_key, _value}, merged ->
        merged
    end)
  end

  defp normalize_usage(usage) when is_map(usage) do
    # Map Pi usage field names to the format the orchestrator expects
    input = get_usage_field(usage, ["input", "input_tokens", "inputTokens", "prompt_tokens", "promptTokens"])
    output = get_usage_field(usage, ["output", "output_tokens", "outputTokens", "completion_tokens", "completionTokens"])
    cache_read = get_usage_field(usage, ["cacheRead", "cache_read", "cacheReadTokens"])
    cache_write = get_usage_field(usage, ["cacheWrite", "cache_write", "cacheWriteTokens"])

    total =
      case get_usage_field(usage, ["total", "total_tokens", "totalTokens"]) do
        nil ->
          total = (input || 0) + (output || 0) + (cache_read || 0) + (cache_write || 0)
          if total > 0, do: total, else: nil

        value ->
          value
      end

    result = %{}
    result = if input, do: Map.put(result, "input_tokens", input), else: result
    result = if output, do: Map.put(result, "output_tokens", output), else: result
    result = if total, do: Map.put(result, "total_tokens", total), else: result
    result = if cache_read, do: Map.put(result, "cache_read_tokens", cache_read), else: result
    result = if cache_write, do: Map.put(result, "cache_write_tokens", cache_write), else: result
    result
  end

  defp get_usage_field(usage, field_names) do
    Enum.find_value(field_names, fn name ->
      case Map.get(usage, name) do
        value when is_integer(value) and value >= 0 -> value
        _ -> nil
      end
    end)
  end

  # ---------------------------------------------------------------------------
  # Summary helpers
  # ---------------------------------------------------------------------------

  defp summarize_message_start(%{"message" => %{"role" => role}}) do
    "#{role} message started"
  end

  defp summarize_message_start(_event), do: "message started"

  defp summarize_message_update(%{
         "assistantMessageEvent" => %{"type" => "text_delta", "delta" => delta}
       })
       when is_binary(delta) do
    truncated = String.slice(delta, 0, 200)
    if String.length(delta) > 200, do: truncated <> "…", else: truncated
  end

  defp summarize_message_update(%{
         "assistantMessageEvent" => %{"type" => "toolcall_start", "partial" => partial}
       }) do
    tool_name =
      case partial do
        %{"name" => name} when is_binary(name) -> name
        _ -> "tool"
      end

    "calling #{tool_name}"
  end

  defp summarize_message_update(%{"assistantMessageEvent" => %{"type" => type}})
       when is_binary(type) do
    "streaming: #{type}"
  end

  defp summarize_message_update(_event), do: "streaming..."
end
