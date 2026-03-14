defmodule SymphonyElixir.Pi.ToolBridgeTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Pi.ToolBridge

  defmodule FakeLinearClient do
    def graphql(query, variables) do
      if recipient = Application.get_env(:symphony_elixir, __MODULE__)[:recipient] do
        send(recipient, {:graphql_called, query, variables})
      end

      case Application.get_env(:symphony_elixir, __MODULE__)[:graphql_results] do
        [result | rest] ->
          Application.put_env(
            :symphony_elixir,
            __MODULE__,
            Application.get_env(:symphony_elixir, __MODULE__)
            |> Keyword.put(:graphql_results, rest)
          )

          result

        _ ->
          Application.get_env(:symphony_elixir, __MODULE__)[:graphql_result] || {:ok, %{"data" => %{}}}
      end
    end
  end

  defmodule SerialLinearClient do
    def graphql(query, variables) do
      config = Application.get_env(:symphony_elixir, __MODULE__, [])
      atomics = Keyword.fetch!(config, :atomics)
      sleep_ms = Keyword.get(config, :sleep_ms, 0)

      current = :atomics.add_get(atomics, 1, 1)
      update_max(atomics, current)

      if recipient = config[:recipient] do
        send(recipient, {:serial_graphql_called, query, variables, current})
      end

      Process.sleep(sleep_ms)
      :atomics.sub_get(atomics, 1, 1)

      cond do
        String.contains?(query, "commentCreate") ->
          {:ok, %{"data" => %{"commentCreate" => %{"success" => true}}}}

        String.contains?(query, "commentUpdate") ->
          {:ok, %{"data" => %{"commentUpdate" => %{"success" => true}}}}

        String.contains?(query, "comments(first: 50)") ->
          {:ok, %{"data" => %{"issue" => %{"comments" => %{"nodes" => []}}}}}

        true ->
          {:ok, %{"data" => %{}}}
      end
    end

    defp update_max(atomics, current) do
      max = :atomics.get(atomics, 2)

      if current > max do
        case :atomics.compare_exchange(atomics, 2, max, current) do
          ^max -> :ok
          _ -> update_max(atomics, current)
        end
      else
        :ok
      end
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
        graphql_results: [
          {:ok, %{"data" => %{"issue" => %{"comments" => %{"nodes" => []}}}}},
          {:ok, %{"data" => %{"commentCreate" => %{"success" => true}}}}
        ]
      )

      {:ok, pid, port} = ToolBridge.start_link()

      {:ok, resp} =
        Req.post("http://127.0.0.1:#{port}/sync_workpad",
          json: %{"issue_id" => "issue-1", "body" => "## Agent Workpad\nbody"},
          headers: [{"content-type", "application/json"}]
        )

      assert resp.status == 200
      assert resp.body["success"] == true
      assert_receive {:graphql_called, lookup_query, %{issueId: "issue-1"}}
      assert lookup_query =~ "comments(first: 50)"
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

    test "sync_workpad auto-updates the existing Agent Workpad comment when comment_id is omitted" do
      write_workflow_file!(SymphonyElixir.Workflow.workflow_file_path())

      Application.put_env(
        :symphony_elixir,
        FakeLinearClient,
        recipient: self(),
        graphql_results: [
          {:ok,
           %{
             "data" => %{
               "issue" => %{
                 "comments" => %{
                   "nodes" => [
                     %{"id" => "comment-7", "body" => "## Agent Workpad\nold body", "resolvedAt" => nil}
                   ]
                 }
               }
             }
           }},
          {:ok, %{"data" => %{"commentUpdate" => %{"success" => true}}}}
        ]
      )

      {:ok, pid, port} = ToolBridge.start_link()

      {:ok, resp} =
        Req.post("http://127.0.0.1:#{port}/sync_workpad",
          json: %{"issue_id" => "issue-1", "body" => "## Agent Workpad\nnew body"},
          headers: [{"content-type", "application/json"}]
        )

      assert resp.status == 200
      assert resp.body["success"] == true
      assert_receive {:graphql_called, lookup_query, %{issueId: "issue-1"}}
      assert lookup_query =~ "comments(first: 50)"
      assert_receive {:graphql_called, update_query, %{body: "## Agent Workpad\nnew body", commentId: "comment-7"}}
      assert update_query =~ "commentUpdate"

      ToolBridge.stop(pid)
    end

    test "serializes concurrent linear_graphql requests" do
      previous = Application.get_env(:symphony_elixir, :linear_client_module)
      atomics = :atomics.new(2, [])

      Application.put_env(:symphony_elixir, :linear_client_module, SerialLinearClient)
      Application.put_env(:symphony_elixir, SerialLinearClient, recipient: self(), atomics: atomics, sleep_ms: 75)

      on_exit(fn ->
        if is_nil(previous) do
          Application.delete_env(:symphony_elixir, :linear_client_module)
        else
          Application.put_env(:symphony_elixir, :linear_client_module, previous)
        end

        Application.delete_env(:symphony_elixir, SerialLinearClient)
      end)

      write_workflow_file!(SymphonyElixir.Workflow.workflow_file_path())

      {:ok, pid, port} = ToolBridge.start_link()

      task1 =
        Task.async(fn ->
          Req.post!("http://127.0.0.1:#{port}/linear_graphql",
            json: %{"query" => "query First { viewer { id } }"},
            headers: [{"content-type", "application/json"}]
          )
        end)

      task2 =
        Task.async(fn ->
          Req.post!("http://127.0.0.1:#{port}/linear_graphql",
            json: %{"query" => "query Second { viewer { id } }"},
            headers: [{"content-type", "application/json"}]
          )
        end)

      assert %Req.Response{status: 200} = Task.await(task1, 1_000)
      assert %Req.Response{status: 200} = Task.await(task2, 1_000)
      assert :atomics.get(atomics, 2) == 1

      ToolBridge.stop(pid)
    end

    test "serializes concurrent sync_workpad requests for the same issue" do
      previous = Application.get_env(:symphony_elixir, :linear_client_module)
      atomics = :atomics.new(2, [])

      Application.put_env(:symphony_elixir, :linear_client_module, SerialLinearClient)
      Application.put_env(:symphony_elixir, SerialLinearClient, recipient: self(), atomics: atomics, sleep_ms: 75)

      on_exit(fn ->
        if is_nil(previous) do
          Application.delete_env(:symphony_elixir, :linear_client_module)
        else
          Application.put_env(:symphony_elixir, :linear_client_module, previous)
        end

        Application.delete_env(:symphony_elixir, SerialLinearClient)
      end)

      write_workflow_file!(SymphonyElixir.Workflow.workflow_file_path())

      {:ok, pid, port} = ToolBridge.start_link()

      task1 =
        Task.async(fn ->
          Req.post!("http://127.0.0.1:#{port}/sync_workpad",
            json: %{"issue_id" => "issue-serial", "body" => "## Agent Workpad\nfirst"},
            headers: [{"content-type", "application/json"}]
          )
        end)

      task2 =
        Task.async(fn ->
          Req.post!("http://127.0.0.1:#{port}/sync_workpad",
            json: %{"issue_id" => "issue-serial", "body" => "## Agent Workpad\nsecond"},
            headers: [{"content-type", "application/json"}]
          )
        end)

      assert %Req.Response{status: 200} = Task.await(task1, 1_000)
      assert %Req.Response{status: 200} = Task.await(task2, 1_000)
      assert :atomics.get(atomics, 2) == 1

      ToolBridge.stop(pid)
    end
  end
end
