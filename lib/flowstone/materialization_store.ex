defmodule FlowStone.MaterializationStore do
  @moduledoc """
  Lightweight in-memory store for materialization metadata.

  Intended as a test/development stub until durable DB wiring is enabled.
  Keys are normalized to ensure consistent lookups.
  """

  use Agent
  alias FlowStone.Partition

  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    Agent.start_link(fn -> %{} end, name: name)
  end

  def record_start(asset, partition, run_id, server \\ __MODULE__) do
    key = normalize_key(asset, partition, run_id)

    entry = %{
      asset: asset,
      partition: partition,
      run_id: run_id,
      status: :running,
      started_at: DateTime.utc_now()
    }

    Agent.update(server, &Map.put(&1, key, entry))
    :ok
  end

  def record_success(asset, partition, run_id, duration_ms, server \\ __MODULE__) do
    key = normalize_key(asset, partition, run_id)
    now = DateTime.utc_now()

    Agent.update(server, fn state ->
      Map.update(
        state,
        key,
        %{
          asset: asset,
          partition: partition,
          run_id: run_id,
          status: :success,
          started_at: now,
          completed_at: now,
          duration_ms: duration_ms
        },
        fn entry ->
          Map.merge(entry, %{
            status: :success,
            completed_at: now,
            duration_ms: duration_ms
          })
        end
      )
    end)

    :ok
  end

  def record_failure(asset, partition, run_id, error, server \\ __MODULE__) do
    key = normalize_key(asset, partition, run_id)
    now = DateTime.utc_now()

    Agent.update(server, fn state ->
      Map.update(
        state,
        key,
        %{
          asset: asset,
          partition: partition,
          run_id: run_id,
          status: :failed,
          started_at: now,
          error: error,
          completed_at: now
        },
        fn entry ->
          Map.merge(entry, %{
            status: :failed,
            error: error,
            completed_at: now
          })
        end
      )
    end)

    :ok
  end

  def record_skipped(asset, partition, run_id, duration_ms, server \\ __MODULE__) do
    key = normalize_key(asset, partition, run_id)
    now = DateTime.utc_now()

    Agent.update(server, fn state ->
      Map.update(
        state,
        key,
        %{
          asset: asset,
          partition: partition,
          run_id: run_id,
          status: :skipped,
          started_at: now,
          completed_at: now,
          duration_ms: duration_ms
        },
        fn entry ->
          Map.merge(entry, %{
            status: :skipped,
            completed_at: now,
            duration_ms: duration_ms
          })
        end
      )
    end)

    :ok
  end

  def get(asset, partition, run_id, server \\ __MODULE__) do
    key = normalize_key(asset, partition, run_id)
    Agent.get(server, &Map.get(&1, key))
  end

  def list(server \\ __MODULE__) do
    Agent.get(server, &Map.values/1)
  end

  # Normalize key to ensure consistent lookups
  defp normalize_key(asset, partition, run_id) do
    asset_str = to_string(asset)
    partition_str = Partition.serialize(partition)
    {asset_str, partition_str, run_id}
  end
end
