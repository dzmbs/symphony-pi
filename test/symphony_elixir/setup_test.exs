defmodule SymphonyElixir.SetupTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.Setup

  @base_required_states [
    %{"name" => "Todo"},
    %{"name" => "In Progress"},
    %{"name" => "Rework"},
    %{"name" => "Human Review"},
    %{"name" => "Merging"},
    %{"name" => "Done"}
  ]

  @auto_review_required_states List.insert_at(@base_required_states, 3, %{"name" => "Agent Review"})

  test "setup writes workflow, installs skills, and can create AGENTS.md" do
    parent = self()
    source_root = temp_dir("source")
    repo_root = temp_dir("repo")

    File.write!(Path.join(source_root, "package.json"), ~s({"name": "symphony-pi"}))
    File.write!(Path.join(source_root, "WORKFLOW.md"), "---\ntracker:\n  kind: linear\n---\nPrompt body\n")

    deps = %{
      current_dir: fn -> source_root end,
      expand_path: &Path.expand/1,
      read_file: &File.read/1,
      write_file: fn path, body ->
        path |> Path.dirname() |> File.mkdir_p!()
        File.write(path, body)
      end,
      file_regular?: &File.regular?/1,
      get_env: fn
        "LINEAR_API_KEY" -> "token"
        "ANTHROPIC_API_KEY" -> "sk-ant-123"
        "OPENAI_API_KEY" -> "sk-openai-123"
        _ -> nil
      end,
      put_env: fn _key, _value -> :ok end,
      find_executable: fn
        "pi" -> "/usr/bin/pi"
        _ -> nil
      end,
      io_gets:
        prompt_answers(%{
          "Use the only Linear project found:" => "",
          "Workspace root" => "~/code/workspaces",
          "Implementation model" => "",
          "Enable optional internal auto-review before human handoff?" => "y",
          "Review model" => "",
          "Create a minimal AGENTS.md starter for repo-specific coding guidance?" => "y"
        }),
      io_puts: fn _line -> :ok end,
      pi_auth_path: fn -> Path.join(repo_root, "missing-auth.json") end,
      available_models: fn "pi" ->
        {:ok, MapSet.new(["anthropic/claude-opus-4-6", "openai/gpt-5.4", "anthropic/claude-sonnet-4-5"])}
      end,
      list_projects: fn "token" ->
        {:ok, [project_fixture("Project A", "project-a", include_agent_review?: true)]}
      end,
      fetch_project_by_slug: fn "token", "project-a" ->
        {:ok, project_fixture("Project A", "project-a", include_agent_review?: true)}
      end,
      run_cmd:
        with_pi_version(fn
          "git", ["-C", ^repo_root, "rev-parse", "--show-toplevel"], _opts ->
            {repo_root <> "\n", 0}

          "git", ["-C", ^repo_root, "remote", "get-url", "origin"], _opts ->
            {"git@github.com:org/project-a.git\n", 0}

          "pi", ["install", "-l", ^source_root], opts ->
            send(parent, {:pi_install, opts[:cd], source_root})
            {"installed\n", 0}
        end)
    }

    assert :ok = Setup.run(repo_root, deps)

    workflow = File.read!(Path.join(repo_root, "WORKFLOW.md"))
    assert workflow =~ ~s(project_slug: "project-a")
    assert workflow =~ ~s(model: "anthropic/claude-opus-4-6")
    assert workflow =~ "auto_review:"
    assert workflow =~ ~s(model: "openai/gpt-5.4")
    assert workflow =~ "Prompt body"

    agents = File.read!(Path.join(repo_root, "AGENTS.md"))
    assert agents =~ "Repository guidance for Pi and Symphony Pi runs."

    assert_received {:pi_install, ^repo_root, ^source_root}
  end

  test "setup backs up an existing workflow and leaves auto review disabled by default" do
    source_root = temp_dir("source")
    repo_root = temp_dir("repo")
    workflow_path = Path.join(repo_root, "WORKFLOW.md")

    File.write!(Path.join(source_root, "package.json"), ~s({"name": "symphony-pi"}))
    File.write!(workflow_path, "old workflow\n")

    Process.put(:setup_inputs, ["", "", "", "", "", "n", "n"])

    deps = %{
      current_dir: fn -> source_root end,
      expand_path: &Path.expand/1,
      read_file: &File.read/1,
      write_file: fn path, body ->
        path |> Path.dirname() |> File.mkdir_p!()
        File.write(path, body)
      end,
      file_regular?: &File.regular?/1,
      get_env: fn
        "LINEAR_API_KEY" -> "token"
        "OPENAI_API_KEY" -> "sk-openai-123"
        _ -> nil
      end,
      put_env: fn _key, _value -> :ok end,
      find_executable: fn
        "pi" -> "/usr/bin/pi"
        _ -> nil
      end,
      io_gets: &next_input/1,
      io_puts: fn _line -> :ok end,
      pi_auth_path: fn -> Path.join(repo_root, "missing-auth.json") end,
      available_models: fn "pi" ->
        {:ok, MapSet.new(["openai/gpt-5.4"])}
      end,
      list_projects: fn "token" ->
        {:ok, [project_fixture("Project B", "project-b")]}
      end,
      fetch_project_by_slug: fn "token", "project-b" ->
        {:ok, project_fixture("Project B", "project-b")}
      end,
      run_cmd:
        with_pi_version(fn
          "git", ["-C", ^repo_root, "rev-parse", "--show-toplevel"], _opts ->
            {repo_root <> "\n", 0}

          "git", ["-C", ^repo_root, "remote", "get-url", "origin"], _opts ->
            {"https://github.com/org/project-b.git\n", 0}

          "pi", ["install", "-l", ^source_root], _opts ->
            {"installed\n", 0}
        end)
    }

    assert :ok = Setup.run(repo_root, deps)

    assert File.read!(workflow_path <> ".bak") == "old workflow\n"

    workflow = File.read!(workflow_path)
    assert workflow =~ ~s(project_slug: "project-b")
    assert workflow =~ ~s(root: "~/code/symphony-workspaces")
    assert workflow =~ "# auto_review:"
    refute File.exists?(Path.join(repo_root, "AGENTS.md"))
  end

  test "setup falls back to manual project slug entry and surfaces the reason" do
    parent = self()
    source_root = temp_dir("source")
    repo_root = temp_dir("repo")

    File.write!(Path.join(source_root, "package.json"), ~s({"name": "symphony-pi"}))

    Process.put(:setup_inputs, ["project-c", "", "", "n", "n"])

    deps = %{
      current_dir: fn -> source_root end,
      expand_path: &Path.expand/1,
      read_file: &File.read/1,
      write_file: fn path, body ->
        path |> Path.dirname() |> File.mkdir_p!()
        File.write(path, body)
      end,
      file_regular?: &File.regular?/1,
      get_env: fn
        "LINEAR_API_KEY" -> "token"
        "ANTHROPIC_API_KEY" -> "sk-ant-123"
        _ -> nil
      end,
      put_env: fn _key, _value -> :ok end,
      find_executable: fn
        "pi" -> "/usr/bin/pi"
        _ -> nil
      end,
      io_gets: &next_input/1,
      io_puts: fn line -> send(parent, {:setup_output, line}) end,
      pi_auth_path: fn -> Path.join(repo_root, "missing-auth.json") end,
      available_models: fn "pi" ->
        {:ok, MapSet.new(["anthropic/claude-opus-4-6", "openai/gpt-5.4", "anthropic/claude-sonnet-4-5"])}
      end,
      list_projects: fn "token" ->
        {:error, {:linear_api_status, 400}}
      end,
      fetch_project_by_slug: fn "token", _slug ->
        {:error, {:linear_api_status, 400}}
      end,
      run_cmd:
        with_pi_version(fn
          "git", ["-C", ^repo_root, "rev-parse", "--show-toplevel"], _opts ->
            {repo_root <> "\n", 0}

          "git", ["-C", ^repo_root, "remote", "get-url", "origin"], _opts ->
            {"git@github.com:org/project-c.git\n", 0}

          "pi", ["install", "-l", ^source_root], _opts ->
            {"installed\n", 0}
        end)
    }

    assert :ok = Setup.run(repo_root, deps)
    assert_received {:setup_output, "! Could not load Linear projects automatically"}
    assert_received {:setup_output, "  Reason: Linear returned status 400"}
    assert_received {:setup_output, "Could not fetch Linear projects automatically: Linear returned status 400"}
    assert_received {:setup_output, "  1. anthropic/claude-opus-4-6 (recommended)"}
    assert_received {:setup_output, "! Could not validate required Linear states automatically."}
  end

  test "setup prompts for missing Linear key and provider key and persists them to repo dotenv" do
    source_root = temp_dir("source")
    repo_root = temp_dir("repo")

    File.write!(Path.join(source_root, "package.json"), ~s({"name": "symphony-pi"}))
    Process.put(:setup_env, %{})

    deps = %{
      current_dir: fn -> source_root end,
      expand_path: &Path.expand/1,
      read_file: &File.read/1,
      write_file: fn path, body ->
        path |> Path.dirname() |> File.mkdir_p!()
        File.write(path, body)
      end,
      file_regular?: &File.regular?/1,
      get_env: fn name -> Process.get(:setup_env, %{})[name] end,
      put_env: fn key, value ->
        Process.put(:setup_env, Map.put(Process.get(:setup_env, %{}), key, value))
        :ok
      end,
      find_executable: fn
        "pi" -> "/usr/bin/pi"
        _ -> nil
      end,
      io_gets:
        prompt_answers(%{
          "Paste LINEAR_API_KEY:" => "linear-token-123",
          "Save LINEAR_API_KEY to" => "y",
          "Use the only Linear project found:" => "",
          "Workspace root" => "",
          "Implementation model" => "",
          "Enable optional internal auto-review before human handoff?" => "n",
          "Create a minimal AGENTS.md starter for repo-specific coding guidance?" => "n",
          "Credential setup" => "1",
          "Paste ANTHROPIC_API_KEY for anthropic:" => "sk-ant-123",
          "Save ANTHROPIC_API_KEY to" => "y"
        }),
      io_puts: fn _line -> :ok end,
      pi_auth_path: fn -> Path.join(repo_root, "missing-auth.json") end,
      available_models: fn "pi" ->
        {:ok, MapSet.new(["anthropic/claude-opus-4-6"])}
      end,
      list_projects: fn "linear-token-123" ->
        {:ok, [project_fixture("Project D", "project-d")]}
      end,
      fetch_project_by_slug: fn "linear-token-123", "project-d" ->
        {:ok, project_fixture("Project D", "project-d")}
      end,
      run_cmd:
        with_pi_version(fn
          "git", ["-C", ^repo_root, "rev-parse", "--show-toplevel"], _opts ->
            {repo_root <> "\n", 0}

          "git", ["-C", ^repo_root, "remote", "get-url", "origin"], _opts ->
            {"git@github.com:org/project-d.git\n", 0}

          "pi", ["install", "-l", ^source_root], _opts ->
            {"installed\n", 0}
        end)
    }

    assert :ok = Setup.run(repo_root, deps)

    dotenv = File.read!(Path.join(repo_root, ".env"))
    assert dotenv =~ "LINEAR_API_KEY=linear-token-123"
    assert dotenv =~ "ANTHROPIC_API_KEY=sk-ant-123"

    Process.delete(:setup_env)
  end

  test "setup requires Agent Review only when auto review is enabled" do
    source_root = temp_dir("source")
    repo_root = temp_dir("repo")

    File.write!(Path.join(source_root, "package.json"), ~s({"name": "symphony-pi"}))

    deps = %{
      current_dir: fn -> source_root end,
      expand_path: &Path.expand/1,
      read_file: &File.read/1,
      write_file: fn path, body ->
        path |> Path.dirname() |> File.mkdir_p!()
        File.write(path, body)
      end,
      file_regular?: &File.regular?/1,
      get_env: fn
        "LINEAR_API_KEY" -> "token"
        "OPENAI_API_KEY" -> "sk-openai-123"
        _ -> nil
      end,
      put_env: fn _key, _value -> :ok end,
      find_executable: fn
        "pi" -> "/usr/bin/pi"
        _ -> nil
      end,
      io_gets:
        prompt_answers(%{
          "Use the only Linear project found:" => "",
          "Workspace root" => "",
          "Implementation model" => "",
          "Enable optional internal auto-review before human handoff?" => "y",
          "Review model" => "",
          "Create a minimal AGENTS.md starter for repo-specific coding guidance?" => "n"
        }),
      io_puts: fn _line -> :ok end,
      pi_auth_path: fn -> Path.join(repo_root, "missing-auth.json") end,
      available_models: fn "pi" ->
        {:ok, MapSet.new(["openai/gpt-5.4"])}
      end,
      list_projects: fn "token" ->
        {:ok, [project_fixture("Project F", "project-f")]}
      end,
      fetch_project_by_slug: fn "token", "project-f" ->
        {:ok, project_fixture("Project F", "project-f")}
      end,
      run_cmd:
        with_pi_version(fn
          "git", ["-C", ^repo_root, "rev-parse", "--show-toplevel"], _opts ->
            {repo_root <> "\n", 0}

          "git", ["-C", ^repo_root, "remote", "get-url", "origin"], _opts ->
            {"git@github.com:org/project-f.git\n", 0}

          "pi", ["install", "-l", ^source_root], _opts ->
            {"installed\n", 0}
        end)
    }

    assert {:error, message} = Setup.run(repo_root, deps)
    assert message =~ ~s(Selected Linear project "project-f" is missing required workflow states: Agent Review)
  end

  test "setup stops when Linear project listing is unauthorized" do
    source_root = temp_dir("source")
    repo_root = temp_dir("repo")

    File.write!(Path.join(source_root, "package.json"), ~s({"name": "symphony-pi"}))

    deps = %{
      current_dir: fn -> source_root end,
      expand_path: &Path.expand/1,
      read_file: &File.read/1,
      write_file: fn path, body ->
        path |> Path.dirname() |> File.mkdir_p!()
        File.write(path, body)
      end,
      file_regular?: &File.regular?/1,
      get_env: fn
        "LINEAR_API_KEY" -> "token"
        _ -> nil
      end,
      put_env: fn _key, _value -> :ok end,
      find_executable: fn
        "pi" -> "/usr/bin/pi"
        _ -> nil
      end,
      io_gets: &next_input/1,
      io_puts: fn _line -> :ok end,
      pi_auth_path: fn -> Path.join(repo_root, "missing-auth.json") end,
      available_models: fn "pi" ->
        {:ok, MapSet.new(["anthropic/claude-opus-4-6"])}
      end,
      list_projects: fn "token" ->
        {:error, {:linear_api_status, 403}}
      end,
      fetch_project_by_slug: fn _token, _slug ->
        flunk("manual fallback should not be used for unauthorized Linear access")
      end,
      run_cmd:
        with_pi_version(fn
          "git", ["-C", ^repo_root, "rev-parse", "--show-toplevel"], _opts ->
            {repo_root <> "\n", 0}

          "git", ["-C", ^repo_root, "remote", "get-url", "origin"], _opts ->
            {"git@github.com:org/project-f.git\n", 0}
        end)
    }

    assert {:error, "Could not load Linear projects: Linear returned status 403"} =
             Setup.run(repo_root, deps)
  end

  test "setup can install pi before continuing" do
    parent = self()
    source_root = temp_dir("source")
    repo_root = temp_dir("repo")

    File.write!(Path.join(source_root, "package.json"), ~s({"name": "symphony-pi"}))
    Process.put(:pi_installed, false)

    deps = %{
      current_dir: fn -> source_root end,
      expand_path: &Path.expand/1,
      read_file: &File.read/1,
      write_file: fn path, body ->
        path |> Path.dirname() |> File.mkdir_p!()
        File.write(path, body)
      end,
      file_regular?: &File.regular?/1,
      get_env: fn
        "LINEAR_API_KEY" -> "token"
        "OPENAI_API_KEY" -> "sk-openai-123"
        _ -> nil
      end,
      put_env: fn _key, _value -> :ok end,
      find_executable: fn
        "pi" ->
          if Process.get(:pi_installed), do: "/usr/bin/pi", else: nil

        "npm" ->
          "/usr/bin/npm"

        _ ->
          nil
      end,
      io_gets:
        prompt_answers(%{
          "Install Pi now with" => "",
          "Use the only Linear project found:" => "",
          "Workspace root" => "",
          "Implementation model" => "",
          "Enable optional internal auto-review before human handoff?" => "n",
          "Create a minimal AGENTS.md starter for repo-specific coding guidance?" => "n"
        }),
      io_puts: fn _line -> :ok end,
      pi_auth_path: fn -> Path.join(repo_root, "missing-auth.json") end,
      available_models: fn "pi" ->
        {:ok, MapSet.new(["openai/gpt-5.4"])}
      end,
      list_projects: fn "token" ->
        {:ok, [project_fixture("Project E", "project-e")]}
      end,
      fetch_project_by_slug: fn "token", "project-e" ->
        {:ok, project_fixture("Project E", "project-e")}
      end,
      run_cmd:
        with_pi_version(fn
          "git", ["-C", ^repo_root, "rev-parse", "--show-toplevel"], _opts ->
            {repo_root <> "\n", 0}

          "git", ["-C", ^repo_root, "remote", "get-url", "origin"], _opts ->
            {"git@github.com:org/project-e.git\n", 0}

          "npm", ["install", "-g", "@mariozechner/pi-coding-agent"], _opts ->
            Process.put(:pi_installed, true)
            send(parent, :pi_runtime_installed)
            {"installed\n", 0}

          "pi", ["install", "-l", ^source_root], _opts ->
            {"installed\n", 0}
        end)
    }

    assert :ok = Setup.run(repo_root, deps)
    assert_received :pi_runtime_installed
    Process.delete(:pi_installed)
  end

  defp project_fixture(name, slug, opts \\ []) do
    states =
      if Keyword.get(opts, :include_agent_review?, false) do
        @auto_review_required_states
      else
        @base_required_states
      end

    %{
      "name" => name,
      "slugId" => slug,
      "teams" => %{
        "nodes" => [
          %{
            "name" => "Core",
            "states" => %{"nodes" => states}
          }
        ]
      }
    }
  end

  defp next_input(_prompt) do
    case Process.get(:setup_inputs, []) do
      [next | rest] ->
        Process.put(:setup_inputs, rest)
        next <> "\n"

      [] ->
        flunk("unexpected setup prompt")
    end
  end

  defp temp_dir(label) do
    path = Path.join(System.tmp_dir!(), "symphony-setup-test-#{label}-#{System.unique_integer([:positive])}")
    File.mkdir_p!(path)
    path
  end

  defp with_pi_version(run_cmd) when is_function(run_cmd, 3) do
    fn
      "pi", ["--version"], _opts ->
        {"0.58.0\n", 0}

      command, args, opts ->
        run_cmd.(command, args, opts)
    end
  end

  defp prompt_answers(answers) when is_map(answers) do
    fn prompt ->
      respond_to_prompt(prompt, answers)
    end
  end

  defp respond_to_prompt(prompt, answers) when is_binary(prompt) and is_map(answers) do
    case matching_prompt_response(prompt, answers) do
      {:ok, response} -> response <> "\n"
      :error -> flunk("unexpected setup prompt: #{inspect(prompt)}")
    end
  end

  defp matching_prompt_response(prompt, answers) when is_binary(prompt) and is_map(answers) do
    case Enum.find(answers, fn {pattern, _response} -> String.contains?(prompt, pattern) end) do
      {_pattern, response} -> {:ok, response}
      nil -> :error
    end
  end
end
