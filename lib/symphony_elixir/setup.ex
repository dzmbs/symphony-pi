defmodule SymphonyElixir.Setup do
  @moduledoc """
  Interactive onboarding for connecting a repository to Symphony Pi.
  """

  alias SymphonyElixir.Pi.Preflight

  @linear_endpoint "https://api.linear.app/graphql"
  @required_workflow_states ["Todo", "In Progress", "Rework", "Human Review", "Merging", "Done"]
  @default_workspace_root "~/code/symphony-workspaces"
  @default_pi_command "pi"
  @default_pi_package "@mariozechner/pi-coding-agent"
  @default_pi_thinking "high"
  @default_review_thinking "medium"
  @default_max_rework_passes 1
  @default_active_states ["Todo", "In Progress", "Merging", "Rework"]
  @default_terminal_states ["Closed", "Cancelled", "Canceled", "Duplicate", "Done"]
  @oauth_login_providers MapSet.new([
                           "anthropic",
                           "openai-codex",
                           "github-copilot",
                           "google-gemini-cli",
                           "google-antigravity"
                         ])
  @provider_env_vars %{
    "amazon-bedrock" => ["AWS_BEARER_TOKEN_BEDROCK", "AWS_PROFILE", "AWS_ACCESS_KEY_ID"],
    "anthropic" => ["ANTHROPIC_API_KEY", "ANTHROPIC_OAUTH_TOKEN"],
    "azure-openai-responses" => ["AZURE_OPENAI_API_KEY"],
    "cerebras" => ["CEREBRAS_API_KEY"],
    "github-copilot" => ["COPILOT_GITHUB_TOKEN", "GH_TOKEN", "GITHUB_TOKEN"],
    "google" => ["GEMINI_API_KEY"],
    "google-vertex" => ["GOOGLE_CLOUD_API_KEY"],
    "groq" => ["GROQ_API_KEY"],
    "huggingface" => ["HF_TOKEN"],
    "kimi-coding" => ["KIMI_API_KEY"],
    "minimax" => ["MINIMAX_API_KEY"],
    "minimax-cn" => ["MINIMAX_CN_API_KEY"],
    "mistral" => ["MISTRAL_API_KEY"],
    "opencode" => ["OPENCODE_API_KEY"],
    "opencode-go" => ["OPENCODE_API_KEY"],
    "openai" => ["OPENAI_API_KEY"],
    "openai-codex" => ["OPENAI_API_KEY"],
    "openrouter" => ["OPENROUTER_API_KEY"],
    "vercel-ai-gateway" => ["AI_GATEWAY_API_KEY"],
    "xai" => ["XAI_API_KEY"],
    "zai" => ["ZAI_API_KEY"]
  }
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
  @linear_projects_query """
  query SymphonySetupProjects {
    projects(first: 100) {
      nodes {
        name
        slugId
        teams(first: 10) {
          nodes {
            name
            key
            states(first: 50) {
              nodes {
                name
                type
              }
            }
          }
        }
      }
    }
  }
  """
  @linear_project_query """
  query SymphonySetupProjectBySlug($slugId: String!) {
    projects(filter: {slugId: {eq: $slugId}}, first: 1) {
      nodes {
        name
        slugId
        teams(first: 10) {
          nodes {
            name
            key
            states(first: 50) {
              nodes {
                name
                type
              }
            }
          }
        }
      }
    }
  }
  """

  @type deps :: %{
          current_dir: (-> String.t()),
          expand_path: (String.t() -> String.t()),
          read_file: (String.t() -> {:ok, String.t()} | {:error, term()}),
          write_file: (String.t(), String.t() -> :ok | {:error, term()}),
          file_regular?: (String.t() -> boolean()),
          get_env: (String.t() -> String.t() | nil),
          put_env: (String.t(), String.t() -> any()),
          find_executable: (String.t() -> String.t() | nil),
          io_gets: (String.t() -> String.t() | nil),
          io_puts: (String.t() -> any()),
          pi_auth_path: (-> String.t()),
          run_cmd: (String.t(), [String.t()], keyword() -> {String.t(), non_neg_integer()}),
          available_models: (String.t() -> {:ok, MapSet.t(String.t())} | {:error, term()}),
          list_projects: (String.t() -> {:ok, [map()]} | {:error, term()}),
          fetch_project_by_slug: (String.t(), String.t() -> {:ok, map() | nil} | {:error, term()})
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
         workflow_path = Path.join(repo_root, "WORKFLOW.md"),
         {:ok, linear_api_key} <- ensure_linear_api_key(repo_root, deps),
         :ok <- ensure_pi_available(deps),
         {:ok, origin_url} <- origin_url(repo_root, deps),
         {:ok, models} <- available_models(deps),
         {:ok, projects} <- available_projects(linear_api_key, deps),
         :ok <- print_setup_status(repo_root, origin_url, models, projects, workflow_path, deps),
         :ok <- maybe_confirm_workflow_overwrite(workflow_path, deps),
         {:ok, answers} <- collect_answers(linear_api_key, projects, models, deps),
         :ok <- ensure_model_credentials(repo_root, answers, deps),
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
      put_env: &System.put_env/2,
      find_executable: &System.find_executable/1,
      io_gets: &IO.gets/1,
      io_puts: &IO.puts/1,
      pi_auth_path: fn -> Path.expand("~/.pi/agent/auth.json") end,
      run_cmd: &System.cmd/3,
      available_models: &Preflight.available_model_ids/1,
      list_projects: &list_linear_projects/1,
      fetch_project_by_slug: &fetch_linear_project_by_slug/2
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

  defp origin_url(repo_root, deps) do
    case deps.run_cmd.("git", ["-C", repo_root, "remote", "get-url", "origin"], stderr_to_stdout: true) do
      {output, 0} ->
        {:ok, String.trim(output)}

      {output, _code} ->
        {:error,
         "Could not read git origin for #{repo_root}. Symphony Pi setup expects the target repo " <>
           "to have an `origin` remote. #{String.trim(output)}"}
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

  defp available_projects(token, deps) when is_binary(token) do
    case deps.list_projects.(token) do
      {:ok, []} ->
        {:ok, {:manual, "Could not find any Linear projects available to this token."}}

      {:ok, projects} ->
        {:ok, {:loaded, Enum.sort_by(projects, &project_sort_key/1)}}

      {:error, reason} ->
        if manual_project_fallback_allowed?(reason) do
          {:ok, {:manual, format_projects_error(reason)}}
        else
          {:error, "Could not load Linear projects: #{format_projects_error(reason)}"}
        end
    end
  end

  defp collect_answers(linear_api_key, projects, models, deps) do
    deps.io_puts.("")
    deps.io_puts.("Setup choices")
    deps.io_puts.("-------------")

    with {:ok, project_slug} <- prompt_project_slug(linear_api_key, projects, deps),
         {:ok, workspace_root} <- prompt_with_default("Workspace root", @default_workspace_root, deps),
         {:ok, implementation_model} <-
           prompt_model_choice(
             "Implementation model",
             preferred_implementation_model(models),
             models,
             "Used for normal ticket implementation work.",
             deps
           ),
         {:ok, auto_review_enabled} <-
           prompt_yes_no("Enable optional internal auto-review before human handoff?", false, deps),
         {:ok, review_model} <- maybe_prompt_review_model(auto_review_enabled, models, implementation_model, deps),
         {:ok, create_agents_file} <-
           prompt_yes_no("Create a minimal AGENTS.md starter for repo-specific coding guidance?", false, deps) do
      maybe_warn_missing_provider_auth(implementation_model, deps)
      maybe_warn_missing_provider_auth(review_model, deps)

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
    prompt_model_choice(
      "Review model",
      preferred_review_model(models, implementation_model),
      models,
      "Used only for the internal review pass.",
      deps
    )
  end

  defp maybe_install_skills(repo_root, deps) do
    source = install_source(deps)
    deps.io_puts.("Installing Symphony Pi skills into #{repo_root} ...")

    case deps.run_cmd.(@default_pi_command, ["install", "-l", source], cd: repo_root, stderr_to_stdout: true) do
      {_output, 0} ->
        :ok

      {output, _code} ->
        {:error, "Failed to install Symphony Pi package into #{repo_root}: #{String.trim(output)}"}
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
    deps.io_puts.("Setup complete")
    deps.io_puts.("--------------")
    deps.io_puts.("✓ Repository: #{repo_root}")
    deps.io_puts.("✓ Origin: #{origin_url}")
    deps.io_puts.("✓ Workflow: #{workflow_path}")
    deps.io_puts.("✓ Implementation model: #{answers.implementation_model}")

    if answers.auto_review_enabled do
      deps.io_puts.("✓ Auto-review: enabled (#{answers.review_model})")
    else
      deps.io_puts.("✓ Auto-review: disabled")
    end

    deps.io_puts.("")
    deps.io_puts.("Required Linear states: Todo, In Progress, Rework, Human Review, Merging, Done")
    deps.io_puts.("")
    deps.io_puts.("Run Symphony Pi with:")

    deps.io_puts.(
      "./bin/symphony-pi #{repo_root} " <>
        "--i-understand-that-this-will-be-running-without-the-usual-guardrails --port 4050"
    )
  end

  defp preferred_implementation_model(models) do
    preferred_model(models, [
      "anthropic/claude-opus-4-6",
      "openai/gpt-5.4",
      "anthropic/claude-sonnet-4-5",
      "openai/gpt-5"
    ])
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

  defp prompt_project([project], deps) do
    project_label = format_project(project)

    case prompt_yes_no("Use the only Linear project found: #{project_label}?", true, deps) do
      {:ok, true} -> {:ok, project}
      {:ok, false} -> prompt_project_selection([project], deps)
      {:error, reason} -> {:error, reason}
    end
  end

  defp prompt_project(projects, deps) when is_list(projects) do
    prompt_project_selection(projects, deps)
  end

  defp prompt_project_slug(_linear_api_key, {:loaded, projects}, deps) when is_list(projects) do
    with {:ok, project} <- prompt_project(projects, deps),
         :ok <- validate_required_states(project) do
      {:ok, project["slugId"]}
    end
  end

  defp prompt_project_slug(linear_api_key, {:manual, reason}, deps) when is_binary(reason) do
    deps.io_puts.("Could not fetch Linear projects automatically: #{reason}")

    with {:ok, slug} <-
           prompt_required("Linear project slug (the part after /project/ in the Linear URL): ", deps),
         {:ok, project} <- maybe_validate_manual_project(linear_api_key, slug, deps) do
      {:ok, Map.get(project, "slugId", slug)}
    end
  end

  defp maybe_validate_manual_project(linear_api_key, slug, deps) do
    case deps.fetch_project_by_slug.(linear_api_key, slug) do
      {:ok, nil} ->
        deps.io_puts.("! Could not find a Linear project with slug #{inspect(slug)}.")
        maybe_validate_manual_project_retry(linear_api_key, deps)

      {:ok, project} ->
        with :ok <- validate_required_states(project) do
          {:ok, project}
        end

      {:error, reason} ->
        deps.io_puts.("! Could not validate required Linear states automatically.")
        deps.io_puts.("  Reason: #{format_projects_error(reason)}")
        deps.io_puts.("  Setup will continue with the slug you entered.")
        {:ok, %{"slugId" => slug}}
    end
  end

  defp maybe_validate_manual_project_retry(linear_api_key, deps) do
    case prompt_yes_no("Enter a different project slug?", true, deps) do
      {:ok, true} ->
        with {:ok, slug} <-
               prompt_required("Linear project slug (the part after /project/ in the Linear URL): ", deps) do
          maybe_validate_manual_project(linear_api_key, slug, deps)
        end

      {:ok, false} ->
        {:error, "Setup aborted: no valid Linear project slug was provided."}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp prompt_project_selection(projects, deps) do
    deps.io_puts.("Linear projects:")

    Enum.each(Enum.with_index(projects, 1), fn {project, index} ->
      deps.io_puts.("  #{index}. #{format_project(project)}")
    end)

    with {:ok, selected_slug} <-
           prompt_choice(
             "Choose Linear project [number or slug]",
             Enum.map(projects, & &1["slugId"]),
             List.first(projects)["slugId"],
             deps
           ) do
      {:ok, Enum.find(projects, &(&1["slugId"] == selected_slug))}
    end
  end

  defp prompt_model_choice(label, default, models, help_text, deps) do
    options = ordered_options(models, default)

    deps.io_puts.("")
    deps.io_puts.("#{label}:")
    deps.io_puts.("  #{help_text}")

    Enum.each(Enum.with_index(options, 1), fn {model, index} ->
      suffix = if model == default, do: " (recommended)", else: ""
      deps.io_puts.("  #{index}. #{model}#{suffix}")
    end)

    prompt_choice("#{label} [Enter for recommended]", options, default, deps)
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

  defp prompt_choice(label, options, default, deps) when is_list(options) and is_binary(default) do
    case deps.io_gets.("#{label} [#{default}]: ") do
      nil ->
        {:error, "Setup aborted while reading input."}

      value ->
        selected = parse_choice_response(value, options, default)

        if is_binary(selected) do
          {:ok, selected}
        else
          deps.io_puts.("Choose a listed number or an exact value.")
          prompt_choice(label, options, default, deps)
        end
    end
  end

  defp parse_choice_response(value, options, default) when is_binary(value) do
    trimmed = String.trim(value)

    cond do
      trimmed == "" ->
        default

      Regex.match?(~r/^\d+$/, trimmed) ->
        case Integer.parse(trimmed) do
          {index, ""} -> Enum.at(options, index - 1)
          _ -> nil
        end

      trimmed in options ->
        trimmed

      true ->
        nil
    end
  end

  defp print_setup_status(repo_root, origin_url, models, projects, workflow_path, deps) do
    deps.io_puts.("")
    deps.io_puts.("Symphony Pi setup")
    deps.io_puts.("-----------------")
    deps.io_puts.("✓ Git repository detected: #{repo_root}")
    deps.io_puts.("✓ Git origin found: #{origin_url}")
    deps.io_puts.("✓ LINEAR_API_KEY present")
    deps.io_puts.("✓ Pi executable found: #{@default_pi_command}")
    deps.io_puts.("✓ Loaded #{length(models)} model(s) from Pi")
    print_project_status(projects, deps)

    if deps.file_regular?.(workflow_path) do
      deps.io_puts.("! Existing WORKFLOW.md found; setup will back it up to #{workflow_path}.bak before writing")
    else
      deps.io_puts.("✓ No existing WORKFLOW.md found")
    end

    deps.io_puts.("")
    :ok
  end

  defp maybe_confirm_workflow_overwrite(workflow_path, deps) do
    if deps.file_regular?.(workflow_path) do
      case prompt_yes_no("Replace existing WORKFLOW.md and create #{Path.basename(workflow_path)}.bak?", true, deps) do
        {:ok, true} -> :ok
        {:ok, false} -> {:error, "Setup aborted: existing WORKFLOW.md was left unchanged."}
        {:error, reason} -> {:error, reason}
      end
    else
      :ok
    end
  end

  defp ordered_options(options, default) when is_list(options) and is_binary(default) do
    [default | Enum.reject(options, &(&1 == default))]
  end

  defp print_project_status({:loaded, projects}, deps) when is_list(projects) do
    deps.io_puts.("✓ Loaded #{length(projects)} Linear project(s)")
  end

  defp print_project_status({:manual, reason}, deps) when is_binary(reason) do
    deps.io_puts.("! Could not load Linear projects automatically")
    deps.io_puts.("  Reason: #{reason}")
    deps.io_puts.("  Manual slug entry will be used")
  end

  defp project_sort_key(project) do
    {
      String.downcase(project_team_name(project)),
      String.downcase(project["name"] || ""),
      String.downcase(project["slugId"] || "")
    }
  end

  defp format_project(project) do
    "#{project_team_name(project)} / #{project["name"]} (#{project["slugId"]})"
  end

  defp project_team_name(%{"teams" => %{"nodes" => [team | _]}}), do: team_name(team)
  defp project_team_name(%{"team" => team}), do: team_name(team)
  defp project_team_name(_project), do: "Unknown team"

  defp list_linear_projects(token) when is_binary(token) do
    with :ok <- ensure_req_started(),
         {:ok, response} <-
           Req.post(@linear_endpoint,
             headers: [
               {"Authorization", token},
               {"Content-Type", "application/json"}
             ],
             json: %{"query" => @linear_projects_query},
             connect_options: [timeout: 30_000]
           ) do
      case response do
        %{status: 200, body: %{"data" => %{"projects" => %{"nodes" => nodes}}}} when is_list(nodes) ->
          {:ok, Enum.filter(nodes, &valid_project_node?/1)}

        %{body: %{"errors" => errors}} ->
          {:error, {:linear_graphql_errors, errors}}

        %{status: status} ->
          {:error, {:linear_api_status, status}}
      end
    else
      {:error, reason} -> {:error, {:linear_api_request, reason}}
    end
  end

  defp list_linear_projects(_token), do: {:error, :missing_linear_api_token}

  defp fetch_linear_project_by_slug(token, slug_id)
       when is_binary(token) and is_binary(slug_id) do
    with :ok <- ensure_req_started(),
         {:ok, response} <-
           Req.post(@linear_endpoint,
             headers: [
               {"Authorization", token},
               {"Content-Type", "application/json"}
             ],
             json: %{
               "query" => @linear_project_query,
               "variables" => %{"slugId" => slug_id}
             },
             connect_options: [timeout: 30_000]
           ) do
      case response do
        %{status: 200, body: %{"data" => %{"projects" => %{"nodes" => nodes}}}} when is_list(nodes) ->
          {:ok, Enum.find(nodes, &valid_project_node?/1)}

        %{body: %{"errors" => errors}} ->
          {:error, {:linear_graphql_errors, errors}}

        %{status: status} ->
          {:error, {:linear_api_status, status}}
      end
    else
      {:error, reason} -> {:error, {:linear_api_request, reason}}
    end
  end

  defp fetch_linear_project_by_slug(_token, _slug_id), do: {:error, :missing_linear_api_token}

  defp ensure_req_started do
    case Application.ensure_all_started(:req) do
      {:ok, _started} -> :ok
      {:error, {:already_started, _app}} -> :ok
      {:error, reason} -> {:error, {:req_start_failed, reason}}
    end
  end

  defp format_projects_error({:linear_graphql_errors, errors}) when is_list(errors) do
    errors
    |> Enum.map_join("; ", fn
      %{"message" => message} when is_binary(message) -> message
      %{message: message} when is_binary(message) -> message
      other -> inspect(other)
    end)
  end

  defp format_projects_error({:linear_api_status, status}), do: "Linear returned status #{status}"
  defp format_projects_error({:linear_api_request, reason}), do: "request failed: #{inspect(reason)}"
  defp format_projects_error({:req_start_failed, reason}), do: "could not start HTTP client: #{inspect(reason)}"
  defp format_projects_error(:missing_linear_api_token), do: "LINEAR_API_KEY is missing"
  defp format_projects_error(reason), do: inspect(reason)

  defp manual_project_fallback_allowed?({:linear_api_status, 400}), do: true
  defp manual_project_fallback_allowed?({:linear_graphql_errors, _errors}), do: true
  defp manual_project_fallback_allowed?(_reason), do: false

  defp validate_required_states(%{"slugId" => slug} = project) do
    available_states =
      project
      |> project_state_nodes()
      |> Enum.map(& &1["name"])
      |> Enum.filter(&is_binary/1)
      |> Enum.uniq()

    missing_states = Enum.reject(@required_workflow_states, &(&1 in available_states))

    if missing_states == [] do
      :ok
    else
      {:error,
       "Selected Linear project #{inspect(slug)} is missing required workflow states: " <>
         Enum.join(missing_states, ", ") <>
         ". Add them in Linear Team Settings -> Workflow and rerun `symphony-pi setup`."}
    end
  end

  defp valid_project_node?(%{"name" => name, "slugId" => slug})
       when is_binary(name) and name != "" and is_binary(slug) and slug != "" do
    true
  end

  defp valid_project_node?(_node), do: false

  defp project_state_nodes(%{"teams" => %{"nodes" => teams}}) when is_list(teams) do
    teams
    |> Enum.flat_map(fn
      %{"states" => %{"nodes" => states}} when is_list(states) -> states
      _ -> []
    end)
  end

  defp project_state_nodes(%{"team" => %{"states" => %{"nodes" => states}}}) when is_list(states), do: states
  defp project_state_nodes(_project), do: []

  defp team_name(%{"name" => name}) when is_binary(name) and name != "", do: name
  defp team_name(%{"key" => key}) when is_binary(key) and key != "", do: key
  defp team_name(_team), do: "Unknown team"

  defp ensure_linear_api_key(repo_root, deps) do
    case deps.get_env.("LINEAR_API_KEY") do
      value when is_binary(value) and value != "" ->
        {:ok, value}

      _ ->
        deps.io_puts.("! LINEAR_API_KEY is not set.")

        with {:ok, token} <- prompt_required("Paste LINEAR_API_KEY: ", deps),
             :ok <- persist_repo_env_prompt(repo_root, "LINEAR_API_KEY", token, deps) do
          deps.put_env.("LINEAR_API_KEY", token)
          {:ok, token}
        end
    end
  end

  defp ensure_pi_available(deps) do
    if deps.find_executable.(@default_pi_command) do
      :ok
    else
      deps.io_puts.("! Pi is not installed.")

      with {:ok, command, args} <- detect_pi_install_command(deps),
           {:ok, true} <-
             prompt_yes_no(
               "Install Pi now with `#{Enum.join([command | args], " ")}`?",
               true,
               deps
             ),
           :ok <- install_pi(command, args, deps),
           :ok <- confirm_pi_installed(deps) do
        :ok
      else
        {:ok, false} ->
          {:error, "Pi is required for Symphony Pi setup. Install it and rerun `symphony-pi setup`."}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  defp detect_pi_install_command(deps) do
    cond do
      deps.find_executable.("npm") ->
        {:ok, "npm", ["install", "-g", @default_pi_package]}

      deps.find_executable.("pnpm") ->
        {:ok, "pnpm", ["add", "-g", @default_pi_package]}

      deps.find_executable.("bun") ->
        {:ok, "bun", ["add", "-g", @default_pi_package]}

      true ->
        {:error,
         "Pi is required for Symphony Pi setup. Install it first with " <>
           "`npm install -g #{@default_pi_package}` and rerun setup."}
    end
  end

  defp install_pi(command, args, deps) do
    deps.io_puts.("Installing Pi ...")

    case deps.run_cmd.(command, args, stderr_to_stdout: true) do
      {_output, 0} ->
        :ok

      {output, _code} ->
        {:error, "Failed to install Pi: #{String.trim(output)}"}
    end
  end

  defp confirm_pi_installed(deps) do
    if deps.find_executable.(@default_pi_command) do
      :ok
    else
      {:error, "Pi installation completed but `pi` is still not available in PATH."}
    end
  end

  defp ensure_model_credentials(repo_root, answers, deps) do
    answers
    |> selected_models()
    |> Enum.map(&provider_for_model/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
    |> Enum.reduce_while(:ok, fn provider, :ok ->
      case ensure_provider_credentials(repo_root, provider, deps) do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp selected_models(%{implementation_model: implementation_model, review_model: review_model}) do
    [implementation_model, review_model]
    |> Enum.filter(&is_binary/1)
  end

  defp provider_for_model(model) when is_binary(model) do
    case String.split(model, "/", parts: 2) do
      [provider, _model_id] when provider != "" -> provider
      _ -> nil
    end
  end

  defp maybe_warn_missing_provider_auth(nil, _deps), do: :ok

  defp maybe_warn_missing_provider_auth(model, deps) when is_binary(model) do
    provider = provider_for_model(model)

    if provider && not provider_authenticated?(provider, deps) do
      deps.io_puts.("")
      deps.io_puts.("! Pi credentials are still missing for #{provider}.")
      deps.io_puts.("  Setup will prompt you to fix that before writing WORKFLOW.md.")
    end

    :ok
  end

  defp ensure_provider_credentials(_repo_root, nil, _deps), do: :ok

  defp ensure_provider_credentials(repo_root, provider, deps) do
    if provider_authenticated?(provider, deps) do
      :ok
    else
      configure_provider_credentials(repo_root, provider, deps)
    end
  end

  defp configure_provider_credentials(repo_root, provider, deps) do
    api_env_var = prompt_env_var_for_provider(provider)
    supports_oauth = MapSet.member?(@oauth_login_providers, provider)

    deps.io_puts.("")
    deps.io_puts.("Pi credentials are missing for provider #{provider}.")

    cond do
      api_env_var && supports_oauth ->
        deps.io_puts.("Choose one:")
        deps.io_puts.("  1. Paste #{api_env_var} now")
        deps.io_puts.("  2. Use Pi subscription login with `/login #{provider}` in another terminal")

        choose_provider_credential_flow(repo_root, provider, api_env_var, deps)

      api_env_var ->
        prompt_provider_api_key(repo_root, provider, api_env_var, deps)

      supports_oauth ->
        prompt_provider_login(provider, deps)

      true ->
        {:error, "Provider #{provider} is not authenticated. Configure it in Pi first, then rerun `symphony-pi setup`."}
    end
  end

  defp choose_provider_credential_flow(repo_root, provider, api_env_var, deps) do
    with {:ok, choice} <- prompt_choice("Credential setup", ["1", "2"], "1", deps) do
      case choice do
        "1" -> prompt_provider_api_key(repo_root, provider, api_env_var, deps)
        "2" -> prompt_provider_login(provider, deps)
      end
    end
  end

  defp prompt_provider_api_key(repo_root, provider, env_var, deps) do
    with {:ok, value} <- prompt_required("Paste #{env_var} for #{provider}: ", deps),
         :ok <- persist_repo_env_prompt(repo_root, env_var, value, deps) do
      deps.put_env.(env_var, value)

      if provider_authenticated?(provider, deps) do
        :ok
      else
        {:error, "Credentials for provider #{provider} still look unavailable after setting #{env_var}."}
      end
    end
  end

  defp prompt_provider_login(provider, deps) do
    deps.io_puts.("Open another terminal and run:")
    deps.io_puts.("  pi")
    deps.io_puts.("  /login #{provider}")
    deps.io_puts.("")

    case prompt_yes_no("Have you finished that login flow and want Symphony Pi to re-check now?", true, deps) do
      {:ok, true} ->
        if provider_authenticated?(provider, deps) do
          :ok
        else
          {:error, "Pi credentials for #{provider} are still missing. Finish `pi` -> `/login #{provider}` and rerun setup."}
        end

      {:ok, false} ->
        {:error, "Setup aborted: Pi credentials are required for provider #{provider}."}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp provider_authenticated?(provider, deps) when is_binary(provider) do
    special_provider_authenticated?(provider, deps) or
      provider_env_vars(provider)
      |> Enum.any?(fn env_var ->
        value = deps.get_env.(env_var)
        is_binary(value) and value != ""
      end) or provider_in_auth_file?(provider, deps)
  end

  defp special_provider_authenticated?("google-vertex", deps) do
    adc_path =
      deps.get_env.("GOOGLE_APPLICATION_CREDENTIALS") ||
        Path.expand("~/.config/gcloud/application_default_credentials.json")

    deps.file_regular?.(adc_path) and
      present_env_value?(deps.get_env.("GOOGLE_CLOUD_PROJECT") || deps.get_env.("GCLOUD_PROJECT")) and
      present_env_value?(deps.get_env.("GOOGLE_CLOUD_LOCATION"))
  end

  defp special_provider_authenticated?(_provider, _deps), do: false

  defp present_env_value?(value) when is_binary(value), do: value != ""
  defp present_env_value?(_value), do: false

  defp provider_in_auth_file?(provider, deps) do
    auth_path = deps.pi_auth_path.()

    case deps.read_file.(auth_path) do
      {:ok, body} ->
        case Jason.decode(body) do
          {:ok, %{} = auth_map} -> Map.has_key?(auth_map, provider)
          _ -> false
        end

      _ ->
        false
    end
  end

  defp provider_env_vars(provider) when is_binary(provider) do
    Map.get(@provider_env_vars, provider, [])
  end

  defp prompt_env_var_for_provider(provider) when is_binary(provider) do
    env_vars = provider_env_vars(provider)
    Enum.find(env_vars, &String.ends_with?(&1, "_API_KEY")) || List.first(env_vars)
  end

  defp persist_repo_env_prompt(repo_root, env_var, value, deps) do
    env_path = Path.join(repo_root, ".env")

    case prompt_yes_no("Save #{env_var} to #{env_path} for this repo?", true, deps) do
      {:ok, true} ->
        upsert_repo_env(env_path, env_var, value, deps)

      {:ok, false} ->
        deps.io_puts("! #{env_var} was not saved. Future Symphony Pi runs will need it set in the shell.")
        :ok

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp upsert_repo_env(env_path, env_var, value, deps) do
    existing =
      case deps.read_file.(env_path) do
        {:ok, body} -> body
        _ -> ""
      end

    updated = upsert_env_assignment(existing, env_var, value)

    case deps.write_file.(env_path, updated) do
      :ok -> :ok
      {:error, reason} -> {:error, "Failed to write #{env_path}: #{inspect(reason)}"}
    end
  end

  defp upsert_env_assignment(existing, env_var, value)
       when is_binary(existing) and is_binary(env_var) and is_binary(value) do
    lines = String.split(existing, ~r/\R/, trim: false)
    new_line = "#{env_var}=#{value}"

    {updated_lines, found?} =
      Enum.map_reduce(lines, false, fn line, found? ->
        if String.starts_with?(line, env_var <> "=") do
          {new_line, true}
        else
          {line, found?}
        end
      end)

    result_lines =
      if found? do
        updated_lines
      else
        case Enum.reject(updated_lines, &(&1 == "")) do
          [] -> [new_line]
          _ -> updated_lines ++ [new_line]
        end
      end

    body = Enum.join(result_lines, "\n")
    if String.ends_with?(body, "\n"), do: body, else: body <> "\n"
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
