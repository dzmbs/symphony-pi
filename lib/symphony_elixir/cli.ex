defmodule SymphonyElixir.CLI do
  @moduledoc """
  Escript entrypoint for running Symphony with an explicit WORKFLOW.md path.
  """

  alias SymphonyElixir.{LogFile, Pi.Preflight, Workflow}

  @acknowledgement_switch :i_understand_that_this_will_be_running_without_the_usual_guardrails

  @switches [
    {@acknowledgement_switch, :boolean},
    logs_root: :string,
    port: :integer,
    pi_model: :string,
    pi_thinking: :string,
    auto_review: :boolean,
    no_auto_review: :boolean,
    review_model: :string,
    review_thinking: :string
  ]

  @type ensure_started_result :: {:ok, [atom()]} | {:error, term()}
  @type deps :: %{
          file_regular?: (String.t() -> boolean()),
          load_dotenv: (String.t() -> :ok),
          set_workflow_file_path: (String.t() -> :ok | {:error, term()}),
          set_runtime_overrides: (map() -> :ok),
          validate_workflow: (-> :ok | {:error, String.t()}),
          set_logs_root: (String.t() -> :ok | {:error, term()}),
          set_server_port_override: (non_neg_integer() | nil -> :ok | {:error, term()}),
          ensure_all_started: (-> ensure_started_result())
        }

  @spec main([String.t()]) :: no_return()
  def main(args) do
    case evaluate(args) do
      :ok ->
        wait_for_shutdown()

      {:error, message} ->
        IO.puts(:stderr, message)
        System.halt(1)
    end
  end

  @spec evaluate([String.t()], deps()) :: :ok | {:error, String.t()}
  def evaluate(args, deps \\ runtime_deps()) do
    case OptionParser.parse(args, strict: @switches) do
      {opts, [], []} ->
        with :ok <- require_guardrails_acknowledgement(opts),
             :ok <- maybe_set_logs_root(opts, deps),
             :ok <- maybe_set_server_port(opts, deps),
             :ok <- maybe_set_runtime_overrides(opts, deps) do
          run(Path.expand("WORKFLOW.md"), deps)
        end

      {opts, [workflow_path], []} ->
        with :ok <- require_guardrails_acknowledgement(opts),
             :ok <- maybe_set_logs_root(opts, deps),
             :ok <- maybe_set_server_port(opts, deps),
             :ok <- maybe_set_runtime_overrides(opts, deps) do
          run(workflow_path, deps)
        end

      _ ->
        {:error, usage_message()}
    end
  end

  @spec run(String.t(), deps()) :: :ok | {:error, String.t()}
  def run(workflow_path, deps) do
    expanded_path = Path.expand(workflow_path)

    case deps.file_regular?.(expanded_path) do
      true ->
        with :ok <- deps.load_dotenv.(expanded_path),
             :ok <- deps.set_workflow_file_path.(expanded_path),
             :ok <- Map.get(deps, :validate_workflow, fn -> :ok end).() do
          ensure_workflow_started(expanded_path, deps)
        end

      false ->
        {:error, "Workflow file not found: #{expanded_path}"}
    end
  end

  @spec usage_message() :: String.t()
  defp usage_message do
    "Usage: symphony [--logs-root <path>] [--port <port>] [--pi-model <model>] [--pi-thinking <level>] [--auto-review | --no-auto-review] [--review-model <model>] [--review-thinking <level>] [path-to-WORKFLOW.md]"
  end

  @spec runtime_deps() :: deps()
  defp runtime_deps do
    %{
      file_regular?: &File.regular?/1,
      load_dotenv: &load_dotenv_for_workflow/1,
      set_workflow_file_path: &Workflow.set_workflow_file_path/1,
      set_runtime_overrides: &SymphonyElixir.Config.set_runtime_overrides/1,
      validate_workflow: &Preflight.validate_workflow/0,
      set_logs_root: &set_logs_root/1,
      set_server_port_override: &set_server_port_override/1,
      ensure_all_started: fn -> Application.ensure_all_started(:symphony_elixir) end
    }
  end

  defp ensure_workflow_started(expanded_path, deps) do
    case deps.ensure_all_started.() do
      {:ok, _started_apps} ->
        :ok

      {:error, reason} ->
        {:error, "Failed to start Symphony with workflow #{expanded_path}: #{inspect(reason)}"}
    end
  end

  @doc false
  @spec load_dotenv_for_workflow(String.t()) :: :ok
  def load_dotenv_for_workflow(workflow_path) when is_binary(workflow_path) do
    workflow_dir = workflow_path |> Path.dirname() |> Path.expand()
    cwd = File.cwd!() |> Path.expand()

    [Path.join(workflow_dir, ".env"), Path.join(cwd, ".env")]
    |> Enum.uniq()
    |> Enum.each(&load_dotenv_file/1)

    :ok
  end

  defp load_dotenv_file(path) when is_binary(path) do
    case File.read(path) do
      {:ok, body} ->
        body
        |> String.split("\n")
        |> Enum.each(&load_dotenv_line/1)

      {:error, _reason} ->
        :ok
    end
  end

  defp load_dotenv_line(raw_line) when is_binary(raw_line) do
    line = String.trim(raw_line)

    cond do
      line == "" ->
        :ok

      String.starts_with?(line, "#") ->
        :ok

      true ->
        load_dotenv_assignment(line)
    end
  end

  defp load_dotenv_assignment(line) when is_binary(line) do
    case String.split(line, "=", parts: 2) do
      [raw_key, raw_value] ->
        key = String.trim(raw_key)
        value = raw_value |> String.trim() |> trim_matching_quotes()
        maybe_put_dotenv_env(key, value)

      _ ->
        :ok
    end
  end

  defp maybe_put_dotenv_env("", _value), do: :ok

  defp maybe_put_dotenv_env(key, value) when is_binary(key) and is_binary(value) do
    if System.get_env(key) in [nil, ""] do
      System.put_env(key, value)
    end
  end

  defp trim_matching_quotes(value) when is_binary(value) do
    cond do
      String.length(value) >= 2 and String.starts_with?(value, "\"") and String.ends_with?(value, "\"") ->
        String.slice(value, 1, String.length(value) - 2)

      String.length(value) >= 2 and String.starts_with?(value, "'") and String.ends_with?(value, "'") ->
        String.slice(value, 1, String.length(value) - 2)

      true ->
        value
    end
  end

  defp maybe_set_logs_root(opts, deps) do
    case Keyword.get_values(opts, :logs_root) do
      [] ->
        :ok

      values ->
        logs_root = values |> List.last() |> String.trim()

        if logs_root == "" do
          {:error, usage_message()}
        else
          :ok = deps.set_logs_root.(Path.expand(logs_root))
        end
    end
  end

  defp require_guardrails_acknowledgement(opts) do
    if Keyword.get(opts, @acknowledgement_switch, false) do
      :ok
    else
      {:error, acknowledgement_banner()}
    end
  end

  @spec acknowledgement_banner() :: String.t()
  defp acknowledgement_banner do
    lines = [
      "This Symphony implementation is a low key engineering preview.",
      "Pi will run without any guardrails.",
      "SymphonyElixir is not a supported product and is presented as-is.",
      "To proceed, start with `--i-understand-that-this-will-be-running-without-the-usual-guardrails` CLI argument"
    ]

    width = Enum.max(Enum.map(lines, &String.length/1))
    border = String.duplicate("─", width + 2)
    top = "╭" <> border <> "╮"
    bottom = "╰" <> border <> "╯"
    spacer = "│ " <> String.duplicate(" ", width) <> " │"

    content =
      [
        top,
        spacer
        | Enum.map(lines, fn line ->
            "│ " <> String.pad_trailing(line, width) <> " │"
          end)
      ] ++ [spacer, bottom]

    [
      IO.ANSI.red(),
      IO.ANSI.bright(),
      Enum.join(content, "\n"),
      IO.ANSI.reset()
    ]
    |> IO.iodata_to_binary()
  end

  defp set_logs_root(logs_root) do
    Application.put_env(:symphony_elixir, :log_file, LogFile.default_log_file(logs_root))
    :ok
  end

  defp maybe_set_server_port(opts, deps) do
    case Keyword.get_values(opts, :port) do
      [] ->
        :ok

      values ->
        port = List.last(values)

        if is_integer(port) and port >= 0 do
          :ok = deps.set_server_port_override.(port)
        else
          {:error, usage_message()}
        end
    end
  end

  defp maybe_set_runtime_overrides(opts, deps) do
    :ok = deps.set_runtime_overrides.(runtime_overrides_from_opts(opts))
  end

  defp runtime_overrides_from_opts(opts) do
    %{}
    |> maybe_put_nested(:pi, :model, last_non_blank_string(opts, :pi_model))
    |> maybe_put_nested(:pi, :thinking, last_non_blank_string(opts, :pi_thinking))
    |> maybe_put_nested(:auto_review, :enabled, auto_review_override(opts))
    |> maybe_put_nested(:auto_review, :model, last_non_blank_string(opts, :review_model))
    |> maybe_put_nested(:auto_review, :thinking, last_non_blank_string(opts, :review_thinking))
  end

  defp auto_review_override(opts) do
    case {
      auto_review_value(opts),
      List.last(Keyword.get_values(opts, :no_auto_review))
    } do
      {true, _} -> true
      {_, true} -> false
      {false, _} -> false
      _ -> nil
    end
  end

  defp auto_review_value(opts) do
    case List.last(Keyword.get_values(opts, :auto_review)) do
      value when value in [true, false] -> value
      _ -> nil
    end
  end

  defp last_non_blank_string(opts, key) do
    case List.last(Keyword.get_values(opts, key)) do
      value when is_binary(value) ->
        trimmed = String.trim(value)
        if trimmed == "", do: nil, else: trimmed

      _ ->
        nil
    end
  end

  defp maybe_put_nested(overrides, _section, _key, nil), do: overrides

  defp maybe_put_nested(overrides, section, key, value) do
    Map.update(overrides, section, %{key => value}, &Map.put(&1, key, value))
  end

  defp set_server_port_override(port) when is_integer(port) and port >= 0 do
    Application.put_env(:symphony_elixir, :server_port_override, port)
    :ok
  end

  @spec wait_for_shutdown() :: no_return()
  defp wait_for_shutdown do
    case Process.whereis(SymphonyElixir.Supervisor) do
      nil ->
        IO.puts(:stderr, "Symphony supervisor is not running")
        System.halt(1)

      pid ->
        ref = Process.monitor(pid)

        receive do
          {:DOWN, ^ref, :process, ^pid, reason} ->
            case reason do
              :normal -> System.halt(0)
              _ -> System.halt(1)
            end
        end
    end
  end
end
