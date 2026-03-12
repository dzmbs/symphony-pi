defmodule SymphonyElixir.Pi.RpcClient do
  @moduledoc """
  Low-level client for Pi's RPC mode over stdio.

  Spawns `pi --mode rpc` as an Erlang Port and provides:
  - JSONL command writing to stdin
  - JSONL line reading from stdout with partial-line buffering
  - Classification of incoming lines as responses or events
  - Clean shutdown

  This module does NOT handle prompt lifecycle, event normalization,
  or session reuse. Those belong in `Pi.RpcBackend`.
  """

  require Logger

  @port_line_bytes 1_048_576
  @max_log_bytes 1_000

  @type port_ref :: port()

  @type parsed_line ::
          {:response, map()}
          | {:event, map()}
          | {:parse_error, String.t()}

  # ---------------------------------------------------------------------------
  # Lifecycle
  # ---------------------------------------------------------------------------

  @doc """
  Spawn a Pi process in RPC mode inside the given workspace directory.

  Options:
    - `:command` — path to the pi binary (default: `"pi"`)
    - `:session_dir` — passed as `--session-dir <path>`
    - `:model` — passed as `--model <pattern>`
    - `:thinking` — appended to model as `<model>:<thinking>` (requires `:model`)
    - `:no_session` — if true, adds `--no-session`
    - `:extra_args` — list of additional CLI args
    - `:env` — list of `{name, value}` environment variable tuples
    - `:worker_host` — SSH host for remote execution (nil = local)

  Returns `{:ok, port}` or `{:error, reason}`.
  """
  @spec start(Path.t(), keyword()) :: {:ok, port_ref()} | {:error, term()}
  def start(workspace, opts \\ []) do
    worker_host = Keyword.get(opts, :worker_host)

    if worker_host do
      start_remote(workspace, worker_host, opts)
    else
      start_local(workspace, opts)
    end
  end

  defp start_local(workspace, opts) do
    {executable, args} = build_argv(opts)
    env_vars = Keyword.get(opts, :env, [])

    case resolve_executable(executable) do
      {:ok, resolved} ->
        expanded_workspace = Path.expand(workspace)

        port_opts = [
          :binary,
          :exit_status,
          :stderr_to_stdout,
          args: Enum.map(args, &String.to_charlist/1),
          cd: String.to_charlist(expanded_workspace),
          line: @port_line_bytes
        ]

        port_opts =
          if env_vars != [] do
            charlist_env = Enum.map(env_vars, fn {k, v} -> {String.to_charlist(k), String.to_charlist(v)} end)
            Keyword.put(port_opts, :env, charlist_env)
          else
            port_opts
          end

        port = Port.open({:spawn_executable, String.to_charlist(resolved)}, port_opts)
        {:ok, port}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp start_remote(workspace, worker_host, opts) do
    alias SymphonyElixir.SSH

    {executable, args} = build_argv(opts)
    env_vars = Keyword.get(opts, :env, [])
    expanded_workspace = Path.expand(workspace)
    reverse_forward = Keyword.get(opts, :reverse_forward)

    # Build the remote command: set env vars, cd to workspace, run pi
    # All values are properly shell-escaped to prevent injection
    env_prefix =
      env_vars
      |> Enum.map(fn {k, v} -> "export #{shell_escape_var_name(k)}=#{shell_escape(v)}" end)
      |> Enum.join("; ")

    command_str = Enum.map_join([executable | args], " ", &shell_escape/1)

    full_command =
      if env_prefix == "" do
        "cd #{shell_escape(expanded_workspace)} && #{command_str}"
      else
        "#{env_prefix}; cd #{shell_escape(expanded_workspace)} && #{command_str}"
      end

    ssh_opts = [line: @port_line_bytes]
    ssh_opts = if reverse_forward, do: Keyword.put(ssh_opts, :reverse_forward, reverse_forward), else: ssh_opts

    SSH.start_port(worker_host, full_command, ssh_opts)
  end

  defp shell_escape_var_name(name) when is_binary(name) do
    # Variable names must be alphanumeric + underscore only
    if String.match?(name, ~r/^[A-Za-z_][A-Za-z0-9_]*$/) do
      name
    else
      raise ArgumentError, "invalid environment variable name: #{inspect(name)}"
    end
  end

  defp shell_escape(value) when is_binary(value) do
    "'" <> String.replace(value, "'", "'\"'\"'") <> "'"
  end

  @doc """
  Send a command map as a JSONL line to Pi's stdin.
  """
  @spec send_command(port_ref(), map()) :: :ok | {:error, :port_closed}
  def send_command(port, command) when is_port(port) and is_map(command) do
    line = Jason.encode!(command) <> "\n"

    try do
      case Port.command(port, line) do
        true -> :ok
        false -> {:error, :port_closed}
      end
    rescue
      ArgumentError -> {:error, :port_closed}
    end
  end

  @doc """
  Stop the Pi process by closing the port.

  Safe to call multiple times or on an already-closed port.
  """
  @spec stop(port_ref()) :: :ok
  def stop(port) when is_port(port) do
    case :erlang.port_info(port) do
      :undefined ->
        :ok

      _ ->
        try do
          Port.close(port)
          :ok
        rescue
          ArgumentError -> :ok
        end
    end
  end

  @doc """
  Get the OS PID of the Pi process, if available.
  """
  @spec os_pid(port_ref()) :: String.t() | nil
  def os_pid(port) when is_port(port) do
    case :erlang.port_info(port, :os_pid) do
      {:os_pid, pid} -> to_string(pid)
      _ -> nil
    end
  end

  # ---------------------------------------------------------------------------
  # Line parsing
  # ---------------------------------------------------------------------------

  @doc """
  Parse a complete JSONL line from Pi's stdout into a classified tuple.

  Returns:
    - `{:response, map}` — for `"type": "response"` payloads
    - `{:event, map}` — for all other valid JSON with a `"type"` field
    - `{:parse_error, raw_string}` — for non-JSON output
  """
  @spec parse_line(String.t()) :: parsed_line()
  def parse_line(line) when is_binary(line) do
    # Strip optional trailing \r (Pi uses LF, but be tolerant)
    cleaned = String.trim_trailing(line, "\r")

    case Jason.decode(cleaned) do
      {:ok, %{"type" => "response"} = payload} ->
        {:response, payload}

      {:ok, %{"type" => _} = payload} ->
        {:event, payload}

      {:ok, payload} when is_map(payload) ->
        # JSON object without a type field — treat as untyped event
        {:event, payload}

      {:ok, _non_map} ->
        {:parse_error, cleaned}

      {:error, _reason} ->
        log_non_json(cleaned)
        {:parse_error, cleaned}
    end
  end

  @doc """
  Receive the next complete JSONL line from a port, handling partial chunks.

  Returns `{:ok, parsed_line, new_buffer}` or `{:error, reason}`.

  The `buffer` argument carries over incomplete line data from a previous call.
  Pass `""` on first call.
  """
  @spec receive_line(port_ref(), String.t(), timeout()) ::
          {:ok, parsed_line(), String.t()} | {:error, term()}
  def receive_line(port, buffer \\ "", timeout_ms) do
    receive do
      {^port, {:data, {:eol, chunk}}} ->
        complete_line = buffer <> to_string(chunk)
        {:ok, parse_line(complete_line), ""}

      {^port, {:data, {:noeol, chunk}}} ->
        receive_line(port, buffer <> to_string(chunk), timeout_ms)

      {^port, {:exit_status, status}} ->
        {:error, {:port_exit, status}}
    after
      timeout_ms ->
        {:error, :timeout}
    end
  end

  @doc """
  Wait for a response to a specific command, identified by its `id`.

  Discards events and non-matching responses while waiting.
  Returns accumulated events seen while waiting.
  """
  @spec await_response(port_ref(), String.t(), timeout()) ::
          {:ok, map(), [map()]} | {:error, term()}
  def await_response(port, command_id, timeout_ms) do
    do_await_response(port, command_id, timeout_ms, "", [])
  end

  defp do_await_response(port, command_id, timeout_ms, buffer, events_acc) do
    case receive_line(port, buffer, timeout_ms) do
      {:ok, {:response, %{"id" => ^command_id} = response}, _new_buffer} ->
        if response["success"] == true do
          {:ok, response, Enum.reverse(events_acc)}
        else
          {:error, {:command_failed, response["error"] || response, Enum.reverse(events_acc)}}
        end

      {:ok, {:response, _other_response}, new_buffer} ->
        # Response for a different command id — skip
        do_await_response(port, command_id, timeout_ms, new_buffer, events_acc)

      {:ok, {:event, event}, new_buffer} ->
        do_await_response(port, command_id, timeout_ms, new_buffer, [event | events_acc])

      {:ok, {:parse_error, _raw}, new_buffer} ->
        do_await_response(port, command_id, timeout_ms, new_buffer, events_acc)

      {:error, reason} ->
        {:error, reason}
    end
  end

  # ---------------------------------------------------------------------------
  # Command helpers
  # ---------------------------------------------------------------------------

  @doc """
  Build a prompt command map.
  """
  @spec prompt_command(String.t(), keyword()) :: map()
  def prompt_command(message, opts \\ []) do
    cmd = %{"type" => "prompt", "message" => message}

    cmd =
      if id = Keyword.get(opts, :id) do
        Map.put(cmd, "id", id)
      else
        cmd
      end

    cmd =
      if behavior = Keyword.get(opts, :streaming_behavior) do
        Map.put(cmd, "streamingBehavior", behavior)
      else
        cmd
      end

    cmd
  end

  @doc """
  Build an abort command map.
  """
  @spec abort_command(keyword()) :: map()
  def abort_command(opts \\ []) do
    cmd = %{"type" => "abort"}

    if id = Keyword.get(opts, :id) do
      Map.put(cmd, "id", id)
    else
      cmd
    end
  end

  @doc """
  Build a get_state command map.
  """
  @spec get_state_command(keyword()) :: map()
  def get_state_command(opts \\ []) do
    cmd = %{"type" => "get_state"}

    if id = Keyword.get(opts, :id) do
      Map.put(cmd, "id", id)
    else
      cmd
    end
  end

  @doc """
  Build a get_session_stats command map.
  """
  @spec get_session_stats_command(keyword()) :: map()
  def get_session_stats_command(opts \\ []) do
    cmd = %{"type" => "get_session_stats"}

    if id = Keyword.get(opts, :id) do
      Map.put(cmd, "id", id)
    else
      cmd
    end
  end

  # ---------------------------------------------------------------------------
  # Internal
  # ---------------------------------------------------------------------------

  @doc false
  @spec build_argv(keyword()) :: {String.t(), [String.t()]}
  def build_argv(opts) do
    executable = Keyword.get(opts, :command, "pi")

    args = ["--mode", "rpc"]

    args =
      case Keyword.get(opts, :session_dir) do
        nil -> args
        dir -> args ++ ["--session-dir", dir]
      end

    args =
      case build_model_arg(opts) do
        nil -> args
        model_arg -> args ++ ["--model", model_arg]
      end

    args =
      if Keyword.get(opts, :no_session, false) do
        args ++ ["--no-session"]
      else
        args
      end

    args = args ++ Keyword.get(opts, :extra_args, [])

    {executable, args}
  end

  defp resolve_executable(command) do
    expanded = Path.expand(command)

    cond do
      File.exists?(expanded) ->
        {:ok, expanded}

      path = System.find_executable(command) ->
        {:ok, path}

      true ->
        {:error, {:pi_not_found, command}}
    end
  end

  defp build_model_arg(opts) do
    case Keyword.get(opts, :model) do
      nil ->
        nil

      model ->
        case Keyword.get(opts, :thinking) do
          nil -> model
          thinking -> "#{model}:#{thinking}"
        end
    end
  end

  defp log_non_json(data) do
    text =
      data
      |> String.trim()
      |> String.slice(0, @max_log_bytes)

    if text != "" do
      if String.match?(text, ~r/\b(error|warn|warning|failed|fatal|panic|exception)\b/i) do
        Logger.warning("Pi RPC output: #{text}")
      else
        Logger.debug("Pi RPC output: #{text}")
      end
    end
  end
end
