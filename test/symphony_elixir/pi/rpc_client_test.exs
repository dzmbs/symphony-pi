defmodule SymphonyElixir.Pi.RpcClientTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.Pi.RpcClient

  # ---------------------------------------------------------------------------
  # parse_line/1
  # ---------------------------------------------------------------------------

  describe "parse_line/1" do
    test "classifies a response payload" do
      line = Jason.encode!(%{"type" => "response", "command" => "prompt", "success" => true, "id" => "req-1"})

      assert {:response, %{"type" => "response", "command" => "prompt", "success" => true, "id" => "req-1"}} =
               RpcClient.parse_line(line)
    end

    test "classifies a failed response" do
      line = Jason.encode!(%{"type" => "response", "command" => "set_model", "success" => false, "error" => "Model not found"})
      assert {:response, %{"success" => false, "error" => "Model not found"}} = RpcClient.parse_line(line)
    end

    test "classifies an agent_start event" do
      line = Jason.encode!(%{"type" => "agent_start"})
      assert {:event, %{"type" => "agent_start"}} = RpcClient.parse_line(line)
    end

    test "classifies an agent_end event with messages" do
      line = Jason.encode!(%{"type" => "agent_end", "messages" => [%{"role" => "assistant"}]})
      assert {:event, %{"type" => "agent_end", "messages" => _}} = RpcClient.parse_line(line)
    end

    test "classifies a message_update event" do
      payload = %{
        "type" => "message_update",
        "message" => %{},
        "assistantMessageEvent" => %{"type" => "text_delta", "delta" => "Hello", "contentIndex" => 0}
      }

      line = Jason.encode!(payload)
      assert {:event, %{"type" => "message_update"}} = RpcClient.parse_line(line)
    end

    test "classifies tool_execution events" do
      for type <- ["tool_execution_start", "tool_execution_update", "tool_execution_end"] do
        line = Jason.encode!(%{"type" => type, "toolCallId" => "call_123", "toolName" => "bash"})
        assert {:event, %{"type" => ^type}} = RpcClient.parse_line(line)
      end
    end

    test "classifies turn_start and turn_end events" do
      assert {:event, %{"type" => "turn_start"}} = RpcClient.parse_line(Jason.encode!(%{"type" => "turn_start"}))
      assert {:event, %{"type" => "turn_end"}} = RpcClient.parse_line(Jason.encode!(%{"type" => "turn_end", "message" => %{}}))
    end

    test "handles JSON object without type field as event" do
      line = Jason.encode!(%{"something" => "else"})
      assert {:event, %{"something" => "else"}} = RpcClient.parse_line(line)
    end

    test "returns parse_error for non-JSON" do
      assert {:parse_error, "this is not json"} = RpcClient.parse_line("this is not json")
    end

    test "returns parse_error for JSON array" do
      assert {:parse_error, "[1, 2, 3]"} = RpcClient.parse_line("[1, 2, 3]")
    end

    test "returns parse_error for empty string" do
      assert {:parse_error, ""} = RpcClient.parse_line("")
    end

    test "strips trailing \\r before parsing" do
      line = Jason.encode!(%{"type" => "agent_start"}) <> "\r"
      assert {:event, %{"type" => "agent_start"}} = RpcClient.parse_line(line)
    end

    test "classifies extension_ui_request as event" do
      line =
        Jason.encode!(%{
          "type" => "extension_ui_request",
          "id" => "uuid-1",
          "method" => "notify",
          "message" => "test"
        })

      assert {:event, %{"type" => "extension_ui_request"}} = RpcClient.parse_line(line)
    end

    test "classifies auto_compaction events" do
      assert {:event, _} = RpcClient.parse_line(Jason.encode!(%{"type" => "auto_compaction_start", "reason" => "threshold"}))
      assert {:event, _} = RpcClient.parse_line(Jason.encode!(%{"type" => "auto_compaction_end", "result" => %{}, "aborted" => false}))
    end

    test "classifies auto_retry events" do
      assert {:event, _} = RpcClient.parse_line(Jason.encode!(%{"type" => "auto_retry_start", "attempt" => 1, "maxAttempts" => 3, "delayMs" => 2000}))
      assert {:event, _} = RpcClient.parse_line(Jason.encode!(%{"type" => "auto_retry_end", "success" => true, "attempt" => 2}))
    end
  end

  # ---------------------------------------------------------------------------
  # Command builders
  # ---------------------------------------------------------------------------

  describe "prompt_command/2" do
    test "builds a basic prompt command" do
      cmd = RpcClient.prompt_command("Hello!")
      assert cmd == %{"type" => "prompt", "message" => "Hello!"}
    end

    test "includes id when provided" do
      cmd = RpcClient.prompt_command("Hello!", id: "req-1")
      assert cmd["id"] == "req-1"
    end

    test "includes streamingBehavior when provided" do
      cmd = RpcClient.prompt_command("Redirect", streaming_behavior: "steer")
      assert cmd["streamingBehavior"] == "steer"
    end
  end

  describe "abort_command/1" do
    test "builds a basic abort command" do
      assert RpcClient.abort_command() == %{"type" => "abort"}
    end

    test "includes id when provided" do
      cmd = RpcClient.abort_command(id: "abort-1")
      assert cmd == %{"type" => "abort", "id" => "abort-1"}
    end
  end

  describe "get_state_command/1" do
    test "builds a get_state command" do
      assert RpcClient.get_state_command() == %{"type" => "get_state"}
    end
  end

  # ---------------------------------------------------------------------------
  # build_argv/1
  # ---------------------------------------------------------------------------

  describe "build_argv/1" do
    test "defaults to pi with --mode rpc" do
      assert {"pi", ["--mode", "rpc"]} = RpcClient.build_argv([])
    end

    test "accepts custom command (binary path)" do
      assert {"/usr/local/bin/custom-pi", ["--mode", "rpc"]} =
               RpcClient.build_argv(command: "/usr/local/bin/custom-pi")
    end

    test "adds --session-dir" do
      {_cmd, args} = RpcClient.build_argv(session_dir: "/tmp/sessions")
      assert "--session-dir" in args
      assert "/tmp/sessions" in args
    end

    test "adds --model" do
      {_cmd, args} = RpcClient.build_argv(model: "anthropic/claude-sonnet-4-5")
      assert args == ["--mode", "rpc", "--model", "anthropic/claude-sonnet-4-5"]
    end

    test "combines model and thinking into model:thinking" do
      {_cmd, args} = RpcClient.build_argv(model: "anthropic/claude-sonnet-4-5", thinking: "high")
      assert args == ["--mode", "rpc", "--model", "anthropic/claude-sonnet-4-5:high"]
    end

    test "thinking without model is ignored" do
      {_cmd, args} = RpcClient.build_argv(thinking: "high")
      refute "--model" in args
    end

    test "adds --no-session" do
      {_cmd, args} = RpcClient.build_argv(no_session: true)
      assert "--no-session" in args
    end

    test "does not add --no-session when false" do
      {_cmd, args} = RpcClient.build_argv(no_session: false)
      refute "--no-session" in args
    end

    test "appends extra_args" do
      {_cmd, args} = RpcClient.build_argv(extra_args: ["--verbose", "--debug"])
      assert List.last(args) == "--debug"
      assert "--verbose" in args
    end

    test "extra_args supports extension flag" do
      {_cmd, args} = RpcClient.build_argv(extra_args: ["-e", "/path/to/extension"])
      assert "-e" in args
      assert "/path/to/extension" in args
    end

    test "combines all options" do
      {cmd, args} =
        RpcClient.build_argv(
          command: "/opt/pi",
          session_dir: "/tmp/s",
          model: "openai/gpt-4",
          thinking: "low",
          no_session: true,
          extra_args: ["--foo"]
        )

      assert cmd == "/opt/pi"
      assert args == ["--mode", "rpc", "--session-dir", "/tmp/s", "--model", "openai/gpt-4:low", "--no-session", "--foo"]
    end
  end

  describe "module API" do
    test "exports expected public functions" do
      assert function_exported?(RpcClient, :start, 2)
      assert function_exported?(RpcClient, :send_command, 2)
      assert function_exported?(RpcClient, :stop, 1)
      assert function_exported?(RpcClient, :os_pid, 1)
      assert function_exported?(RpcClient, :parse_line, 1)
      assert function_exported?(RpcClient, :receive_line, 3)
      assert function_exported?(RpcClient, :await_response, 3)
      assert function_exported?(RpcClient, :build_argv, 1)
      assert function_exported?(RpcClient, :prompt_command, 2)
      assert function_exported?(RpcClient, :abort_command, 1)
      assert function_exported?(RpcClient, :get_state_command, 1)
    end
  end
end
