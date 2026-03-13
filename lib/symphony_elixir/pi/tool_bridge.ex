defmodule SymphonyElixir.Pi.ToolBridge do
  @moduledoc """
  Local HTTP bridge that serves tool requests from Pi extensions.

  The bridge starts on an ephemeral port and exposes two endpoints:

    POST /linear_graphql
    POST /sync_workpad

  The Pi extension calls this endpoint instead of duplicating Linear auth
  in TypeScript. This keeps auth in Elixir and avoids duplicating tracker
  credentials in the extension layer.
  """

  use Plug.Router

  require Logger

  alias SymphonyElixir.Linear.{Adapter, Client}

  plug(Plug.Parsers,
    parsers: [:json],
    json_decoder: Jason,
    pass: ["application/json"]
  )

  plug(:match)
  plug(:dispatch)

  post "/linear_graphql" do
    case conn.body_params do
      %{"query" => query} = params when is_binary(query) and query != "" ->
        variables = Map.get(params, "variables", %{})

        case Client.graphql(query, variables) do
          {:ok, response} ->
            has_errors = match?(%{"errors" => [_ | _]}, response)

            conn
            |> put_resp_content_type("application/json")
            |> send_resp(200, Jason.encode!(%{success: !has_errors, data: response}))

          {:error, reason} ->
            conn
            |> put_resp_content_type("application/json")
            |> send_resp(502, Jason.encode!(%{success: false, error: format_error(reason)}))
        end

      _ ->
        conn
        |> put_resp_content_type("application/json")
        |> send_resp(400, Jason.encode!(%{success: false, error: "Missing or empty `query` field"}))
    end
  end

  post "/sync_workpad" do
    case conn.body_params do
      %{"issue_id" => issue_id, "body" => body} = params
      when is_binary(issue_id) and issue_id != "" and is_binary(body) and body != "" ->
        result =
          case Map.get(params, "comment_id") do
            comment_id when is_binary(comment_id) and comment_id != "" ->
              Adapter.update_comment(comment_id, body)

            _ ->
              Adapter.create_comment(issue_id, body)
          end

        case result do
          :ok ->
            conn
            |> put_resp_content_type("application/json")
            |> send_resp(200, Jason.encode!(%{success: true}))

          {:error, reason} ->
            conn
            |> put_resp_content_type("application/json")
            |> send_resp(502, Jason.encode!(%{success: false, error: format_error(reason)}))
        end

      _ ->
        conn
        |> put_resp_content_type("application/json")
        |> send_resp(400, Jason.encode!(%{success: false, error: "Missing required fields: `issue_id` and non-empty `body`"}))
    end
  end

  match _ do
    send_resp(conn, 404, "not found")
  end

  # ---------------------------------------------------------------------------
  # Lifecycle
  # ---------------------------------------------------------------------------

  @doc """
  Start the tool bridge on an ephemeral port.

  Returns `{:ok, pid, port}` where `port` is the bound port number.
  """
  @spec start_link(keyword()) :: {:ok, pid(), non_neg_integer()} | {:error, term()}
  def start_link(opts \\ []) do
    ref = Keyword.get(opts, :ref, __MODULE__)

    # Use a TCP socket to find a free port first, then bind Bandit to it
    {:ok, socket} = :gen_tcp.listen(0, [:binary, ip: {127, 0, 0, 1}])
    {:ok, port} = :inet.port(socket)
    :gen_tcp.close(socket)

    case Bandit.start_link(
           plug: __MODULE__,
           port: port,
           ip: {127, 0, 0, 1},
           scheme: :http,
           thousand_island_options: [num_acceptors: 1, num_connections: 10],
           startup_log: false
         ) do
      {:ok, pid} ->
        Logger.info("Pi tool bridge started ref=#{ref} port=#{port}")
        {:ok, pid, port}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Stop the tool bridge.
  """
  @spec stop(pid()) :: :ok
  def stop(pid) when is_pid(pid) do
    Supervisor.stop(pid, :normal)
    :ok
  rescue
    _ -> :ok
  end

  # ---------------------------------------------------------------------------
  # Internal
  # ---------------------------------------------------------------------------

  defp format_error({:linear_api_status, status}), do: "Linear API returned HTTP #{status}"
  defp format_error({:linear_api_request, reason}), do: "Linear API request failed: #{inspect(reason)}"
  defp format_error(:missing_linear_api_token), do: "Linear API token not configured"
  defp format_error(:comment_create_failed), do: "Linear comment creation failed"
  defp format_error(:comment_update_failed), do: "Linear comment update failed"
  defp format_error(reason), do: inspect(reason)
end
