defmodule SymphonyElixir.Setup do
  @moduledoc """
  Interactive onboarding for connecting a repository to Symphony Pi.
  """

  alias SymphonyElixir.Pi.Preflight

  @default_workspace_root "~/code/symphony-workspaces"
  @default_pi_command "pi"
  @default_pi_thinking "high"
  @default_review_thinking "medium"
  @default_max_rework_passes 1
  @default_active_states ["Todo", "In Progress", "Merging", "Rework"]
  @default_terminal_states ["Closed", "Cancelled", "Canceled", "Duplicate", "Done"]
  @default_prompt ~S"""
  You are working on a Linear ticket `{{ issue.identifier }}`

  {% if attempt %}
  Continuation context:

  - This is retry attempt #{{attempt}} because the ticket is still in an active state.
  - Resume from the current workspace state instead of restarting from scratch.
  - Do not repeat already-completed investigation or validation unless needed for new code changes.
  - Do not end the turn while the issue remains in an active state unless you are blocked by missing required permissions/secrets.
    {% endif %}

  Issue context:
  Identifier: {{ issue.identifier }}
  Title: {{ issue.title }}
  Current status: {{ issue.state }}
  Labels: {{ issue.labels }}
  URL: {{ issue.url }}

  Description:
  {% if issue.description %}
  {{ issue.description }}
  {% else %}
  No description provided.
  {% endif %}

  Instructions:

  1. This is an unattended orchestration session. Never ask a human to perform follow-up actions.
  2. Only stop early for a true blocker (missing required auth/permissions/secrets). If blocked, record it in the workpad and move the issue according to workflow.
  3. Final message must report completed actions and blockers only. Do not include "next steps for user".

  Work only in the provided repository copy. Do not touch any other path.
  """

  @type deps :: %{
          current_dir: (-> String.t()),
          expand_path: (String.t() -> String.t()),
          read_file: (String.t() -> {:ok, String.t()} | {:error, term()}),
          write_file: (String.t(), String.t() -> :ok | {:error, term()}),
          file_regular?: (String.t() -> boolean()),
          get_env: (String.t() -> String.t() | nil),
          find_executable: (String.t() -> String.t() | nil),
          io_gets: (String.t() -> String.t() | nil),
          io_puts: (String.t() -> any()),
          run_cmd: (String.t(), [String.t()], keyword() -> {String.t(), non_neg_integer()}),
          available_models: (String.t() -> {:ok, MapSet.t(String.t())} | {:error, term()})
        }

  @type answers :: %{
          project_slug: String.t(),
          workspace_root: String.t(),
          implementation_model: String.t(),
          auto_review_enabled: boolean(),
          review_model: String.t() | nil,
          create_agents_file: boolean()
        }

  @spec run(String.t(), deps()) :: :ok | {:error, String.t()}
  def run(repo_path, deps \\ runtime_deps()) when is_binary(repo_path) do
    with {:ok, repo_root} <- repo_root(repo_path, deps),
         :ok <- require_env("LINEAR_API_KEY", deps),
         :ok <- require_executable(@default_pi_command, deps),
         {:ok, origin_url} <- origin_url(repo_root, deps),
         {:ok, models} <- available_models(deps),
         {:ok, answers} <- collect_answers(models, deps),
         :ok <- maybe_install_skills(repo_root, deps),
         :ok <- write_workflow(repo_root, answers, deps),
         :ok <- maybe_write_agents_file(repo_root, answers, deps) do
      print_summary(repo_root, origin_url, answers, deps)
      :ok
    end
  end

  defp runtime_deps do
    %{
      current_dir: &File.cwd!/0,
      expand_path: &Path.expand/1,
      read_file: &File.read/1,
      write_file: fn path, body ->
        path |> Path.dirname() |> File.mkdir_p!()
        File.write(path, body)
      end,
      file_regular?: &File.regular?/1,
      get_env: &System.get_env/1,
      find_executable: &System.find_executable/1,
      io_gets: &IO.gets/1,
      io_puts: &IO.puts/1,
      run_cmd: &System.cmd/3,
      available_models: &Preflight.available_model_ids/1
    }
  end

  defp repo_root(repo_path, deps) do
    expanded = deps.expand_path.(repo_path)

    case deps.run_cmd.("git", ["-C", expanded, "rev-parse", "--show-toplevel"], stderr_to_stdout: true) do
      {output, 0} ->
        {:ok, String.trim(output)}

      {output, _code} ->
        {:error, "Setup requires a git repository. `git rev-parse` failed for #{expanded}: #{String.trim(output)}"}
    end
  end

  defp require_env(name, deps) do
    if deps.get_env.(name) in [nil, ""] do
      {:error, "Missing required environment variable #{name}. Export it before running `symphony setup`."}
    else
      :ok
    end
  end

  defp require_executable(name, deps) do
    if deps.find_executable.(name) do
      :ok
    else
      {:error, "Could not find required executable #{inspect(name)} in PATH."}
    end
  end

  defp origin_url(repo_root, deps) do
    case deps.run_cmd.("git", ["-C", repo_root, "remote", "get-url", "origin"], stderr_to_stdout: true) do
      {output, 0} ->
        {:ok, String.trim(output)}

      {output, _code} ->
        {:error, "Could not read git origin for #{repo_root}. Symphony Pi setup expects the target repo to have an `origin` remote. #{String.trim(output)}"}
    end
  end

  defp available_models(deps) do
    case deps.available_models.(@default_pi_command) do
      {:ok, models} when is_struct(models, MapSet) ->
        case MapSet.size(models) do
          size when size > 0 ->
            {:ok, models |> MapSet.to_list() |> Enum.sort()}

          _ ->
            {:error, "Pi did not report any available models."}
        end

      {:error, reason} ->
        {:error, "Could not query Pi models during setup: #{inspect(reason)}"}
    end
  end

  defp collect_answers(models, deps) do
    deps.io_puts.("")
    deps.io_puts.("Symphony Pi setup")
    deps.io_puts.("-----------------")
    deps.io_puts.("Pi reported these models:")
    Enum.each(models, &deps.io_puts.("  - #{&1}"))
    deps.io_puts.("")

    with {:ok, project_slug} <- prompt_required("Linear project slug: ", deps),
         {:ok, workspace_root} <- prompt_with_default("Workspace root", @default_workspace_root, deps),
         {:ok, implementation_model} <- prompt_model("Implementation model", preferred_implementation_model(models), models, deps),
         {:ok, auto_review_enabled} <- prompt_yes_no("Enable internal auto-review?", false, deps),
         {:ok, review_model} <- maybe_prompt_review_model(auto_review_enabled, models, implementation_model, deps),
         {:ok, create_agents_file} <- prompt_yes_no("Create a minimal AGENTS.md starter?", false, deps) do
      {:ok,
       %{
         project_slug: project_slug,
         workspace_root: workspace_root,
         implementation_model: implementation_model,
         auto_review_enabled: auto_review_enabled,
         review_model: review_model,
         create_agents_file: create_agents_file
       }}
    end
  end

  defp maybe_prompt_review_model(false, _models, _implementation_model, _deps), do: {:ok, nil}

  defp maybe_prompt_review_model(true, models, implementation_model, deps) do
    prompt_model("Review model", preferred_review_model(models, implementation_model), models, deps)
  end

  defp maybe_install_skills(repo_root, deps) do
    source = install_source(deps)
    deps.io_puts.("Installing Symphony Pi skills into #{repo_root} ...")

    case deps.run_cmd.(@default_pi_command, ["install", "-l", source], cd: repo_root, stderr_to_stdout: true) do
      {_output, 0} ->
        :ok

      {output, _code} ->
        {:error, "Failed to install Symphony Pi Pi-package into #{repo_root}: #{String.trim(output)}"}
    end
  end

  defp install_source(deps) do
    current_dir = deps.current_dir.()
    package_json = Path.join(current_dir, "package.json")

    case deps.read_file.(package_json) do
      {:ok, body} when is_binary(body) ->
        if body =~ ~s("name": "symphony-pi") do
          current_dir
        else
          "git:github.com/dzmbs/symphony-pi"
        end

      _ ->
        "git:github.com/dzmbs/symphony-pi"
    end
  end

  defp write_workflow(repo_root, answers, deps) do
    workflow_path = Path.join(repo_root, "WORKFLOW.md")

    with :ok <- maybe_backup_existing(workflow_path, deps),
         :ok <- deps.write_file.(workflow_path, workflow_content(answers, deps)) do
      :ok
    else
      {:error, reason} -> {:error, "Failed to write #{workflow_path}: #{inspect(reason)}"}
    end
  end

  defp maybe_backup_existing(path, deps) do
    if deps.file_regular?.(path) do
      backup_path = path <> ".bak"

      case deps.read_file.(path) do
        {:ok, existing} ->
          deps.write_file.(backup_path, existing)

        {:error, reason} ->
          {:error, reason}
      end
    else
      :ok
    end
  end

  defp maybe_write_agents_file(_repo_root, %{create_agents_file: false}, _deps), do: :ok

  defp maybe_write_agents_file(repo_root, _answers, deps) do
    agents_path = Path.join(repo_root, "AGENTS.md")

    if deps.file_regular?.(agents_path) do
      :ok
    else
      case deps.write_file.(agents_path, agents_starter()) do
        :ok -> :ok
        {:error, reason} -> {:error, "Failed to write #{agents_path}: #{inspect(reason)}"}
      end
    end
  end

  defp workflow_content(answers, deps) do
    prompt = prompt_template(deps)

    [
      "---",
      "tracker:",
      "  kind: linear",
      "  project_slug: #{yaml_value(answers.project_slug)}",
      "  api_key: $LINEAR_API_KEY",
      "  active_states: #{yaml_value(@default_active_states)}",
      "  terminal_states: #{yaml_value(@default_terminal_states)}",
      "polling:",
      "  interval_ms: 5000",
      "workspace:",
      "  root: #{yaml_value(answers.workspace_root)}",
      "hooks:",
      "  after_create: |",
      ~s(    git clone --depth 1 "$SOURCE_REPO_URL" .),
      "agent:",
      "  max_concurrent_agents: 10",
      "  max_turns: 20",
      "agent_runtime:",
      "  backend: pi",
      "pi:",
      "  command: pi",
      "  model: #{yaml_value(answers.implementation_model)}",
      "  thinking: #{@default_pi_thinking}",
      auto_review_yaml(answers),
      "---",
      prompt
    ]
    |> List.flatten()
    |> Enum.reject(&is_nil/1)
    |> Enum.join("\n")
    |> Kernel.<>("\n")
  end

  defp auto_review_yaml(%{auto_review_enabled: false}) do
    [
      "# Optional internal review pass before final human handoff:",
      "# auto_review:",
      "#   enabled: true",
      "#   model: openai/gpt-5.4",
      "#   thinking: medium",
      "#   max_rework_passes: 1",
      "#   fresh_session: true"
    ]
  end

  defp auto_review_yaml(%{auto_review_enabled: true, review_model: review_model}) do
    [
      "auto_review:",
      "  enabled: true",
      "  model: #{yaml_value(review_model)}",
      "  thinking: #{@default_review_thinking}",
      "  max_rework_passes: #{@default_max_rework_passes}",
      "  fresh_session: true"
    ]
  end

  defp prompt_template(deps) do
    source_workflow = Path.join(deps.current_dir.(), "WORKFLOW.md")

    case deps.read_file.(source_workflow) do
      {:ok, body} ->
        {_front_matter, prompt_lines} = split_front_matter(body)
        normalize_prompt_template(prompt_lines)

      _ ->
        @default_prompt
    end
  end

  defp normalize_prompt_template(prompt_lines) do
    case prompt_lines |> Enum.join("\n") |> String.trim() do
      "" -> @default_prompt
      prompt -> prompt
    end
  end

  defp split_front_matter(content) do
    lines = String.split(content, ~r/\R/, trim: false)

    case lines do
      ["---" | tail] ->
        {front, rest} = Enum.split_while(tail, &(&1 != "---"))

        case rest do
          ["---" | prompt_lines] -> {front, prompt_lines}
          _ -> {front, []}
        end

      _ ->
        {[], lines}
    end
  end

  defp agents_starter do
    """
    # AGENTS.md

    Repository guidance for Pi and Symphony Pi runs.

    - Follow the repository's existing style and structure.
    - Run the narrowest validation that proves the change.
    - Avoid unrelated refactors during ticket work.
    - Do not edit generated files unless the ticket explicitly requires it.
    - Add project-specific build, test, and architectural notes below.
    """
  end

  defp print_summary(repo_root, origin_url, answers, deps) do
    workflow_path = Path.join(repo_root, "WORKFLOW.md")

    deps.io_puts.("")
    deps.io_puts.("Symphony Pi setup complete.")
    deps.io_puts.("Repository: #{repo_root}")
    deps.io_puts.("Origin: #{origin_url}")
    deps.io_puts.("Workflow: #{workflow_path}")
    deps.io_puts.("Implementation model: #{answers.implementation_model}")

    if answers.auto_review_enabled do
      deps.io_puts.("Auto-review: enabled (#{answers.review_model})")
    else
      deps.io_puts.("Auto-review: disabled")
    end

    deps.io_puts.("")
    deps.io_puts.("Required Linear states: Todo, In Progress, Rework, Human Review, Merging, Done")
    deps.io_puts.("")
    deps.io_puts.("Run Symphony Pi with:")
    deps.io_puts.("./bin/symphony #{workflow_path} --i-understand-that-this-will-be-running-without-the-usual-guardrails --port 4050")
  end

  defp preferred_implementation_model(models) do
    preferred_model(models, ["anthropic/claude-opus-4-6", "openai/gpt-5.4", "anthropic/claude-sonnet-4-5", "openai/gpt-5"])
  end

  defp preferred_review_model(models, implementation_model) do
    preferred_model(models, ["openai/gpt-5.4", "anthropic/claude-opus-4-6", implementation_model, "openai/gpt-5"])
  end

  defp preferred_model(models, preferences) do
    Enum.find(preferences, &(&1 in models)) || List.first(models)
  end

  defp prompt_required(label, deps) do
    case deps.io_gets.(label) do
      nil ->
        {:error, "Setup aborted while reading input."}

      value ->
        trimmed = String.trim(value)
        if trimmed == "", do: prompt_required(label, deps), else: {:ok, trimmed}
    end
  end

  defp prompt_with_default(label, default, deps) do
    case deps.io_gets.("#{label} [#{default}]: ") do
      nil ->
        {:error, "Setup aborted while reading input."}

      value ->
        trimmed = String.trim(value)
        {:ok, if(trimmed == "", do: default, else: trimmed)}
    end
  end

  defp prompt_model(label, default, models, deps) do
    with {:ok, selected} <- prompt_with_default(label, default, deps) do
      if selected in models do
        {:ok, selected}
      else
        deps.io_puts.("Choose one of the models reported by Pi.")
        prompt_model(label, default, models, deps)
      end
    end
  end

  defp prompt_yes_no(label, default, deps) do
    default_label = if(default, do: "Y/n", else: "y/N")

    case deps.io_gets.("#{label} [#{default_label}]: ") do
      nil ->
        {:error, "Setup aborted while reading input."}

      value ->
        case parse_yes_no_response(value, default) do
          {:ok, answer} -> {:ok, answer}
          :retry -> prompt_yes_no(label, default, deps)
        end
    end
  end

  defp parse_yes_no_response(value, default) when is_binary(value) do
    case String.trim(value) |> String.downcase() do
      "" -> {:ok, default}
      "y" -> {:ok, true}
      "yes" -> {:ok, true}
      "n" -> {:ok, false}
      "no" -> {:ok, false}
      _ -> :retry
    end
  end

  defp yaml_value(value) when is_binary(value) do
    escaped =
      value
      |> String.replace("\\", "\\\\")
      |> String.replace("\"", "\\\"")

    ~s("#{escaped}")
  end

  defp yaml_value(values) when is_list(values) do
    "[" <> Enum.map_join(values, ", ", &yaml_value/1) <> "]"
  end
end
