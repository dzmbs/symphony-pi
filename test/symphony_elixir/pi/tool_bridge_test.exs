defmodule SymphonyElixir.Pi.ToolBridgeTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Pi.ToolBridge

  describe "tool bridge lifecycle" do
    test "starts on ephemeral port and responds to health probe" do
      write_workflow_file!(SymphonyElixir.Workflow.workflow_file_path())

      {:ok, pid, port} = ToolBridge.start_link()
      assert is_pid(pid)
      assert is_integer(port)
      assert port > 0

      # 404 for unknown path
      {:ok, resp} = Req.get("http://127.0.0.1:#{port}/unknown")
      assert resp.status == 404

      ToolBridge.stop(pid)
    end

    test "returns 400 for missing query" do
      write_workflow_file!(SymphonyElixir.Workflow.workflow_file_path())

      {:ok, pid, port} = ToolBridge.start_link()

      {:ok, resp} =
        Req.post("http://127.0.0.1:#{port}/linear_graphql",
          json: %{},
          headers: [{"content-type", "application/json"}]
        )

      assert resp.status == 400
      assert resp.body["success"] == false
      assert resp.body["error"] =~ "query"

      ToolBridge.stop(pid)
    end

    test "returns 400 for empty query" do
      write_workflow_file!(SymphonyElixir.Workflow.workflow_file_path())

      {:ok, pid, port} = ToolBridge.start_link()

      {:ok, resp} =
        Req.post("http://127.0.0.1:#{port}/linear_graphql",
          json: %{"query" => ""},
          headers: [{"content-type", "application/json"}]
        )

      assert resp.status == 400
      assert resp.body["success"] == false

      ToolBridge.stop(pid)
    end
  end
end
