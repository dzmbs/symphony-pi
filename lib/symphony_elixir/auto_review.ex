defmodule SymphonyElixir.AutoReview do
  @moduledoc """
  Builds and parses the optional automated review stage.
  """

  alias SymphonyElixir.{Config, Linear.Issue}

  @agent_review_state "Agent Review"
  @human_review_state "Human Review"

  @type finding :: %{
          title: String.t() | nil,
          summary: String.t(),
          severity: String.t() | nil,
          path: String.t() | nil
        }

  @type verdict :: %{
          status: :pass | :changes_requested,
          summary: String.t(),
          findings: [finding()]
        }

  @spec enabled?(Config.Schema.t() | nil) :: boolean()
  def enabled?(settings \\ nil)

  @spec enabled?(nil) :: boolean()
  def enabled?(nil), do: enabled?(Config.settings!())

  @spec enabled?(Config.Schema.t()) :: boolean()
  def enabled?(%{auto_review: %{enabled: enabled}}), do: enabled == true

  @spec human_review_state() :: String.t()
  def human_review_state, do: @human_review_state

  @spec agent_review_state() :: String.t()
  def agent_review_state, do: @agent_review_state

  @spec max_rework_passes(Config.Schema.t() | nil) :: non_neg_integer()
  def max_rework_passes(settings \\ nil)

  @spec max_rework_passes(nil) :: non_neg_integer()
  def max_rework_passes(nil), do: max_rework_passes(Config.settings!())

  @spec max_rework_passes(Config.Schema.t()) :: non_neg_integer()
  def max_rework_passes(%{auto_review: %{max_rework_passes: value}}) when is_integer(value), do: value
  def max_rework_passes(_settings), do: 1

  @spec runtime_overrides(Config.Schema.t() | nil) :: keyword()
  def runtime_overrides(settings \\ nil)

  @spec runtime_overrides(nil) :: keyword()
  def runtime_overrides(nil), do: runtime_overrides(Config.settings!())

  @spec runtime_overrides(Config.Schema.t()) :: keyword()
  def runtime_overrides(%{auto_review: auto_review}) do
    []
    |> maybe_put_runtime_override(:model, auto_review.model)
    |> maybe_put_runtime_override(:thinking, auto_review.thinking)
  end

  @spec build_review_prompt(Issue.t()) :: String.t()
  def build_review_prompt(%Issue{} = issue) do
    """
    You are the automated reviewer for Linear issue `#{issue.identifier}`.

    Review the current repository state in this workspace as if you were the first critical reviewer before a human looks at the PR.

    Review checklist:
    - Compare the current diff against the issue requirements.
    - Look for correctness bugs, regressions, broken assumptions, and missing validation.
    - Check whether the implementation actually satisfies the ticket scope.
    - Ignore style-only nits unless they hide a real bug or maintainability problem.

    Working rules:
    - Prefer reading and inspecting over editing.
    - Use the repository state, git diff, and test evidence in the workspace.
    - Do not ask the human for next steps.

    Return ONLY valid JSON with this exact shape:
    {"status":"pass"|"changes_requested","summary":"short summary","findings":[{"severity":"high|medium|low","title":"short title","summary":"what is wrong","path":"optional/file.ext"}]}

    Requirements for the JSON:
    - `status` must be `pass` when there are no blocking findings.
    - `status` must be `changes_requested` when at least one blocking finding exists.
    - `summary` must always be present.
    - `findings` must be an array.
    - If `status` is `pass`, `findings` must be empty.
    - Do not wrap the JSON in markdown fences.
    """
  end

  @spec build_rework_prompt(Issue.t(), verdict(), pos_integer(), pos_integer()) :: String.t()
  def build_rework_prompt(%Issue{} = issue, verdict, rework_pass, max_rework_passes) do
    findings_json =
      verdict
      |> Map.take([:status, :summary, :findings])
      |> Jason.encode_to_iodata!(pretty: true)
      |> IO.iodata_to_binary()

    """
    Rework cycle for Linear issue `#{issue.identifier}`.

    Automated review requested changes after the implementation was moved to `#{@agent_review_state}`.

    This is rework pass #{rework_pass} of #{max_rework_passes}.

    Review findings:
    #{findings_json}

    Instructions:
    - Fix the blocking findings only; do not expand scope.
    - Re-run the validation needed to prove the findings are resolved.
    - Update the existing Agent Workpad comment with what changed and what was validated.
    - When the findings are resolved, move the issue back to `#{@agent_review_state}`.
    - If you discover a genuine blocker, record it clearly in the workpad before stopping.
    """
  end

  @spec parse_verdict(String.t()) :: {:ok, verdict()} | {:error, term()}
  def parse_verdict(text) when is_binary(text) do
    with {:ok, payload} <- extract_json_payload(text),
         {:ok, status} <- parse_status(payload),
         {:ok, findings} <- parse_findings(Map.get(payload, "findings", [])),
         {:ok, summary} <- parse_summary(payload),
         :ok <- validate_findings_for_status(status, findings) do
      {:ok, %{status: status, summary: summary, findings: findings}}
    end
  end

  def parse_verdict(_text), do: {:error, :invalid_review_output}

  defp maybe_put_runtime_override(overrides, _key, nil), do: overrides
  defp maybe_put_runtime_override(overrides, _key, false), do: overrides
  defp maybe_put_runtime_override(overrides, key, value), do: Keyword.put(overrides, key, value)

  defp extract_json_payload(text) do
    trimmed = String.trim(text)

    case Jason.decode(trimmed) do
      {:ok, payload} when is_map(payload) ->
        {:ok, payload}

      _ ->
        extract_embedded_json_payload(trimmed)
    end
  end

  defp extract_embedded_json_payload(trimmed) do
    case Regex.run(~r/\{.*\}/s, trimmed) do
      [json] ->
        case Jason.decode(json) do
          {:ok, payload} when is_map(payload) -> {:ok, payload}
          _ -> {:error, :invalid_review_output}
        end

      _ ->
        {:error, :invalid_review_output}
    end
  end

  defp parse_status(%{"status" => "pass"}), do: {:ok, :pass}
  defp parse_status(%{"status" => "changes_requested"}), do: {:ok, :changes_requested}
  defp parse_status(_payload), do: {:error, :invalid_review_status}

  defp parse_summary(%{"summary" => summary}) when is_binary(summary) and byte_size(summary) > 0,
    do: {:ok, summary}

  defp parse_summary(_payload), do: {:error, :invalid_review_summary}

  defp parse_findings(findings) when is_list(findings) do
    findings
    |> Enum.reduce_while({:ok, []}, fn finding, {:ok, acc} ->
      case normalize_finding(finding) do
        {:ok, normalized} -> {:cont, {:ok, [normalized | acc]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, normalized} -> {:ok, Enum.reverse(normalized)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp parse_findings(_findings), do: {:error, :invalid_review_findings}

  defp normalize_finding(%{} = finding) do
    summary = Map.get(finding, "summary") || Map.get(finding, :summary)

    if is_binary(summary) and byte_size(String.trim(summary)) > 0 do
      {:ok,
       %{
         title: stringify_optional(Map.get(finding, "title") || Map.get(finding, :title)),
         summary: summary,
         severity: stringify_optional(Map.get(finding, "severity") || Map.get(finding, :severity)),
         path: stringify_optional(Map.get(finding, "path") || Map.get(finding, :path))
       }}
    else
      {:error, :invalid_review_findings}
    end
  end

  defp normalize_finding(_finding), do: {:error, :invalid_review_findings}

  defp validate_findings_for_status(:pass, []), do: :ok
  defp validate_findings_for_status(:changes_requested, findings) when findings != [], do: :ok
  defp validate_findings_for_status(:pass, _findings), do: {:error, :pass_with_findings}
  defp validate_findings_for_status(:changes_requested, _findings), do: {:error, :changes_requested_without_findings}

  defp stringify_optional(value) when is_binary(value), do: value
  defp stringify_optional(_value), do: nil
end
