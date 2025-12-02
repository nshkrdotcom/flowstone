defmodule FlowStone.ErrorRecorder do
  @moduledoc """
  Records structured errors via logs, telemetry, and materialization updates when available.
  """

  require Logger
  alias FlowStone.Materializations

  def record(%FlowStone.Error{} = error, context \\ %{}) do
    Logger.error("FlowStone error",
      type: error.type,
      message: error.message,
      asset: context[:asset],
      partition: context[:partition],
      run_id: context[:run_id],
      retryable: error.retryable
    )

    :telemetry.execute([:flowstone, :error], %{count: 1}, %{
      type: error.type,
      asset: context[:asset],
      retryable: error.retryable
    })

    maybe_record_materialization(error, context)
    :ok
  end

  defp maybe_record_materialization(error, %{asset: asset, partition: partition, run_id: run_id}) do
    if asset && partition && run_id do
      Materializations.record_failure(asset, partition, run_id, error.message)
    else
      :ok
    end
  end

  defp maybe_record_materialization(_error, _), do: :ok
end
