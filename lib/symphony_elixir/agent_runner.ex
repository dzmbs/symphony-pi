defmodule SymphonyElixir.AgentRunner do
  @moduledoc """
  Executes a single Linear issue in its workspace using the configured agent backend.
  """

  require Logger
  alias SymphonyElixir.{Config, Linear.Issue, PromptBuilder, Tracker, Workspace}

  @spec run(map(), pid() | nil, keyword()) :: :ok | no_return()
  def run(issue, update_recipient \\ nil, opts \\ []) do
    worker_host = Keyword.get(opts, :worker_host)
    Logger.info("Starting agent run for #{issue_context(issue)} worker_host=#{worker_host || "local"}")

    if is_pid(update_recipient) and is_binary(worker_host) do
      send(update_recipient, {:worker_runtime_info, issue.id, %{worker_host: worker_host}})
    end

    case Workspace.create_for_issue(issue, worker_host) do
      {:ok, workspace} ->
        try do
          with :ok <- Workspace.run_before_run_hook(workspace, issue, worker_host),
               :ok <- run_agent_turns(workspace, issue, update_recipient, opts) do
            :ok
          else
            {:error, reason} ->
              Logger.error("Agent run failed for #{issue_context(issue)}: #{inspect(reason)}")
              raise RuntimeError, "Agent run failed for #{issue_context(issue)}: #{inspect(reason)}"
          end
        after
          Workspace.run_after_run_hook(workspace, issue, worker_host)
        end

      {:error, reason} ->
        Logger.error("Agent run failed for #{issue_context(issue)}: #{inspect(reason)}")
        raise RuntimeError, "Agent run failed for #{issue_context(issue)}: #{inspect(reason)}"
    end
  end

  defp backend_module do
    Config.backend_module()
  end

  defp agent_message_handler(recipient, issue) do
    fn message ->
      send_agent_update(recipient, issue, message)
    end
  end

  defp send_agent_update(recipient, %Issue{id: issue_id}, message)
       when is_binary(issue_id) and is_pid(recipient) do
    send(recipient, {:runtime_worker_update, issue_id, message})
    :ok
  end

  defp send_agent_update(_recipient, _issue, _message), do: :ok

  defp run_agent_turns(workspace, issue, update_recipient, opts) do
    backend = backend_module()
    max_turns = Keyword.get(opts, :max_turns, Config.settings!().agent.max_turns)
    issue_state_fetcher = Keyword.get(opts, :issue_state_fetcher, &Tracker.fetch_issue_states_by_ids/1)
    latest_session_key = {__MODULE__, :latest_session, make_ref()}

    with {:ok, session} <- backend.start_session(workspace, opts) do
      Process.put(latest_session_key, session)

      try do
        case do_run_agent_turns(
               backend,
               session,
               latest_session_key,
               workspace,
               issue,
               update_recipient,
               opts,
               issue_state_fetcher,
               1,
               max_turns
             ) do
          {:ok, _final_session} ->
            :ok

          {:error, reason, _final_session} ->
            {:error, reason}

          {:error, reason} ->
            {:error, reason}
        end
      after
        final_session = Process.get(latest_session_key, session)
        Process.delete(latest_session_key)
        backend.stop_session(final_session)
      end
    end
  end

  defp do_run_agent_turns(backend, session, latest_session_key, workspace, issue, update_recipient, opts, issue_state_fetcher, turn_number, max_turns) do
    prompt = build_turn_prompt(issue, opts, turn_number, max_turns)

    with {:ok, turn_result, updated_session} <-
           backend.run_turn(
             session,
             prompt,
             issue,
             on_message: agent_message_handler(update_recipient, issue)
           ) do
      Process.put(latest_session_key, updated_session)

      Logger.info("Completed agent run for #{issue_context(issue)} session_id=#{turn_result[:session_id]} workspace=#{workspace} turn=#{turn_number}/#{max_turns}")

      case continue_with_issue?(issue, issue_state_fetcher) do
        {:continue, refreshed_issue} when turn_number < max_turns ->
          Logger.info("Continuing agent run for #{issue_context(refreshed_issue)} after normal turn completion turn=#{turn_number}/#{max_turns}")

          do_run_agent_turns(
            backend,
            updated_session,
            latest_session_key,
            workspace,
            refreshed_issue,
            update_recipient,
            opts,
            issue_state_fetcher,
            turn_number + 1,
            max_turns
          )

        {:continue, refreshed_issue} ->
          Logger.info("Reached agent.max_turns for #{issue_context(refreshed_issue)} with issue still active; returning control to orchestrator")

          {:ok, updated_session}

        {:done, _refreshed_issue} ->
          {:ok, updated_session}

        {:error, reason} ->
          {:error, reason, updated_session}
      end
    end
  end

  defp build_turn_prompt(issue, opts, 1, _max_turns), do: PromptBuilder.build_prompt(issue, opts)

  defp build_turn_prompt(_issue, _opts, turn_number, max_turns) do
    """
    Continuation guidance:

    - The previous turn completed normally, but the Linear issue is still in an active state.
    - This is continuation turn ##{turn_number} of #{max_turns} for the current agent run.
    - Resume from the current workspace and workpad state instead of restarting from scratch.
    - The original task instructions and prior turn context are already present in this session, so do not restate them before acting.
    - Focus on the remaining ticket work and do not end the turn while the issue stays active unless you are truly blocked.
    """
  end

  defp continue_with_issue?(%Issue{id: issue_id} = issue, issue_state_fetcher) when is_binary(issue_id) do
    case issue_state_fetcher.([issue_id]) do
      {:ok, [%Issue{} = refreshed_issue | _]} ->
        if active_issue_state?(refreshed_issue.state) do
          {:continue, refreshed_issue}
        else
          {:done, refreshed_issue}
        end

      {:ok, []} ->
        {:done, issue}

      {:error, reason} ->
        {:error, {:issue_state_refresh_failed, reason}}
    end
  end

  defp continue_with_issue?(issue, _issue_state_fetcher), do: {:done, issue}

  defp active_issue_state?(state_name) when is_binary(state_name) do
    normalized_state = normalize_issue_state(state_name)

    Config.settings!().tracker.active_states
    |> Enum.any?(fn active_state -> normalize_issue_state(active_state) == normalized_state end)
  end

  defp active_issue_state?(_state_name), do: false

  defp normalize_issue_state(state_name) when is_binary(state_name) do
    state_name
    |> String.trim()
    |> String.downcase()
  end

  defp issue_context(%Issue{id: issue_id, identifier: identifier}) do
    "issue_id=#{issue_id} issue_identifier=#{identifier}"
  end
end
