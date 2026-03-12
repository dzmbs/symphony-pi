defmodule SymphonyElixir.AgentBackend do
  @moduledoc """
  Behaviour for agent runtime backends.

  The orchestrator and AgentRunner depend on this abstraction.
  Implementations handle the actual agent subprocess lifecycle.

  The active runtime in this repo is `SymphonyElixir.Pi.RpcBackend` (Pi RPC mode).
  """

  @doc """
  Start a new agent session in the given workspace.

  Returns an opaque session map that must be passed to `run_turn/4` and `stop_session/1`.
  """
  @callback start_session(workspace :: Path.t(), opts :: keyword()) ::
              {:ok, session :: map()} | {:error, term()}

  @doc """
  Execute a single turn (prompt) within an existing session.

  The `session` is the map returned by `start_session/2`.
  The `prompt` is the rendered workflow prompt string.
  The `issue` is the Linear issue map (used for context/logging).
  Options may include `:on_message` callback for streaming updates.

  Returns `{:ok, result, updated_session}` where `updated_session` carries
  any state changes (e.g., turn counters) that must be threaded into the
  next continuation turn.
  """
  @callback run_turn(session :: map(), prompt :: String.t(), issue :: map(), opts :: keyword()) ::
              {:ok, result :: map(), updated_session :: map()} | {:error, term()}

  @doc """
  Stop a session and release its resources.

  Must be safe to call even if the session has already stopped.
  """
  @callback stop_session(session :: map()) :: :ok
end
