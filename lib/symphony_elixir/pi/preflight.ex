defmodule SymphonyElixir.Pi.Preflight do
  @moduledoc """
  Best-effort startup validation for Pi runtime settings.
  """

  alias SymphonyElixir.{Config, Pi.RpcClient}

  @command_id "symphony-model-preflight"

  @spec validate_workflow() :: :ok | {:error, String.t()}
  def validate_workflow do
    case Config.settings() do
      {:ok, settings} ->
        case configured_models(settings) do
          [] -> :ok
          models -> validate_configured_models(models, settings.pi.command)
        end

      {:error, reason} ->
        {:error, "Workflow validation failed before Pi model preflight: #{inspect(reason)}"}
    end
  end

  defp validate_configured_models(models, command) do
    case available_model_ids(command) do
      {:ok, available_models} ->
        case Enum.reject(models, &MapSet.member?(available_models, &1)) do
          [] ->
            :ok

          missing ->
            {:error,
             "Pi model validation failed. Missing model(s): #{Enum.join(missing, ", ")}. " <>
               "Available models are determined by your local `pi` installation."}
        end

      {:error, {:pi_not_found, missing_command}} ->
        {:error, "Pi model validation failed: could not find Pi command #{inspect(missing_command)}"}

      {:error, reason} ->
        {:error, "Pi model validation failed: #{inspect(reason)}"}
    end
  end

  defp configured_models(settings) do
    [settings.pi.model, auto_review_model(settings)]
    |> Enum.filter(&is_binary/1)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
  end

  defp auto_review_model(%{auto_review: %{enabled: true, model: model}}), do: model
  defp auto_review_model(_settings), do: nil

  @spec available_model_ids(String.t()) :: {:ok, MapSet.t(String.t())} | {:error, term()}
  def available_model_ids(command) when is_binary(command) do
    temp_dir =
      Path.join(System.tmp_dir!(), "symphony-pi-model-preflight-#{System.unique_integer([:positive])}")

    File.mkdir_p!(temp_dir)

    case RpcClient.start(temp_dir, command: command, no_session: true) do
      {:ok, port} ->
        try do
          fetch_available_model_ids(port)
        after
          RpcClient.stop(port)
          File.rm_rf(temp_dir)
        end

      {:error, reason} ->
        File.rm_rf(temp_dir)
        {:error, reason}
    end
  end

  defp fetch_available_model_ids(port) do
    with :ok <- RpcClient.send_command(port, RpcClient.get_available_models_command(id: @command_id)),
         {:ok, %{"data" => %{"models" => models}}, _events} <- RpcClient.await_response(port, @command_id, 5_000) do
      {:ok,
       models
       |> Enum.map(&model_identifier/1)
       |> Enum.filter(&is_binary/1)
       |> MapSet.new()}
    else
      {:error, :port_closed} -> {:error, {:pi_model_validation_failed, :port_closed}}
      {:error, reason} -> {:error, reason}
      _ -> {:error, :invalid_get_available_models_response}
    end
  end

  defp model_identifier(%{"provider" => provider, "id" => model_id})
       when is_binary(provider) and is_binary(model_id) do
    "#{provider}/#{model_id}"
  end

  defp model_identifier(%{provider: provider, id: model_id})
       when is_binary(provider) and is_binary(model_id) do
    "#{provider}/#{model_id}"
  end

  defp model_identifier(_model), do: nil
end
