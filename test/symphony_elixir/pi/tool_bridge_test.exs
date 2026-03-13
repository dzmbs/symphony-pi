defmodule SymphonyElixir.Pi.ToolBridgeTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Pi.ToolBridge

  defmodule FakeLinearClient do
    def graphql(query, variables) do
      if recipient = Application.get_env(:symphony_elixir, __MODULE__)[:recipient] do
        send(recipient, {:graphql_called, query, variables})
      end

      Application.get_env(:symphony_elixir, __MODULE__)[:graphql_result] || {:ok, %{"data" => %{}}}
    end
  end

  setup do
    previous = Application.get_env(:symphony_elixir, :linear_client_module)
    previous_fake = Application.get_env(:symphony_elixir, FakeLinearClient)
    Application.put_env(:symphony_elixir, :linear_client_module, FakeLinearClient)
    Application.put_env(:symphony_elixir, FakeLinearClient, recipient: self())

    on_exit(fn ->
      if is_nil(previous) do
        Application.delete_env(:symphony_elixir, :linear_client_module)
      else
        Application.put_env(:symphony_elixir, :linear_client_module, previous)
      end

      if is_nil(previous_fake) do
        Application.delete_env(:symphony_elixir, FakeLinearClient)
      else
        Application.put_env(:symphony_elixir, FakeLinearClient, previous_fake)
      end
    end)

    :ok
  end

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

    test "sync_workpad creates a comment" do
      write_workflow_file!(SymphonyElixir.Workflow.workflow_file_path())

      Application.put_env(
        :symphony_elixir,
        FakeLinearClient,
        recipient: self(),
        graphql_result: {:ok, %{"data" => %{"commentCreate" => %{"success" => true}}}}
      )

      {:ok, pid, port} = ToolBridge.start_link()

      {:ok, resp} =
        Req.post("http://127.0.0.1:#{port}/sync_workpad",
          json: %{"issue_id" => "issue-1", "body" => "## Agent Workpad\nbody"},
          headers: [{"content-type", "application/json"}]
        )

      assert resp.status == 200
      assert resp.body["success"] == true
      assert_receive {:graphql_called, query, %{body: "## Agent Workpad\nbody", issueId: "issue-1"}}
      assert query =~ "commentCreate"

      ToolBridge.stop(pid)
    end

    test "sync_workpad updates an existing comment" do
      write_workflow_file!(SymphonyElixir.Workflow.workflow_file_path())

      Application.put_env(
        :symphony_elixir,
        FakeLinearClient,
        recipient: self(),
        graphql_result: {:ok, %{"data" => %{"commentUpdate" => %{"success" => true}}}}
      )

      {:ok, pid, port} = ToolBridge.start_link()

      {:ok, resp} =
        Req.post("http://127.0.0.1:#{port}/sync_workpad",
          json: %{"issue_id" => "issue-1", "comment_id" => "comment-1", "body" => "updated"},
          headers: [{"content-type", "application/json"}]
        )

      assert resp.status == 200
      assert resp.body["success"] == true
      assert_receive {:graphql_called, query, %{body: "updated", commentId: "comment-1"}}
      assert query =~ "commentUpdate"

      ToolBridge.stop(pid)
    end
  end
end
