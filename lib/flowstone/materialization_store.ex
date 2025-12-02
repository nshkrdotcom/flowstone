defmodule FlowStone.MaterializationStore do
  @moduledoc """
  Lightweight in-memory store for materialization metadata.

  Intended as a test/development stub until durable DB wiring is enabled.
  """

  use Agent

  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    Agent.start_link(fn -> %{} end, name: name)
  end

  def record_start(asset, partition, run_id, server \\ __MODULE__) do
    entry = %{
      asset: asset,
      partition: partition,
      run_id: run_id,
      status: :running,
      started_at: DateTime.utc_now()
    }

    Agent.update(server, &Map.put(&1, {asset, partition, run_id}, entry))
    :ok
  end

  def record_success(asset, partition, run_id, duration_ms, server \\ __MODULE__) do
    Agent.update(server, fn state ->
      Map.update(
        state,
        {asset, partition, run_id},
        %{
          asset: asset,
          partition: partition,
          run_id: run_id,
          status: :success,
          completed_at: DateTime.utc_now(),
          duration_ms: duration_ms
        },
        fn entry ->
          Map.merge(entry, %{
            status: :success,
            completed_at: DateTime.utc_now(),
            duration_ms: duration_ms
          })
        end
      )
    end)

    :ok
  end

  def record_failure(asset, partition, run_id, error, server \\ __MODULE__) do
    Agent.update(server, fn state ->
      Map.update(
        state,
        {asset, partition, run_id},
        %{
          asset: asset,
          partition: partition,
          run_id: run_id,
          status: :failed,
          error: error,
          completed_at: DateTime.utc_now()
        },
        fn entry ->
          Map.merge(entry, %{
            status: :failed,
            error: error,
            completed_at: DateTime.utc_now()
          })
        end
      )
    end)

    :ok
  end

  def get(asset, partition, run_id, server \\ __MODULE__) do
    Agent.get(server, &Map.get(&1, {asset, partition, run_id}))
  end

  def list(server \\ __MODULE__) do
    Agent.get(server, &Map.values/1)
  end
end
