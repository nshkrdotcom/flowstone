defmodule FlowStone.Materializations do
  @moduledoc """
  Persistence wrapper for materialization metadata with Repo-or-fallback semantics.

  Uses upsert logic to handle concurrent writes safely when using the database.
  """

  alias FlowStone.{Materialization, MaterializationStore, Repo}

  @spec record_start(atom(), term(), binary(), keyword()) :: :ok | {:error, term()}
  def record_start(asset, partition, run_id, opts \\ []) do
    metadata = Keyword.get(opts, :metadata, %{})

    if use_repo?(opts) do
      params = %{
        asset_name: to_string(asset),
        partition: FlowStone.Partition.serialize(partition),
        run_id: run_id,
        status: :running,
        started_at: DateTime.utc_now(),
        metadata: metadata
      }

      # Use upsert to handle concurrent inserts safely
      %Materialization{}
      |> Materialization.changeset(params)
      |> Repo.insert(
        on_conflict: {:replace, [:status, :started_at, :metadata, :updated_at]},
        conflict_target: [:asset_name, :partition, :run_id]
      )
      |> normalize_result()
    else
      store = Keyword.get(opts, :store, MaterializationStore)

      maybe_store(store, fn ->
        MaterializationStore.record_start(asset, partition, run_id, store)
      end)
    end
  end

  @spec record_success(atom(), term(), binary(), integer(), keyword()) :: :ok | {:error, term()}
  def record_success(asset, partition, run_id, duration_ms, opts \\ []) do
    if use_repo?(opts) do
      upsert_record(asset, partition, run_id, %{
        status: :success,
        completed_at: DateTime.utc_now(),
        duration_ms: duration_ms
      })
    else
      store = Keyword.get(opts, :store, MaterializationStore)

      maybe_store(store, fn ->
        MaterializationStore.record_success(asset, partition, run_id, duration_ms, store)
      end)
    end
  end

  @spec record_failure(atom(), term(), binary(), term(), keyword()) :: :ok | {:error, term()}
  def record_failure(asset, partition, run_id, error, opts \\ []) do
    error_message =
      case error do
        %{message: msg} -> msg
        other -> inspect(other)
      end

    if use_repo?(opts) do
      upsert_record(asset, partition, run_id, %{
        status: :failed,
        completed_at: DateTime.utc_now(),
        error_message: error_message
      })
    else
      store = Keyword.get(opts, :store, MaterializationStore)

      maybe_store(store, fn ->
        MaterializationStore.record_failure(asset, partition, run_id, error, store)
      end)
    end
  end

  @spec record_skipped(atom(), term(), binary(), integer(), keyword()) :: :ok | {:error, term()}
  def record_skipped(asset, partition, run_id, duration_ms, opts \\ []) do
    if use_repo?(opts) do
      upsert_record(asset, partition, run_id, %{
        status: :skipped,
        completed_at: DateTime.utc_now(),
        duration_ms: duration_ms
      })
    else
      store = Keyword.get(opts, :store, MaterializationStore)

      maybe_store(store, fn ->
        MaterializationStore.record_skipped(asset, partition, run_id, duration_ms, store)
      end)
    end
  end

  def record_waiting_approval(asset, partition, run_id, opts \\ []) do
    if use_repo?(opts) do
      upsert_record(asset, partition, run_id, %{
        status: :waiting_approval
      })
    else
      :ok
    end
  end

  # Use upsert to safely handle concurrent writes
  defp upsert_record(asset, partition, run_id, changes) do
    partition_str = FlowStone.Partition.serialize(partition)
    asset_str = to_string(asset)

    base_params = %{
      asset_name: asset_str,
      partition: partition_str,
      run_id: run_id
    }

    params = Map.merge(base_params, changes)

    # Get the keys to update on conflict (all provided changes)
    update_keys = Map.keys(changes) ++ [:updated_at]

    %Materialization{}
    |> Materialization.changeset(params)
    |> Repo.insert(
      on_conflict: {:replace, update_keys},
      conflict_target: [:asset_name, :partition, :run_id]
    )
    |> normalize_result()
  end

  defp use_repo?(opts), do: Keyword.get(opts, :use_repo, true) and repo_running?()

  defp repo_running?,
    do: Application.get_env(:flowstone, :start_repo, false) and Process.whereis(Repo) != nil

  defp maybe_store(nil, _fun), do: :ok

  defp maybe_store(store, fun) do
    if Process.whereis(store) do
      fun.()
    else
      :ok
    end
  end

  defp normalize_result({:ok, _}), do: :ok
  defp normalize_result({:error, reason}), do: {:error, reason}
end
