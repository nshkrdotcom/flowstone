defmodule FlowStone.Logger do
  @moduledoc """
  Structured logging helpers.
  """

  require Logger

  def log_materialization_start(asset, partition, run_id) do
    Logger.info("Materialization started",
      flowstone: true,
      event: :materialization_start,
      asset: asset,
      partition: partition,
      run_id: run_id
    )
  end

  def log_materialization_complete(asset, partition, run_id, duration_ms) do
    Logger.info("Materialization completed",
      flowstone: true,
      event: :materialization_complete,
      asset: asset,
      partition: partition,
      run_id: run_id,
      duration_ms: duration_ms
    )
  end

  def log_materialization_failed(asset, partition, run_id, error) do
    Logger.error("Materialization failed",
      flowstone: true,
      event: :materialization_failed,
      asset: asset,
      partition: partition,
      run_id: run_id,
      error_type: error.type,
      error_message: error.message,
      retryable: error.retryable
    )
  end
end
