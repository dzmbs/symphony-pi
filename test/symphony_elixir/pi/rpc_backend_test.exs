defmodule SymphonyElixir.Pi.RpcBackendTest do
  use ExUnit.Case

  alias SymphonyElixir.Pi.RpcBackend

  describe "start_session/2" do
    test "module implements AgentBackend behaviour" do
      # Ensure module is loaded
      Code.ensure_loaded!(RpcBackend)

      assert function_exported?(RpcBackend, :start_session, 2)
      assert function_exported?(RpcBackend, :run_turn, 4)
      assert function_exported?(RpcBackend, :stop_session, 1)
    end
  end

  describe "stop_session/1" do
    test "handles nil/empty session gracefully" do
      assert :ok = RpcBackend.stop_session(%{})
      assert :ok = RpcBackend.stop_session(nil)
    end
  end
end
