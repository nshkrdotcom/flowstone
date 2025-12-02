defmodule FlowStone.Materializations do
  @moduledoc """
  Persistence wrapper for materialization metadata with Repo-or-fallback semantics.
  """

  alias FlowStone.{Materialization, MaterializationStore, Repo}

  @spec record_start(atom(), term(), binary(), keyword()) :: :ok | {:error, term()}
  def record_start(asset, partition, run_id, opts \\ []) do
    metadata = Keyword.get(opts, :metadata, %{})

    if use_repo?(opts) do
      params = %{
        asset_name: Atom.to_string(asset),
        partition: FlowStone.Partition.serialize(partition),
        run_id: run_id,
        status: :running,
        started_at: DateTime.utc_now(),
        metadata: metadata
      }

      %Materialization{}
      |> Materialization.changeset(params)
      |> Repo.insert()
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
      update_record(asset, partition, run_id, %{
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
    if use_repo?(opts) do
      update_record(asset, partition, run_id, %{
        status: :failed,
        completed_at: DateTime.utc_now(),
        error_message: inspect(error)
      })
    else
      store = Keyword.get(opts, :store, MaterializationStore)

      maybe_store(store, fn ->
        MaterializationStore.record_failure(asset, partition, run_id, error, store)
      end)
    end
  end

  defp update_record(asset, partition, run_id, changes) do
    partition_str = FlowStone.Partition.serialize(partition)

    case Repo.get_by(Materialization,
           asset_name: Atom.to_string(asset),
           partition: partition_str,
           run_id: run_id
         ) do
      nil ->
        %Materialization{}
        |> Materialization.changeset(
          Map.merge(
            %{
              asset_name: Atom.to_string(asset),
              partition: partition_str,
              run_id: run_id
            },
            changes
          )
        )
        |> Repo.insert()
        |> normalize_result()

      record ->
        record
        |> Materialization.changeset(changes)
        |> Repo.update()
        |> normalize_result()
    end
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
