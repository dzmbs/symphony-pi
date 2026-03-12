defmodule SymphonyElixir.Pi.RpcBackend do
  @moduledoc """
  AgentBackend implementation that runs Pi in RPC mode.

  For each session:
  - Spawns `pi --mode rpc` inside the issue workspace
  - Stores Pi session data in `<workspace>/<session_subdir>/`
  - Sends prompts via JSONL stdin, consumes events from JSONL stdout
  - Reuses the same Pi process across continuation turns
  - Translates Pi events into the format expected by the Orchestrator
  """

  @behaviour SymphonyElixir.AgentBackend

  require Logger

  alias SymphonyElixir.{Config, Pi.EventNormalizer, Pi.RpcClient, Pi.ToolBridge}

  @prompt_command_id "symphony-prompt"
  @get_state_command_id "symphony-get-state"
  @get_state_snapshot_command_id "symphony-get-state-snapshot"
  @get_session_stats_command_id "symphony-get-session-stats"
  @stats_poll_interval_ms 1_000

  # ---------------------------------------------------------------------------
  # AgentBackend callbacks
  # ---------------------------------------------------------------------------

  @impl true
  @doc """
  Start a Pi RPC session in the given workspace.

  Creates the session subdirectory and spawns `pi --mode rpc`.
  Returns a session map used by `run_turn/4` and `stop_session/1`.
  """
  def start_session(workspace, opts) do
    pi_config = Config.settings!().pi
    session_dir = Path.join(Path.expand(workspace), pi_config.session_subdir)
    worker_host = Keyword.get(opts, :worker_host)

    with :ok <- ensure_dir(session_dir),
         {:ok, bridge_pid, bridge_port} <- start_tool_bridge(),
         {:ok, port} <- start_pi_process(workspace, pi_config, session_dir, bridge_port, worker_host) do
      pi_pid = RpcClient.os_pid(port)

      Logger.info("Pi RPC session started workspace=#{workspace} pi_pid=#{pi_pid || "unknown"} bridge_port=#{bridge_port}")

      session = %{
        port: port,
        workspace: Path.expand(workspace),
        session_dir: session_dir,
        pi_pid: pi_pid,
        session_id: nil,
        turn_number: 0,
        bridge_pid: bridge_pid,
        bridge_port: bridge_port,
        worker_host: worker_host
      }

      # Fetch session_id from Pi's get_state response
      session = fetch_session_id(session, pi_config)

      {:ok, session}
    else
      {:error, reason} ->
        {:error, reason}
    end
  end

  @impl true
  @doc """
  Execute a single prompt turn within an existing Pi session.

  Sends the prompt, consumes events until `agent_end`, and forwards
  normalized updates via the `:on_message` callback.
  """
  def run_turn(session, prompt, issue, opts) do
    %{port: port, pi_pid: pi_pid} = session
    on_message = Keyword.get(opts, :on_message, &default_on_message/1)
    pi_config = Config.settings!().pi

    # Increment turn number for this prompt
    turn_number = Map.get(session, :turn_number, 0) + 1
    session = %{session | turn_number: turn_number}

    # Build and send prompt command
    command = RpcClient.prompt_command(prompt, id: @prompt_command_id)

    Logger.info("Pi RPC sending prompt for #{issue_context(issue)} pi_pid=#{pi_pid || "unknown"}")

    case RpcClient.send_command(port, command) do
      :ok ->
        case RpcClient.await_response(port, @prompt_command_id, pi_config.read_timeout_ms) do
          {:ok, _response, early_events} ->
            # Forward any events that arrived before the response
            Enum.each(early_events, fn event ->
              normalized = EventNormalizer.normalize(event, normalizer_context(session))
              on_message.(normalized)
            end)

            # Now consume the event stream until agent_end or failure
            consume_events(session, on_message, pi_config)

          {:error, {:command_failed, error, _events}} ->
            Logger.error("Pi RPC prompt rejected for #{issue_context(issue)}: #{inspect(error)}")
            {:error, {:prompt_rejected, error}}

          {:error, reason} ->
            Logger.error("Pi RPC prompt failed for #{issue_context(issue)}: #{inspect(reason)}")
            {:error, reason}
        end

      {:error, :port_closed} ->
        Logger.error("Pi RPC prompt failed for #{issue_context(issue)}: port closed")
        {:error, {:port_exit, :unknown}}
    end
  end

  @impl true
  @doc """
  Stop the Pi RPC session.

  Sends abort if needed, then closes the port. Safe to call multiple times.
  """
  def stop_session(%{port: port} = session) do
    pi_pid = Map.get(session, :pi_pid)
    Logger.info("Pi RPC session stopping pi_pid=#{pi_pid || "unknown"}")

    # Best-effort abort — ignore errors if port is already closed
    try do
      RpcClient.send_command(port, RpcClient.abort_command())
    rescue
      ArgumentError -> :ok
    catch
      :error, :badarg -> :ok
    end

    RpcClient.stop(port)

    # Stop the tool bridge
    case Map.get(session, :bridge_pid) do
      pid when is_pid(pid) -> ToolBridge.stop(pid)
      _ -> :ok
    end
  end

  def stop_session(_session), do: :ok

  # ---------------------------------------------------------------------------
  # Event consumption loop
  # ---------------------------------------------------------------------------

  defp consume_events(session, on_message, pi_config) do
    %{port: port} = session
    turn_timeout_ms = pi_config.turn_timeout_ms
    stall_timeout_ms = pi_config.stall_timeout_ms
    now_ms = System.monotonic_time(:millisecond)

    case emit_runtime_snapshot(session, on_message, pi_config, force: true) do
      {:ok, session, last_stats_at_ms} ->
        do_consume_events(
          port,
          session,
          on_message,
          pi_config,
          turn_timeout_ms,
          stall_timeout_ms,
          "",
          now_ms,
          now_ms,
          last_stats_at_ms
        )

      {:terminal, result, session} ->
        terminal_result(result, session)
    end
  end

  defp do_consume_events(
         port,
         session,
         on_message,
         pi_config,
         turn_timeout_ms,
         stall_timeout_ms,
         buffer,
         turn_start_ms,
         last_event_at_ms,
         last_stats_at_ms
       ) do
    now_ms = System.monotonic_time(:millisecond)

    # Check both: stall (time since last event) and turn (total elapsed)
    stall_remaining_ms = max(0, stall_timeout_ms - (now_ms - last_event_at_ms))
    turn_remaining_ms = max(0, turn_timeout_ms - (now_ms - turn_start_ms))
    effective_timeout_ms = min(stall_remaining_ms, turn_remaining_ms)
    effective_timeout_ms = max(effective_timeout_ms, 100)

    case RpcClient.receive_line(port, buffer, effective_timeout_ms) do
      {:ok, {:event, %{"type" => "agent_end"} = event}, _new_buffer} ->
        normalized = EventNormalizer.normalize(event, normalizer_context(session))
        on_message.(normalized)

        case emit_runtime_snapshot(session, on_message, pi_config, force: true) do
          {:ok, session, _last_stats_at_ms} ->
            {:ok, %{result: :turn_completed, session_id: turn_scoped_session_id(session)}, session}

          {:terminal, result, session} ->
            terminal_result(result, session)
        end

      {:ok, {:event, %{"type" => "auto_retry_end", "success" => false} = event}, _new_buffer} ->
        # All retries exhausted — this is a hard failure
        normalized = EventNormalizer.normalize(event, normalizer_context(session))
        on_message.(normalized)

        final_error = Map.get(event, "finalError", "auto-retry exhausted")
        Logger.warning("Pi RPC auto-retry failed: #{final_error}")
        {:error, {:turn_failed, final_error}}

      {:ok, {:event, %{"type" => "message_update", "assistantMessageEvent" => %{"type" => "error"} = ame} = event}, _new_buffer} ->
        # Streaming error during message generation — hard failure
        normalized = EventNormalizer.normalize(event, normalizer_context(session))
        on_message.(normalized)

        reason = Map.get(ame, "reason", "unknown")
        Logger.warning("Pi RPC streaming error: #{reason}")
        {:error, {:turn_failed, reason}}

      {:ok, {:event, event}, new_buffer} ->
        normalized = EventNormalizer.normalize(event, normalizer_context(session))
        on_message.(normalized)

        if port_closed?(port) do
          {:error, {:port_exit, :unknown}}
        else
          case emit_runtime_snapshot(session, on_message, pi_config, last_stats_at_ms: last_stats_at_ms) do
            {:ok, session, last_stats_at_ms} ->
              do_consume_events(
                port,
                session,
                on_message,
                pi_config,
                turn_timeout_ms,
                stall_timeout_ms,
                new_buffer,
                turn_start_ms,
                System.monotonic_time(:millisecond),
                last_stats_at_ms
              )

            {:terminal, result, session} ->
              terminal_result(result, session)
          end
        end

      {:ok, {:response, response}, new_buffer} ->
        # Responses during event streaming (e.g., from auto-retry)
        # — forward as normalized event and continue
        normalized = EventNormalizer.normalize(response, normalizer_context(session))
        on_message.(normalized)

        case emit_runtime_snapshot(session, on_message, pi_config, last_stats_at_ms: last_stats_at_ms) do
          {:ok, session, last_stats_at_ms} ->
            do_consume_events(
              port,
              session,
              on_message,
              pi_config,
              turn_timeout_ms,
              stall_timeout_ms,
              new_buffer,
              turn_start_ms,
              System.monotonic_time(:millisecond),
              last_stats_at_ms
            )

          {:terminal, result, session} ->
            terminal_result(result, session)
        end

      {:ok, {:parse_error, _raw}, new_buffer} ->
        do_consume_events(
          port,
          session,
          on_message,
          pi_config,
          turn_timeout_ms,
          stall_timeout_ms,
          new_buffer,
          turn_start_ms,
          last_event_at_ms,
          last_stats_at_ms
        )

      {:error, :timeout} ->
        now_ms = System.monotonic_time(:millisecond)
        stall_elapsed_ms = now_ms - last_event_at_ms
        turn_elapsed_ms = now_ms - turn_start_ms

        cond do
          port_closed?(port) ->
            {:error, {:port_exit, :unknown}}

          turn_elapsed_ms >= turn_timeout_ms ->
            Logger.warning("Pi RPC turn timeout after #{turn_elapsed_ms}ms")
            {:error, :turn_timeout}

          stall_elapsed_ms >= stall_timeout_ms ->
            Logger.warning("Pi RPC stall timeout after #{stall_elapsed_ms}ms without events")
            {:error, :stall_timeout}

          true ->
            # Spurious timeout — keep waiting
            do_consume_events(
              port,
              session,
              on_message,
              pi_config,
              turn_timeout_ms,
              stall_timeout_ms,
              buffer,
              turn_start_ms,
              last_event_at_ms,
              last_stats_at_ms
            )
        end

      {:error, {:port_exit, status}} ->
        Logger.warning("Pi RPC process exited with status #{status}")
        {:error, {:port_exit, status}}

      {:error, reason} ->
        Logger.error("Pi RPC event stream error: #{inspect(reason)}")
        {:error, reason}
    end
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp start_tool_bridge do
    case ToolBridge.start_link() do
      {:ok, pid, port} -> {:ok, pid, port}
      {:error, reason} -> {:error, {:tool_bridge_failed, reason}}
    end
  end

  defp start_pi_process(workspace, pi_config, session_dir, bridge_port, nil = _worker_host) do
    env = [{"SYMPHONY_TOOL_BRIDGE_URL", "http://127.0.0.1:#{bridge_port}"}]
    RpcClient.start(workspace, start_opts(pi_config, session_dir) ++ [env: env])
  end

  defp start_pi_process(workspace, pi_config, session_dir, bridge_port, worker_host) do
    # For remote workers, use SSH reverse port forwarding (-R) so the remote Pi
    # can reach the local bridge at 127.0.0.1:<remote_port> on the worker.
    # We use the same port number — SSH will forward remote:<bridge_port> -> local:127.0.0.1:<bridge_port>
    env = [{"SYMPHONY_TOOL_BRIDGE_URL", "http://127.0.0.1:#{bridge_port}"}]

    RpcClient.start(
      workspace,
      start_opts(pi_config, session_dir) ++
        [
          env: env,
          worker_host: worker_host,
          reverse_forward: {bridge_port, bridge_port}
        ]
    )
  end

  defp fetch_session_id(%{port: port} = session, pi_config) do
    command = RpcClient.get_state_command(id: @get_state_command_id)

    case RpcClient.send_command(port, command) do
      :ok ->
        case RpcClient.await_response(port, @get_state_command_id, pi_config.read_timeout_ms) do
          {:ok, %{"data" => %{"sessionId" => session_id}}, _events} when is_binary(session_id) ->
            Logger.info("Pi RPC session_id=#{session_id}")
            %{session | session_id: session_id}

          {:ok, _response, _events} ->
            Logger.debug("Pi RPC get_state did not return sessionId; using fallback")
            session

          {:error, reason} ->
            Logger.warning("Pi RPC get_state failed: #{inspect(reason)}; continuing without session_id")
            session
        end

      {:error, :port_closed} ->
        Logger.warning("Pi RPC get_state failed: port closed; continuing without session_id")
        session
    end
  end

  defp emit_runtime_snapshot(session, on_message, pi_config, opts) do
    force? = Keyword.get(opts, :force, false)
    last_stats_at_ms = Keyword.get(opts, :last_stats_at_ms, 0)
    now_ms = System.monotonic_time(:millisecond)

    if force? or now_ms - last_stats_at_ms >= @stats_poll_interval_ms do
      case fetch_runtime_snapshot(session, pi_config, on_message) do
        {:ok, update, updated_session} ->
          on_message.(update)
          {:ok, updated_session, now_ms}

        {:terminal, result, updated_session} ->
          {:terminal, result, updated_session}

        {:error, {:port_exit, status}} ->
          {:terminal, {:port_exit, status}, session}

        {:error, reason} ->
          Logger.debug("Pi RPC runtime snapshot unavailable: #{inspect(reason)}")
          {:ok, session, last_stats_at_ms}
      end
    else
      {:ok, session, last_stats_at_ms}
    end
  end

  defp fetch_runtime_snapshot(session, pi_config, on_message) do
    with {:ok, stats, session} <- fetch_session_stats(session, pi_config, on_message),
         {:ok, state, session} <- fetch_runtime_state(session, pi_config, on_message) do
      {:ok, runtime_snapshot_update(stats, state), session}
    end
  end

  defp fetch_session_stats(%{port: port} = session, pi_config, on_message) do
    case RpcClient.send_command(port, RpcClient.get_session_stats_command(id: @get_session_stats_command_id)) do
      :ok ->
        case RpcClient.await_response(port, @get_session_stats_command_id, pi_config.read_timeout_ms) do
          {:ok, %{"data" => data}, events} when is_map(data) ->
            case forward_runtime_events(events, session, on_message) do
              :ok -> {:ok, data, session}
              {:terminal, result} -> {:terminal, result, session}
            end

          {:ok, response, events} ->
            case forward_runtime_events(events, session, on_message) do
              :ok -> {:error, {:unexpected_session_stats_response, response}}
              {:terminal, result} -> {:terminal, result, session}
            end

          {:error, reason} ->
            {:error, reason}
        end

      {:error, :port_closed} ->
        {:error, {:port_exit, :unknown}}
    end
  end

  defp fetch_runtime_state(%{port: port} = session, pi_config, on_message) do
    case RpcClient.send_command(port, RpcClient.get_state_command(id: @get_state_snapshot_command_id)) do
      :ok ->
        case RpcClient.await_response(port, @get_state_snapshot_command_id, pi_config.read_timeout_ms) do
          {:ok, %{"data" => data}, events} when is_map(data) ->
            session = maybe_update_session_id(session, data)

            case forward_runtime_events(events, session, on_message) do
              :ok -> {:ok, data, session}
              {:terminal, result} -> {:terminal, result, session}
            end

          {:ok, response, events} ->
            case forward_runtime_events(events, session, on_message) do
              :ok -> {:error, {:unexpected_get_state_response, response}}
              {:terminal, result} -> {:terminal, result, session}
            end

          {:error, reason} ->
            {:error, reason}
        end

      {:error, :port_closed} ->
        {:error, {:port_exit, :unknown}}
    end
  end

  defp forward_runtime_events(events, session, on_message) when is_list(events) do
    Enum.reduce_while(events, :ok, fn event, _acc ->
      normalized = EventNormalizer.normalize(event, normalizer_context(session))
      on_message.(normalized)

      case classify_terminal_event(event) do
        nil -> {:cont, :ok}
        result -> {:halt, {:terminal, result}}
      end
    end)
  end

  defp runtime_snapshot_update(stats, state) do
    usage =
      stats
      |> Map.get("tokens", %{})
      |> normalize_session_stats_tokens()

    %{
      event: :runtime_snapshot,
      timestamp: DateTime.utc_now(),
      usage: usage,
      cost_total: get_in(stats, ["cost"]),
      runtime_state: %{
        model_id: get_in(state, ["model", "id"]),
        provider: get_in(state, ["model", "provider"]),
        context_window: get_in(state, ["model", "contextWindow"]),
        thinking_level: Map.get(state, "thinkingLevel"),
        is_streaming: Map.get(state, "isStreaming"),
        is_compacting: Map.get(state, "isCompacting"),
        auto_compaction_enabled: Map.get(state, "autoCompactionEnabled"),
        pending_message_count: Map.get(state, "pendingMessageCount")
      }
    }
  end

  defp normalize_session_stats_tokens(tokens) when is_map(tokens) do
    %{}
    |> maybe_put_token("input_tokens", Map.get(tokens, "input"))
    |> maybe_put_token("output_tokens", Map.get(tokens, "output"))
    |> maybe_put_token("cache_read_tokens", Map.get(tokens, "cacheRead"))
    |> maybe_put_token("cache_write_tokens", Map.get(tokens, "cacheWrite"))
    |> maybe_put_token("total_tokens", Map.get(tokens, "total"))
  end

  defp normalize_session_stats_tokens(_tokens), do: %{}

  defp maybe_put_token(map, _key, value) when not is_integer(value), do: map
  defp maybe_put_token(map, key, value), do: Map.put(map, key, value)

  defp maybe_update_session_id(session, %{"sessionId" => session_id}) when is_binary(session_id) do
    %{session | session_id: session_id}
  end

  defp maybe_update_session_id(session, _state), do: session

  defp port_closed?(port) when is_port(port), do: :erlang.port_info(port) == :undefined

  defp classify_terminal_event(%{"type" => "agent_end"}), do: :agent_end

  defp classify_terminal_event(%{"type" => "auto_retry_end", "success" => false} = event) do
    {:turn_failed, Map.get(event, "finalError", "auto-retry exhausted")}
  end

  defp classify_terminal_event(%{
         "type" => "message_update",
         "assistantMessageEvent" => %{"type" => "error"} = ame
       }) do
    {:turn_failed, Map.get(ame, "reason", "unknown")}
  end

  defp classify_terminal_event(_event), do: nil

  defp terminal_result(:agent_end, session),
    do: {:ok, %{result: :turn_completed, session_id: turn_scoped_session_id(session)}, session}

  defp terminal_result({:turn_failed, reason}, _session),
    do: {:error, {:turn_failed, reason}}

  defp terminal_result({:port_exit, status}, _session),
    do: {:error, {:port_exit, status}}

  defp start_opts(pi_config, session_dir) do
    opts = [
      command: pi_config.command,
      session_dir: session_dir
    ]

    opts =
      if pi_config.model do
        Keyword.put(opts, :model, pi_config.model)
      else
        opts
      end

    opts =
      if pi_config.thinking do
        Keyword.put(opts, :thinking, pi_config.thinking)
      else
        opts
      end

    # Load the Symphony extension explicitly via --extension flag
    # since Pi runs inside the issue workspace, not the symphony-pi repo.
    extension_source = resolve_extension_source(pi_config)

    if extension_source do
      Keyword.update(opts, :extra_args, ["-e", extension_source], &(&1 ++ ["-e", extension_source]))
    else
      opts
    end
  end

  defp resolve_extension_source(pi_config) do
    case pi_config.extension_dir do
      path when is_binary(path) and path != "" ->
        resolve_extension_source_path(Path.expand(path))

      _ ->
        priv_source = Application.app_dir(:symphony_elixir, "priv/pi/extensions/symphony/index.ts")

        if File.regular?(priv_source) do
          priv_source
        else
          dev_source = Path.expand("../../../.pi/extensions/symphony/index.ts", __DIR__)
          if File.regular?(dev_source), do: dev_source, else: nil
        end
    end
  end

  defp resolve_extension_source_path(path) when is_binary(path) do
    cond do
      File.regular?(path) ->
        path

      File.regular?(Path.join(path, "index.ts")) ->
        Path.join(path, "index.ts")

      File.dir?(path) ->
        path

      true ->
        nil
    end
  end

  defp normalizer_context(%{pi_pid: pi_pid} = session) do
    [
      pi_pid: pi_pid,
      session_id: turn_scoped_session_id(session)
    ]
  end

  # Produce a turn-scoped session ID so the orchestrator increments turn_count
  # on each continuation turn. Format: "<pi_session_id>-turn-<N>"
  defp turn_scoped_session_id(session) do
    base = Map.get(session, :session_id) || generate_fallback_base_id(session)
    turn = Map.get(session, :turn_number, 1)
    "#{base}-turn-#{turn}"
  end

  defp generate_fallback_base_id(%{pi_pid: pid}) when is_binary(pid), do: "pi-#{pid}"
  defp generate_fallback_base_id(_session), do: "pi-#{System.unique_integer([:positive])}"

  defp ensure_dir(path) do
    case File.mkdir_p(path) do
      :ok -> :ok
      {:error, reason} -> {:error, {:session_dir_failed, path, reason}}
    end
  end

  defp issue_context(%{id: issue_id, identifier: identifier}) do
    "issue_id=#{issue_id} issue_identifier=#{identifier}"
  end

  defp issue_context(_issue), do: "unknown issue"

  defp default_on_message(_message), do: :ok
end
