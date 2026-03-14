defmodule SymphonyElixir.Pi.PreflightTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Pi.Preflight
  alias SymphonyElixir.Workflow

  @fake_pi_script Path.expand("../../support/fake-pi.sh", __DIR__)

  test "accepts configured implementation and review models exposed by Pi" do
    write_workflow_file!(Workflow.workflow_file_path(),
      pi_command: @fake_pi_script,
      pi_model: "anthropic/claude-sonnet-4-5",
      auto_review_enabled: true,
      auto_review_model: "openai/gpt-5",
      auto_review_thinking: "medium"
    )

    assert :ok = Preflight.validate_workflow()
  end

  test "returns a clear error when a configured review model is unavailable" do
    write_workflow_file!(Workflow.workflow_file_path(),
      pi_command: @fake_pi_script,
      pi_model: "anthropic/claude-sonnet-4-5",
      auto_review_enabled: true,
      auto_review_model: "anthropic/claude-opus-4-6"
    )

    assert {:error, message} = Preflight.validate_workflow()
    assert message =~ "Missing model(s): anthropic/claude-opus-4-6"
  end
end
