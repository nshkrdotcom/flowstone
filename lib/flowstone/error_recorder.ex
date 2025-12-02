defmodule FlowStone.ErrorRecorder do
  @moduledoc """
  Records structured errors via logs and telemetry.
  """

  require Logger

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

    :ok
  end
end
