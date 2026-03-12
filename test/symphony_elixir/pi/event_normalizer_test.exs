defmodule SymphonyElixir.Pi.EventNormalizerTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.Pi.EventNormalizer

  @context [pi_pid: "12345", session_id: "test-session-1"]

  describe "normalize/2" do
    test "agent_start produces :session_started with session_id" do
      result = EventNormalizer.normalize(%{"type" => "agent_start"}, @context)

      assert result.event == :session_started
      assert result.session_id == "test-session-1"
      assert result.runtime_pid == "12345"
      assert %DateTime{} = result.timestamp
    end

    test "agent_end produces :turn_completed" do
      event = %{
        "type" => "agent_end",
        "messages" => [
          %{
            "role" => "assistant",
            "usage" => %{
              "input" => 1000,
              "output" => 500,
              "cacheRead" => 200,
              "cacheWrite" => 50
            }
          }
        ]
      }

      result = EventNormalizer.normalize(event, @context)

      assert result.event == :turn_completed
      assert result.usage["input_tokens"] == 1000
      assert result.usage["output_tokens"] == 500
      assert result.usage["total_tokens"] == 1750
      assert result.usage["cache_read_tokens"] == 200
      assert result.usage["cache_write_tokens"] == 50
    end

    test "agent_end without messages returns nil usage" do
      result = EventNormalizer.normalize(%{"type" => "agent_end"}, @context)
      assert result.event == :turn_completed
      refute Map.has_key?(result, :usage) and result.usage != nil
    end

    test "message_update with text_delta summarizes content" do
      event = %{
        "type" => "message_update",
        "message" => %{},
        "assistantMessageEvent" => %{
          "type" => "text_delta",
          "delta" => "Hello world",
          "contentIndex" => 0
        }
      }

      result = EventNormalizer.normalize(event, @context)
      assert result.event == :notification
      assert result.raw == "Hello world"
    end

    test "message_update with text_delta truncates long content" do
      long_text = String.duplicate("x", 300)

      event = %{
        "type" => "message_update",
        "message" => %{},
        "assistantMessageEvent" => %{
          "type" => "text_delta",
          "delta" => long_text,
          "contentIndex" => 0
        }
      }

      result = EventNormalizer.normalize(event, @context)
      assert String.length(result.raw) <= 201
      assert String.ends_with?(result.raw, "…")
    end

    test "message_update with toolcall_start shows tool name" do
      event = %{
        "type" => "message_update",
        "message" => %{},
        "assistantMessageEvent" => %{
          "type" => "toolcall_start",
          "partial" => %{"name" => "bash"}
        }
      }

      result = EventNormalizer.normalize(event, @context)
      assert result.raw == "calling bash"
    end

    test "tool_execution_start shows tool name" do
      event = %{"type" => "tool_execution_start", "toolCallId" => "c1", "toolName" => "edit"}
      result = EventNormalizer.normalize(event, @context)
      assert result.event == :notification
      assert result.raw == "tool: edit"
    end

    test "tool_execution_end shows status" do
      event = %{"type" => "tool_execution_end", "toolCallId" => "c1", "toolName" => "bash", "isError" => false}
      result = EventNormalizer.normalize(event, @context)
      assert result.raw == "tool done: bash"

      error_event = %{"type" => "tool_execution_end", "toolCallId" => "c2", "toolName" => "bash", "isError" => true}
      error_result = EventNormalizer.normalize(error_event, @context)
      assert error_result.raw == "tool failed: bash"
    end

    test "auto_retry_end with failure produces :turn_ended_with_error" do
      event = %{"type" => "auto_retry_end", "success" => false, "attempt" => 3, "finalError" => "overloaded"}
      result = EventNormalizer.normalize(event, @context)
      assert result.event == :turn_ended_with_error
      assert result.raw =~ "auto-retry failed"
    end

    test "auto_retry_end with success produces :notification" do
      event = %{"type" => "auto_retry_end", "success" => true, "attempt" => 2}
      result = EventNormalizer.normalize(event, @context)
      assert result.event == :notification
    end

    test "failed response produces :turn_ended_with_error" do
      event = %{"type" => "response", "command" => "prompt", "success" => false, "error" => "bad request"}
      result = EventNormalizer.normalize(event, @context)
      assert result.event == :turn_ended_with_error
      assert result.raw =~ "command failed"
    end

    test "unknown event type produces :notification" do
      event = %{"type" => "future_event_type", "data" => "something"}
      result = EventNormalizer.normalize(event, @context)
      assert result.event == :notification
      assert result.raw =~ "future_event_type"
    end

    test "message_end with usage includes usage" do
      event = %{
        "type" => "message_end",
        "message" => %{
          "usage" => %{
            "input" => 500,
            "output" => 200
          }
        }
      }

      result = EventNormalizer.normalize(event, @context)
      assert result.event == :notification
      assert result.usage["input_tokens"] == 500
      assert result.usage["output_tokens"] == 200
    end

    test "all normalized events include timestamp and pi_pid" do
      events = [
        %{"type" => "agent_start"},
        %{"type" => "turn_start"},
        %{"type" => "message_update", "assistantMessageEvent" => %{"type" => "text_delta", "delta" => "x"}},
        %{"type" => "tool_execution_start", "toolName" => "bash"},
        %{"type" => "agent_end"}
      ]

      for event <- events do
        result = EventNormalizer.normalize(event, @context)
        assert %DateTime{} = result.timestamp
        assert result.runtime_pid == "12345"
      end
    end

    test "usage extraction sums across multiple assistant messages" do
      event = %{
        "type" => "agent_end",
        "messages" => [
          %{"role" => "assistant", "usage" => %{"input" => 100, "output" => 50}},
          %{"role" => "assistant", "usage" => %{"input" => 200, "output" => 100}}
        ]
      }

      result = EventNormalizer.normalize(event, @context)
      assert result.usage["input_tokens"] == 300
      assert result.usage["output_tokens"] == 150
    end
  end
end
