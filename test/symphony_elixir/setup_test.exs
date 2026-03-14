defmodule SymphonyElixir.SetupTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.Setup

  test "setup writes workflow, installs skills, and can create AGENTS.md" do
    parent = self()
    source_root = temp_dir("source")
    repo_root = temp_dir("repo")

    File.write!(Path.join(source_root, "package.json"), ~s({"name": "symphony-pi"}))
    File.write!(Path.join(source_root, "WORKFLOW.md"), "---\ntracker:\n  kind: linear\n---\nPrompt body\n")

    Process.put(:setup_inputs, ["project-a", "~/code/workspaces", "", "y", "", "y"])

    deps = %{
      current_dir: fn -> source_root end,
      expand_path: &Path.expand/1,
      read_file: &File.read/1,
      write_file: fn path, body ->
        path |> Path.dirname() |> File.mkdir_p!()
        File.write(path, body)
      end,
      file_regular?: &File.regular?/1,
      get_env: fn "LINEAR_API_KEY" -> "token" end,
      find_executable: fn "pi" -> "/usr/bin/pi" end,
      io_gets: &next_input/1,
      io_puts: fn _line -> :ok end,
      available_models: fn "pi" ->
        {:ok, MapSet.new(["anthropic/claude-opus-4-6", "openai/gpt-5.4", "anthropic/claude-sonnet-4-5"])}
      end,
      run_cmd: fn
        "git", ["-C", ^repo_root, "rev-parse", "--show-toplevel"], _opts ->
          {repo_root <> "\n", 0}

        "git", ["-C", ^repo_root, "remote", "get-url", "origin"], _opts ->
          {"git@github.com:org/project-a.git\n", 0}

        "pi", ["install", "-l", ^source_root], opts ->
          send(parent, {:pi_install, opts[:cd], source_root})
          {"installed\n", 0}
      end
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

    Process.put(:setup_inputs, ["project-b", "", "openai/gpt-5.4", "n", "n"])

    deps = %{
      current_dir: fn -> source_root end,
      expand_path: &Path.expand/1,
      read_file: &File.read/1,
      write_file: fn path, body ->
        path |> Path.dirname() |> File.mkdir_p!()
        File.write(path, body)
      end,
      file_regular?: &File.regular?/1,
      get_env: fn "LINEAR_API_KEY" -> "token" end,
      find_executable: fn "pi" -> "/usr/bin/pi" end,
      io_gets: &next_input/1,
      io_puts: fn _line -> :ok end,
      available_models: fn "pi" ->
        {:ok, MapSet.new(["openai/gpt-5.4"])}
      end,
      run_cmd: fn
        "git", ["-C", ^repo_root, "rev-parse", "--show-toplevel"], _opts ->
          {repo_root <> "\n", 0}

        "git", ["-C", ^repo_root, "remote", "get-url", "origin"], _opts ->
          {"https://github.com/org/project-b.git\n", 0}

        "pi", ["install", "-l", ^source_root], _opts ->
          {"installed\n", 0}
      end
    }

    assert :ok = Setup.run(repo_root, deps)

    assert File.read!(workflow_path <> ".bak") == "old workflow\n"

    workflow = File.read!(workflow_path)
    assert workflow =~ ~s(project_slug: "project-b")
    assert workflow =~ ~s(root: "~/code/symphony-workspaces")
    assert workflow =~ "# auto_review:"
    refute File.exists?(Path.join(repo_root, "AGENTS.md"))
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
end
