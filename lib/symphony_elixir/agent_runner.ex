defmodule SymphonyElixir.AgentRunner do
  @moduledoc """
  Executes a single Linear issue in its workspace using the configured agent backend.
  """

  require Logger
  alias SymphonyElixir.{AutoReview, Config, Linear.Issue, PromptBuilder, Tracker, Workspace}

  @type worker_host :: String.t() | nil

  @spec run(map(), pid() | nil, keyword()) :: :ok | no_return()
  def run(issue, update_recipient \\ nil, opts \\ []) do
    worker_hosts =
      candidate_worker_hosts(Keyword.get(opts, :worker_host), Config.settings!().worker.ssh_hosts)

    Logger.info("Starting agent run for #{issue_context(issue)} worker_hosts=#{inspect(worker_hosts_for_log(worker_hosts))}")

    case run_on_worker_hosts(issue, update_recipient, opts, worker_hosts) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.error("Agent run failed for #{issue_context(issue)}: #{inspect(reason)}")
        raise RuntimeError, "Agent run failed for #{issue_context(issue)}: #{inspect(reason)}"
    end
  end

  defp run_on_worker_hosts(issue, update_recipient, opts, [worker_host | rest]) do
    case run_on_worker_host(issue, update_recipient, opts, worker_host) do
      :ok ->
        :ok

      {:error, reason} when rest != [] ->
        Logger.warning("Agent run failed for #{issue_context(issue)} worker_host=#{worker_host_for_log(worker_host)} reason=#{inspect(reason)}; trying next worker host")

        run_on_worker_hosts(issue, update_recipient, opts, rest)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp run_on_worker_hosts(_issue, _update_recipient, _opts, []), do: {:error, :no_worker_hosts_available}

  defp run_on_worker_host(issue, update_recipient, opts, worker_host) do
    Logger.info("Starting worker attempt for #{issue_context(issue)} worker_host=#{worker_host_for_log(worker_host)}")

    case Workspace.create_for_issue(issue, worker_host) do
      {:ok, workspace} ->
        send_worker_runtime_info(update_recipient, issue, worker_host, workspace)

        try do
          with :ok <- Workspace.run_before_run_hook(workspace, issue, worker_host) do
            run_agent_turns(workspace, issue, update_recipient, Keyword.put(opts, :worker_host, worker_host))
          end
        after
          Workspace.run_after_run_hook(workspace, issue, worker_host)
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp backend_module do
    Config.backend_module()
  end

  defp send_worker_runtime_info(recipient, %Issue{id: issue_id}, worker_host, workspace)
       when is_binary(issue_id) and is_pid(recipient) and is_binary(workspace) do
    send(
      recipient,
      {:worker_runtime_info, issue_id,
       %{
         worker_host: worker_host,
         workspace_path: workspace
       }}
    )

    :ok
  end

  defp send_worker_runtime_info(_recipient, _issue, _worker_host, _workspace), do: :ok

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
    implementation_prompt_builder = &build_implementation_turn_prompt(&1, opts, &2, &3)

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
               implementation_prompt_builder,
               1,
               max_turns
             ) do
          {:ok, final_session, final_issue} ->
            Process.put(latest_session_key, final_session)

            case maybe_run_auto_review(
                   backend,
                   final_session,
                   workspace,
                   final_issue,
                   update_recipient,
                   opts,
                   issue_state_fetcher
                 ) do
              {:ok, reviewed_session} ->
                Process.put(latest_session_key, reviewed_session)
                :ok
            end

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

  defp do_run_agent_turns(backend, session, latest_session_key, workspace, issue, update_recipient, opts, issue_state_fetcher, prompt_builder, turn_number, max_turns) do
    prompt = prompt_builder.(issue, turn_number, max_turns)

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
            prompt_builder,
            turn_number + 1,
            max_turns
          )

        {:continue, refreshed_issue} ->
          Logger.info("Reached agent.max_turns for #{issue_context(refreshed_issue)} with issue still active; returning control to orchestrator")

          {:ok, updated_session, refreshed_issue}

        {:done, refreshed_issue} ->
          {:ok, updated_session, refreshed_issue}

        {:error, reason} ->
          {:error, reason, updated_session}
      end
    end
  end

  defp maybe_run_auto_review(
         backend,
         session,
         workspace,
         issue,
         update_recipient,
         opts,
         issue_state_fetcher
       ) do
    settings = Config.settings!()

    cond do
      not AutoReview.enabled?(settings) ->
        {:ok, session}

      not review_ready_state?(issue.state) ->
        {:ok, session}

      true ->
        send_agent_update(update_recipient, issue, auto_review_update("auto-review started"))

        run_review_pass(backend, workspace, issue, update_recipient, opts, settings)
        |> handle_auto_review_result(
          session,
          issue,
          update_recipient,
          issue_state_fetcher
        )
    end
  end

  defp run_review_pass(backend, workspace, issue, update_recipient, opts, settings) do
    review_opts =
      opts
      |> Keyword.put(:runtime_config, AutoReview.runtime_overrides(settings))
      |> Keyword.put(:no_session, settings.auto_review.fresh_session == true)
      |> Keyword.put(:tool_profile, :review)

    with {:ok, review_session} <- backend.start_session(workspace, review_opts) do
      try do
        case backend.run_turn(
               review_session,
               AutoReview.build_review_prompt(issue),
               issue,
               Keyword.put(review_opts, :on_message, agent_message_handler(update_recipient, issue))
             ) do
          {:ok, turn_result, updated_review_session} ->
            Process.put({__MODULE__, :latest_review_session}, updated_review_session)
            parse_review_result(turn_result)

          {:error, reason} ->
            {:error, reason}
        end
      after
        final_review_session = Process.get({__MODULE__, :latest_review_session}, review_session)
        Process.delete({__MODULE__, :latest_review_session})
        backend.stop_session(final_review_session)
      end
    end
  end

  defp parse_review_result(%{assistant_text: assistant_text}) when is_binary(assistant_text) do
    AutoReview.parse_verdict(assistant_text)
  end

  defp parse_review_result(_turn_result), do: {:error, :missing_review_output}

  defp refresh_issue_with_state(%Issue{id: issue_id} = issue, issue_state_fetcher, fallback_state)
       when is_binary(issue_id) do
    case issue_state_fetcher.([issue_id]) do
      {:ok, [%Issue{} = refreshed_issue | _]} ->
        {:ok, %{refreshed_issue | state: fallback_state}}

      {:ok, []} ->
        {:ok, %{issue | state: fallback_state}}

      {:error, reason} ->
        {:error, {:issue_state_refresh_failed, reason}}
    end
  end

  defp review_ready_state?(state_name) when is_binary(state_name) do
    normalize_issue_state(state_name) == normalize_issue_state(AutoReview.agent_review_state())
  end

  defp review_ready_state?(_state_name), do: false

  defp auto_review_update(message) do
    %{
      event: :notification,
      timestamp: DateTime.utc_now(),
      raw: message
    }
  end

  defp build_implementation_turn_prompt(issue, opts, 1, _max_turns),
    do: PromptBuilder.build_prompt(issue, Keyword.put(opts, :auto_review_enabled, AutoReview.enabled?()))

  defp build_implementation_turn_prompt(_issue, _opts, turn_number, max_turns) do
    """
    Continuation guidance:

    - The previous turn completed normally, but the Linear issue is still in an active state.
    - This is continuation turn ##{turn_number} of #{max_turns} for the current agent run.
    - Resume from the current workspace and workpad state instead of restarting from scratch.
    - The original task instructions and prior turn context are already present in this session, so do not restate them before acting.
    - Focus on the remaining ticket work and do not end the turn while the issue stays active unless you are truly blocked.
    """
  end

  defp handle_auto_review_result(
         {:ok, %{status: :pass} = verdict},
         session,
         issue,
         update_recipient,
         issue_state_fetcher
       ) do
    Logger.info("Auto-review passed for #{issue_context(issue)} summary=#{inspect(verdict.summary)}")
    handle_review_handoff(issue, verdict, update_recipient, issue_state_fetcher, session)
  end

  defp handle_auto_review_result(
         {:ok, %{status: :changes_requested} = verdict},
         session,
         issue,
         update_recipient,
         issue_state_fetcher
       ) do
    Logger.info(
      "Auto-review requested changes for #{issue_context(issue)} " <>
        "findings=#{length(verdict.findings)}"
    )

    handle_review_handoff(issue, verdict, update_recipient, issue_state_fetcher, session)
  end

  defp handle_auto_review_result(
         {:error, reason},
         session,
         issue,
         update_recipient,
         issue_state_fetcher
       ) do
    Logger.warning(
      "Auto-review failed for #{issue_context(issue)} reason=#{inspect(reason)}; moving issue to " <>
        "#{AutoReview.human_review_state()} for manual follow-up"
    )

    handle_failed_review_handoff(issue, reason, update_recipient, issue_state_fetcher, session)
  end

  defp handle_review_handoff(issue, verdict, update_recipient, issue_state_fetcher, session) do
    comment_result = persist_review_handoff(issue, verdict)

    case transition_to_human_review(issue, issue_state_fetcher) do
      {:ok, _refreshed_issue} ->
        send_agent_update(
          update_recipient,
          issue,
          auto_review_update(review_handoff_message(verdict, comment_result))
        )

      {:error, reason} ->
        Logger.warning(
          "Auto-review completed for #{issue_context(issue)} but could not move issue to " <>
            "#{AutoReview.human_review_state()}: #{inspect(reason)}"
        )

        send_agent_update(
          update_recipient,
          issue,
          auto_review_update("auto-review completed but failed to move issue to Human Review")
        )
    end

    {:ok, session}
  end

  defp handle_failed_review_handoff(issue, reason, update_recipient, issue_state_fetcher, session) do
    comment_result = persist_failed_review_handoff(issue, reason)

    case transition_to_human_review(issue, issue_state_fetcher) do
      {:ok, _refreshed_issue} ->
        send_agent_update(
          update_recipient,
          issue,
          auto_review_update(failed_review_handoff_message(comment_result))
        )

      {:error, transition_reason} ->
        Logger.warning(
          "Auto-review failed for #{issue_context(issue)} and could not move issue to " <>
            "#{AutoReview.human_review_state()}: #{inspect(transition_reason)}"
        )

        send_agent_update(
          update_recipient,
          issue,
          auto_review_update("auto-review failed and could not move issue to Human Review")
        )
    end

    {:ok, session}
  end

  defp transition_to_human_review(%Issue{id: issue_id} = issue, issue_state_fetcher) when is_binary(issue_id) do
    with :ok <- Tracker.update_issue_state(issue_id, AutoReview.human_review_state()) do
      refresh_issue_with_state(issue, issue_state_fetcher, AutoReview.human_review_state())
    end
  end

  defp transition_to_human_review(_issue, _issue_state_fetcher), do: {:error, :missing_issue_id}

  defp persist_review_handoff(%Issue{id: issue_id} = issue, verdict) when is_binary(issue_id) do
    Tracker.create_comment(issue_id, AutoReview.build_handoff_comment(issue, verdict))
  end

  defp persist_review_handoff(_issue, _verdict), do: {:error, :missing_issue_id}

  defp persist_failed_review_handoff(%Issue{id: issue_id} = issue, reason) when is_binary(issue_id) do
    Tracker.create_comment(issue_id, AutoReview.build_failed_handoff_comment(issue, reason))
  end

  defp persist_failed_review_handoff(_issue, _reason), do: {:error, :missing_issue_id}

  defp review_handoff_message(%{status: :pass}, :ok),
    do: "auto-review passed; posted verdict and moved issue to Human Review"

  defp review_handoff_message(%{status: :pass}, {:error, _reason}),
    do: "auto-review passed; failed to post verdict comment but moved issue to Human Review"

  defp review_handoff_message(%{status: :changes_requested}, :ok),
    do: "auto-review requested changes; posted findings and moved issue to Human Review"

  defp review_handoff_message(%{status: :changes_requested}, {:error, _reason}),
    do: "auto-review requested changes; failed to post findings comment but moved issue to Human Review"

  defp failed_review_handoff_message(:ok),
    do: "auto-review failed; posted failure note and moved issue to Human Review"

  defp failed_review_handoff_message({:error, _reason}),
    do: "auto-review failed; could not post failure note but moved issue to Human Review"

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

  defp candidate_worker_hosts(nil, []), do: [nil]

  defp candidate_worker_hosts(preferred_host, configured_hosts) when is_list(configured_hosts) do
    hosts =
      configured_hosts
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))
      |> Enum.uniq()

    case preferred_host do
      host when is_binary(host) and host != "" ->
        [host | Enum.reject(hosts, &(&1 == host))]

      _ when hosts == [] ->
        [nil]

      _ ->
        hosts
    end
  end

  defp worker_hosts_for_log(worker_hosts) do
    Enum.map(worker_hosts, &worker_host_for_log/1)
  end

  defp worker_host_for_log(nil), do: "local"
  defp worker_host_for_log(worker_host), do: worker_host

  defp normalize_issue_state(state_name) when is_binary(state_name) do
    state_name
    |> String.trim()
    |> String.downcase()
  end

  defp issue_context(%Issue{id: issue_id, identifier: identifier}) do
    "issue_id=#{issue_id} issue_identifier=#{identifier}"
  end
end
