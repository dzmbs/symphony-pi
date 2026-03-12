%{
  configs: [
    %{
      name: "default",
      files: %{
        included: ["lib/", "src/", "test/", "web/"],
        excluded: [~r"^/deps/", ~r"^/_build/"]
      },
      strict: true,
      requires: [],
      plugins: [],
      checks: [
        {Credo.Check.Refactor.CyclomaticComplexity,
         files: %{
           included: ["lib/", "test/"],
           excluded: [
             "lib/symphony_elixir/pi/event_normalizer.ex",
             "lib/symphony_elixir/pi/rpc_backend.ex"
           ]
         }},
        {Credo.Check.Refactor.FunctionArity,
         files: %{
           included: ["lib/", "test/"],
           excluded: [
             "lib/symphony_elixir/agent_runner.ex",
             "lib/symphony_elixir/pi/rpc_backend.ex"
           ]
         }},
        {Credo.Check.Refactor.Nesting,
         files: %{
           included: ["lib/", "test/"],
           excluded: [
             "lib/symphony_elixir/pi/event_normalizer.ex",
             "lib/symphony_elixir/pi/rpc_backend.ex"
           ]
         }},
        {Credo.Check.Refactor.CondStatements,
         files: %{
           included: ["lib/", "test/"],
           excluded: ["lib/symphony_elixir/pi/rpc_backend.ex"]
         }}
      ]
    }
  ]
}
