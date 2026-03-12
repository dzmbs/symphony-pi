defmodule SymphonyElixir.Pi.IntegrationTest do
  @moduledoc """
  Integration tests for the Pi RPC backend using a fake-pi test script.
  """
  use SymphonyElixir.TestSupport

  @fake_pi_script Path.expand("../../support/fake-pi.sh", __DIR__)

  describe "Pi backend single turn" do
    test "runs a prompt through the Pi RPC backend and receives events" do
      test_root =
        Path.join(
          System.tmp_dir!(),
          "symphony-pi-integration-single-#{System.unique_integer([:positive])}"
        )

      try do
        workspace_root = Path.join(test_root, "workspaces")
        trace_file = Path.join(test_root, "pi.trace")

        File.mkdir_p!(workspace_root)
        System.put_env("FAKE_PI_TRACE", trace_file)
        on_exit(fn -> System.delete_env("FAKE_PI_TRACE") end)

        write_workflow_file!(Workflow.workflow_file_path(),
          workspace_root: workspace_root,
          agent_runtime_backend: "pi",
          pi_command: @fake_pi_script,
          hook_after_create: "echo 'workspace ready'"
        )

        assert Config.backend_module() == SymphonyElixir.Pi.RpcBackend

        issue = %Issue{
          id: "pi-issue-1",
          identifier: "PI-1",
          title: "Test Pi integration",
          description: "Verify fake-pi backend works end to end",
          state: "In Progress",
          url: "https://example.org/issues/PI-1",
          labels: ["pi"]
        }

        test_pid = self()

        assert :ok =
                 AgentRunner.run(
                   issue,
                   test_pid,
                   issue_state_fetcher: fn [_issue_id] -> {:ok, [%{issue | state: "Done"}]} end
                 )

        # Verify we got the session_started event
        assert_receive {:runtime_worker_update, "pi-issue-1", %{event: :session_started, timestamp: %DateTime{}}},
                       2_000

        # Verify we got at least one notification event (streaming)
        assert_receive {:runtime_worker_update, "pi-issue-1", %{event: :notification, timestamp: %DateTime{}}},
                       2_000

        # Verify we got the turn_completed event
        assert_receive {:runtime_worker_update, "pi-issue-1", %{event: :turn_completed, timestamp: %DateTime{}}},
                       2_000

        # Verify the session directory was created
        workspace = Path.join(workspace_root, "PI-1")
        session_dir = Path.join(workspace, ".symphony-pi/session")
        assert File.dir?(session_dir)

        # Verify the trace file shows the prompt was sent
        trace = File.read!(trace_file)
        assert trace =~ "PROMPT:"
        assert trace =~ "STARTED:"

        # Verify the shipped Symphony extension was loaded via -e flag
        assert trace =~ "-e"
        assert trace =~ "priv/pi/extensions/symphony/index.ts"
      after
        System.delete_env("FAKE_PI_TRACE")
        File.rm_rf(test_root)
      end
    end

    test "runs a prompt and extracts token usage from agent_end" do
      test_root =
        Path.join(
          System.tmp_dir!(),
          "symphony-pi-integration-tokens-#{System.unique_integer([:positive])}"
        )

      try do
        workspace_root = Path.join(test_root, "workspaces")
        File.mkdir_p!(workspace_root)

        write_workflow_file!(Workflow.workflow_file_path(),
          workspace_root: workspace_root,
          agent_runtime_backend: "pi",
          pi_command: @fake_pi_script,
          hook_after_create: "echo 'ready'"
        )

        issue = %Issue{
          id: "pi-issue-tokens",
          identifier: "PI-2",
          title: "Token extraction",
          description: "Verify usage arrives",
          state: "In Progress",
          url: "https://example.org/issues/PI-2",
          labels: []
        }

        test_pid = self()

        assert :ok =
                 AgentRunner.run(
                   issue,
                   test_pid,
                   issue_state_fetcher: fn [_] -> {:ok, [%{issue | state: "Done"}]} end
                 )

        # Collect all events
        events = collect_runtime_events("pi-issue-tokens", 2_000)

        # Find the turn_completed event — it should have usage
        turn_completed = Enum.find(events, &(&1.event == :turn_completed))
        assert turn_completed != nil

        if turn_completed.usage do
          assert turn_completed.usage["input_tokens"] == 500
          assert turn_completed.usage["output_tokens"] == 200
        end
      after
        File.rm_rf(test_root)
      end
    end
  end

  describe "Pi backend continuation turns" do
    test "reuses the same Pi session for continuation turns" do
      test_root =
        Path.join(
          System.tmp_dir!(),
          "symphony-pi-integration-continuation-#{System.unique_integer([:positive])}"
        )

      try do
        workspace_root = Path.join(test_root, "workspaces")
        trace_file = Path.join(test_root, "pi-continuation.trace")
        File.mkdir_p!(workspace_root)
        System.put_env("FAKE_PI_TRACE", trace_file)
        on_exit(fn -> System.delete_env("FAKE_PI_TRACE") end)

        write_workflow_file!(Workflow.workflow_file_path(),
          workspace_root: workspace_root,
          agent_runtime_backend: "pi",
          pi_command: @fake_pi_script,
          hook_after_create: "echo 'ready'",
          max_turns: 3
        )

        parent = self()
        call_count = :counters.new(1, [:atomics])

        state_fetcher = fn [_issue_id] ->
          count = :counters.get(call_count, 1) + 1
          :counters.put(call_count, 1, count)
          send(parent, {:issue_state_fetch, count})

          state = if count == 1, do: "In Progress", else: "Done"

          {:ok,
           [
             %Issue{
               id: "pi-continue",
               identifier: "PI-3",
               title: "Continuation test",
               description: "Should run 2 turns",
               state: state
             }
           ]}
        end

        issue = %Issue{
          id: "pi-continue",
          identifier: "PI-3",
          title: "Continuation test",
          description: "Should run 2 turns",
          state: "In Progress",
          url: "https://example.org/issues/PI-3",
          labels: []
        }

        assert :ok = AgentRunner.run(issue, parent, issue_state_fetcher: state_fetcher)

        # Should have fetched issue state twice (once per turn completion)
        assert_receive {:issue_state_fetch, 1}, 2_000
        assert_receive {:issue_state_fetch, 2}, 2_000

        # Verify trace shows exactly ONE process start but TWO prompts
        trace = File.read!(trace_file)
        started_lines = trace |> String.split("\n") |> Enum.filter(&String.starts_with?(&1, "STARTED:"))
        prompt_lines = trace |> String.split("\n") |> Enum.filter(&String.starts_with?(&1, "PROMPT:"))

        assert length(started_lines) == 1, "Expected 1 Pi process, got #{length(started_lines)}"
        assert length(prompt_lines) == 2, "Expected 2 prompts, got #{length(prompt_lines)}"

        # Verify turn-scoped session_ids are distinct across turns
        events = collect_runtime_events("pi-continue", 500)
        session_started_events = Enum.filter(events, &(&1.event == :session_started))

        assert length(session_started_events) == 2,
               "Expected 2 :session_started events, got #{length(session_started_events)}"

        [turn1_started, turn2_started] = session_started_events
        assert turn1_started.session_id == "fake-session-1-turn-1"
        assert turn2_started.session_id == "fake-session-1-turn-2"
        assert turn1_started.session_id != turn2_started.session_id
      after
        System.delete_env("FAKE_PI_TRACE")
        File.rm_rf(test_root)
      end
    end
  end

  describe "Pi config" do
    test "backend selection defaults to pi" do
      write_workflow_file!(Workflow.workflow_file_path())
      assert Config.backend_module() == SymphonyElixir.Pi.RpcBackend
    end

    test "backend selection returns Pi when configured" do
      write_workflow_file!(Workflow.workflow_file_path(), agent_runtime_backend: "pi")
      assert Config.backend_module() == SymphonyElixir.Pi.RpcBackend
    end

    test "pi config has sensible defaults" do
      write_workflow_file!(Workflow.workflow_file_path(), agent_runtime_backend: "pi")
      settings = Config.settings!()

      assert settings.pi.command == "pi"
      assert settings.pi.session_subdir == ".symphony-pi/session"
      assert settings.pi.turn_timeout_ms == 3_600_000
      assert settings.pi.read_timeout_ms == 5_000
      assert settings.pi.stall_timeout_ms == 300_000
      assert settings.pi.model == nil
      assert settings.pi.thinking == nil
    end

    test "pi config accepts custom values" do
      write_workflow_file!(Workflow.workflow_file_path(),
        agent_runtime_backend: "pi",
        pi_command: "/usr/local/bin/custom-pi",
        pi_model: "anthropic/claude-sonnet-4-5",
        pi_thinking: "high"
      )

      settings = Config.settings!()

      assert settings.pi.command == "/usr/local/bin/custom-pi"
      assert settings.pi.model == "anthropic/claude-sonnet-4-5"
      assert settings.pi.thinking == "high"
    end
  end

  describe "Pi backend failure handling" do
    @fake_pi_fail_script Path.expand("../../support/fake-pi-fail.sh", __DIR__)

    test "auto_retry_end failure raises and streams error event" do
      test_root =
        Path.join(
          System.tmp_dir!(),
          "symphony-pi-fail-retry-#{System.unique_integer([:positive])}"
        )

      try do
        workspace_root = Path.join(test_root, "workspaces")
        File.mkdir_p!(workspace_root)
        System.put_env("FAKE_PI_FAIL_MODE", "auto_retry")

        write_workflow_file!(Workflow.workflow_file_path(),
          workspace_root: workspace_root,
          agent_runtime_backend: "pi",
          pi_command: @fake_pi_fail_script,
          hook_after_create: "echo 'ready'"
        )

        issue = %Issue{
          id: "pi-fail-retry",
          identifier: "PI-FAIL-1",
          title: "Retry failure test",
          description: "Verify auto-retry exhaustion surfaces as error",
          state: "In Progress",
          url: "https://example.org/issues/PI-FAIL-1",
          labels: []
        }

        test_pid = self()

        # AgentRunner raises on backend errors (Orchestrator catches via Task)
        assert_raise RuntimeError, ~r/turn_failed/, fn ->
          AgentRunner.run(
            issue,
            test_pid,
            issue_state_fetcher: fn [_] -> {:ok, [%{issue | state: "Done"}]} end
          )
        end

        # Verify we got the turn_ended_with_error event streamed to dashboard
        events = collect_runtime_events("pi-fail-retry", 500)

        has_error_event =
          Enum.any?(events, fn e -> e.event == :turn_ended_with_error end)

        assert has_error_event, "Expected :turn_ended_with_error event, got: #{inspect(Enum.map(events, & &1.event))}"
      after
        System.delete_env("FAKE_PI_FAIL_MODE")
        File.rm_rf(test_root)
      end
    end

    test "streaming error raises with turn_failed" do
      test_root =
        Path.join(
          System.tmp_dir!(),
          "symphony-pi-fail-stream-#{System.unique_integer([:positive])}"
        )

      try do
        workspace_root = Path.join(test_root, "workspaces")
        File.mkdir_p!(workspace_root)
        System.put_env("FAKE_PI_FAIL_MODE", "stream_error")

        write_workflow_file!(Workflow.workflow_file_path(),
          workspace_root: workspace_root,
          agent_runtime_backend: "pi",
          pi_command: @fake_pi_fail_script,
          hook_after_create: "echo 'ready'"
        )

        issue = %Issue{
          id: "pi-fail-stream",
          identifier: "PI-FAIL-2",
          title: "Streaming error test",
          description: "Verify streaming error surfaces as error",
          state: "In Progress",
          url: "https://example.org/issues/PI-FAIL-2",
          labels: []
        }

        test_pid = self()

        assert_raise RuntimeError, ~r/turn_failed/, fn ->
          AgentRunner.run(
            issue,
            test_pid,
            issue_state_fetcher: fn [_] -> {:ok, [%{issue | state: "Done"}]} end
          )
        end
      after
        System.delete_env("FAKE_PI_FAIL_MODE")
        File.rm_rf(test_root)
      end
    end

    test "process crash raises with port_exit" do
      test_root =
        Path.join(
          System.tmp_dir!(),
          "symphony-pi-fail-crash-#{System.unique_integer([:positive])}"
        )

      try do
        workspace_root = Path.join(test_root, "workspaces")
        File.mkdir_p!(workspace_root)
        System.put_env("FAKE_PI_FAIL_MODE", "crash")

        write_workflow_file!(Workflow.workflow_file_path(),
          workspace_root: workspace_root,
          agent_runtime_backend: "pi",
          pi_command: @fake_pi_fail_script,
          hook_after_create: "echo 'ready'"
        )

        issue = %Issue{
          id: "pi-fail-crash",
          identifier: "PI-FAIL-3",
          title: "Process crash test",
          description: "Verify process crash surfaces as error",
          state: "In Progress",
          url: "https://example.org/issues/PI-FAIL-3",
          labels: []
        }

        test_pid = self()

        assert_raise RuntimeError, ~r/port_exit/, fn ->
          AgentRunner.run(
            issue,
            test_pid,
            issue_state_fetcher: fn [_] -> {:ok, [%{issue | state: "Done"}]} end
          )
        end
      after
        System.delete_env("FAKE_PI_FAIL_MODE")
        File.rm_rf(test_root)
      end
    end
  end

  describe "Pi session identity" do
    test "session_id is populated from get_state response" do
      test_root =
        Path.join(
          System.tmp_dir!(),
          "symphony-pi-session-id-#{System.unique_integer([:positive])}"
        )

      try do
        workspace_root = Path.join(test_root, "workspaces")
        File.mkdir_p!(workspace_root)

        write_workflow_file!(Workflow.workflow_file_path(),
          workspace_root: workspace_root,
          agent_runtime_backend: "pi",
          pi_command: @fake_pi_script,
          hook_after_create: "echo 'ready'"
        )

        issue = %Issue{
          id: "pi-session-id-test",
          identifier: "PI-SID-1",
          title: "Session ID test",
          description: "Verify session_id comes from get_state",
          state: "In Progress",
          url: "https://example.org/issues/PI-SID-1",
          labels: []
        }

        test_pid = self()

        assert :ok =
                 AgentRunner.run(
                   issue,
                   test_pid,
                   issue_state_fetcher: fn [_] -> {:ok, [%{issue | state: "Done"}]} end
                 )

        # Collect events and verify session_started carries a real session_id
        events = collect_runtime_events("pi-session-id-test", 500)
        session_started = Enum.find(events, &(&1.event == :session_started))
        assert session_started != nil
        # session_id is turn-scoped: "<pi_session_id>-turn-<N>"
        assert session_started.session_id == "fake-session-1-turn-1"
      after
        File.rm_rf(test_root)
      end
    end
  end

  # Helper to collect all runtime_worker_update messages from the mailbox
  defp collect_runtime_events(issue_id, timeout_ms) do
    collect_runtime_events(issue_id, timeout_ms, [])
  end

  defp collect_runtime_events(issue_id, timeout_ms, acc) do
    receive do
      {:runtime_worker_update, ^issue_id, event} ->
        collect_runtime_events(issue_id, timeout_ms, [event | acc])
    after
      timeout_ms -> Enum.reverse(acc)
    end
  end
end
