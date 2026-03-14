defmodule SymphonyElixir.Config do
  @moduledoc """
  Runtime configuration loaded from `WORKFLOW.md`.
  """

  alias SymphonyElixir.Config.Schema
  alias SymphonyElixir.Workflow

  @default_prompt_template """
  You are working on a Linear issue.

  Identifier: {{ issue.identifier }}
  Title: {{ issue.title }}

  Body:
  {% if issue.description %}
  {{ issue.description }}
  {% else %}
  No description provided.
  {% endif %}
  """

  @spec settings() :: {:ok, Schema.t()} | {:error, term()}
  def settings do
    case Workflow.current() do
      {:ok, %{config: config}} when is_map(config) ->
        with {:ok, settings} <- Schema.parse(config) do
          {:ok, apply_runtime_overrides(settings)}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  @spec settings!() :: Schema.t()
  def settings! do
    case settings() do
      {:ok, settings} ->
        settings

      {:error, reason} ->
        raise ArgumentError, message: format_config_error(reason)
    end
  end

  @spec max_concurrent_agents_for_state(term()) :: pos_integer()
  def max_concurrent_agents_for_state(state_name) when is_binary(state_name) do
    config = settings!()

    Map.get(
      config.agent.max_concurrent_agents_by_state,
      Schema.normalize_issue_state(state_name),
      config.agent.max_concurrent_agents
    )
  end

  def max_concurrent_agents_for_state(_state_name), do: settings!().agent.max_concurrent_agents

  @doc """
  Returns the agent backend module based on the `agent_runtime.backend` config.

  Defaults to `SymphonyElixir.Pi.RpcBackend`.
  """
  @spec backend_module() :: module()
  def backend_module do
    case Application.get_env(:symphony_elixir, :backend_module_override) do
      module when is_atom(module) and not is_nil(module) ->
        module

      _ ->
        SymphonyElixir.Pi.RpcBackend
    end
  end

  @spec workflow_prompt() :: String.t()
  def workflow_prompt do
    case Workflow.current() do
      {:ok, %{prompt_template: prompt}} ->
        if String.trim(prompt) == "", do: @default_prompt_template, else: prompt

      _ ->
        @default_prompt_template
    end
  end

  @spec server_port() :: non_neg_integer() | nil
  def server_port do
    case Application.get_env(:symphony_elixir, :server_port_override) do
      port when is_integer(port) and port >= 0 -> port
      _ -> settings!().server.port
    end
  end

  @spec validate!() :: :ok | {:error, term()}
  def validate! do
    with {:ok, settings} <- settings() do
      validate_semantics(settings)
    end
  end

  @spec set_runtime_overrides(map()) :: :ok
  def set_runtime_overrides(overrides) when is_map(overrides) do
    Application.put_env(:symphony_elixir, :workflow_runtime_overrides, overrides)
    :ok
  end

  @spec clear_runtime_overrides() :: :ok
  def clear_runtime_overrides do
    Application.delete_env(:symphony_elixir, :workflow_runtime_overrides)
    :ok
  end

  defp validate_semantics(settings) do
    cond do
      is_nil(settings.tracker.kind) ->
        {:error, :missing_tracker_kind}

      settings.tracker.kind not in ["linear", "memory"] ->
        {:error, {:unsupported_tracker_kind, settings.tracker.kind}}

      settings.tracker.kind == "linear" and not is_binary(settings.tracker.api_key) ->
        {:error, :missing_linear_api_token}

      settings.tracker.kind == "linear" and not is_binary(settings.tracker.project_slug) ->
        {:error, :missing_linear_project_slug}

      true ->
        :ok
    end
  end

  defp format_config_error(reason) do
    case reason do
      {:invalid_workflow_config, message} ->
        "Invalid WORKFLOW.md config: #{message}"

      {:missing_workflow_file, path, raw_reason} ->
        "Missing WORKFLOW.md at #{path}: #{inspect(raw_reason)}"

      {:workflow_parse_error, raw_reason} ->
        "Failed to parse WORKFLOW.md: #{inspect(raw_reason)}"

      :workflow_front_matter_not_a_map ->
        "Failed to parse WORKFLOW.md: workflow front matter must decode to a map"

      other ->
        "Invalid WORKFLOW.md config: #{inspect(other)}"
    end
  end

  defp apply_runtime_overrides(settings) do
    overrides = Application.get_env(:symphony_elixir, :workflow_runtime_overrides, %{})

    settings
    |> apply_pi_overrides(Map.get(overrides, :pi, %{}))
    |> apply_auto_review_overrides(Map.get(overrides, :auto_review, %{}))
  end

  defp apply_pi_overrides(settings, overrides) when map_size(overrides) == 0, do: settings

  defp apply_pi_overrides(settings, overrides) do
    pi =
      settings.pi
      |> maybe_override(:model, overrides)
      |> maybe_override(:thinking, overrides)

    %{settings | pi: pi}
  end

  defp apply_auto_review_overrides(settings, overrides) when map_size(overrides) == 0, do: settings

  defp apply_auto_review_overrides(settings, overrides) do
    auto_review =
      settings.auto_review
      |> maybe_override(:enabled, overrides)
      |> maybe_override(:model, overrides)
      |> maybe_override(:thinking, overrides)

    %{settings | auto_review: auto_review}
  end

  defp maybe_override(struct, key, overrides) do
    case Map.fetch(overrides, key) do
      {:ok, value} -> Map.put(struct, key, value)
      :error -> struct
    end
  end
end
