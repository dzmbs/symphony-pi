defmodule SymphonyElixir.SSH do
  @moduledoc """
  SSH utilities for remote worker execution.

  Provides command execution and port-based stdio transport over SSH,
  supporting the worker architecture where Pi runs on remote hosts.
  """

  @spec run(String.t(), String.t(), keyword()) :: {:ok, {String.t(), non_neg_integer()}} | {:error, term()}
  def run(host, command, opts \\ []) when is_binary(host) and is_binary(command) do
    with {:ok, executable} <- ssh_executable() do
      {:ok, System.cmd(executable, ssh_args(host, command), opts)}
    end
  end

  @spec start_port(String.t(), String.t(), keyword()) :: {:ok, port()} | {:error, term()}
  def start_port(host, command, opts \\ []) when is_binary(host) and is_binary(command) do
    with {:ok, executable} <- ssh_executable() do
      line_bytes = Keyword.get(opts, :line)
      reverse_forward = Keyword.get(opts, :reverse_forward)

      port_opts =
        [
          :binary,
          :exit_status,
          :stderr_to_stdout,
          args: Enum.map(ssh_args(host, command, reverse_forward: reverse_forward), &String.to_charlist/1)
        ]
        |> maybe_put_line_option(line_bytes)

      {:ok, Port.open({:spawn_executable, String.to_charlist(executable)}, port_opts)}
    end
  end

  @spec remote_shell_command(String.t()) :: String.t()
  def remote_shell_command(command) when is_binary(command) do
    "bash -lc " <> shell_escape(command)
  end

  defp ssh_executable do
    case System.find_executable("ssh") do
      nil -> {:error, :ssh_not_found}
      executable -> {:ok, executable}
    end
  end

  defp ssh_args(host, command, opts \\ []) do
    %{destination: destination, port: port} = parse_target(host)
    reverse_forward = Keyword.get(opts, :reverse_forward)

    []
    |> maybe_put_config()
    |> Kernel.++(["-T"])
    |> maybe_put_port(port)
    |> maybe_put_reverse_forward(reverse_forward)
    |> Kernel.++([destination, remote_shell_command(command)])
  end

  defp maybe_put_line_option(port_opts, nil), do: port_opts
  defp maybe_put_line_option(port_opts, line_bytes), do: Keyword.put(port_opts, :line, line_bytes)

  defp maybe_put_config(args) do
    case System.get_env("SYMPHONY_SSH_CONFIG") do
      config_path when is_binary(config_path) and config_path != "" ->
        args ++ ["-F", config_path]

      _ ->
        args
    end
  end

  defp maybe_put_port(args, nil), do: args
  defp maybe_put_port(args, port), do: args ++ ["-p", port]

  defp maybe_put_reverse_forward(args, nil), do: args

  defp maybe_put_reverse_forward(args, {remote_port, local_port}) do
    args ++ ["-R", "#{remote_port}:127.0.0.1:#{local_port}"]
  end

  defp parse_target(target) when is_binary(target) do
    trimmed_target = String.trim(target)

    case Regex.run(~r/^(.*):(\d+)$/, trimmed_target, capture: :all_but_first) do
      [destination, port] ->
        if valid_port_destination?(destination) do
          %{destination: destination, port: port}
        else
          %{destination: trimmed_target, port: nil}
        end

      _ ->
        %{destination: trimmed_target, port: nil}
    end
  end

  defp valid_port_destination?(destination) when is_binary(destination) do
    destination != "" and
      (not String.contains?(destination, ":") or bracketed_host?(destination))
  end

  defp bracketed_host?(destination) when is_binary(destination) do
    String.contains?(destination, "[") and String.contains?(destination, "]")
  end

  defp shell_escape(value) when is_binary(value) do
    "'" <> String.replace(value, "'", "'\"'\"'") <> "'"
  end
end
