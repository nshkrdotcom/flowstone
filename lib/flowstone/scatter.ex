defmodule FlowStone.Scatter do
  @moduledoc """
  Core Scatter functionality for dynamic fan-out.

  Scatter enables runtime-discovered parallel execution within FlowStone's
  asset-centric model. An asset can "scatter" into N instances based on
  data from upstream dependencies, execute in parallel, and reconverge
  for downstream assets.

  ## Overview

  1. **Scatter Phase**: Asset's scatter function returns list of scatter keys
  2. **Execution Phase**: Each scatter key becomes an independent job
  3. **Barrier Tracking**: Postgres-based coordination of all instances
  4. **Gather Phase**: Results aggregated for downstream consumption

  ## Example

      asset :scraped_article do
        depends_on [:source_urls]

        scatter fn %{source_urls: urls} ->
          Enum.map(urls, &%{url: &1})
        end

        scatter_options do
          max_concurrent 50
          rate_limit {10, :second}
          failure_threshold 0.02
        end

        execute fn ctx, _deps ->
          Scraper.fetch(ctx.scatter_key.url)
        end
      end
  """

  import Ecto.Query
  alias FlowStone.{Repo, Partition}
  alias FlowStone.Scatter.{Barrier, Key, Options, Result}

  @type scatter_key :: Key.t()
  @type barrier :: Barrier.t()

  @doc """
  Create a scatter barrier and initialize result records.

  ## Options

  - `:run_id` - Parent run identifier (required)
  - `:asset_name` - The scattering asset (required)
  - `:partition` - Base partition (optional)
  - `:scatter_keys` - List of scatter keys from scatter function (required)
  - `:scatter_source_asset` - Asset that provided the scatter data (optional)
  - `:options` - ScatterOptions struct (optional)
  - `:metadata` - Additional metadata (optional)
  """
  @spec create_barrier(keyword()) :: {:ok, barrier()} | {:error, term()}
  def create_barrier(opts) do
    run_id = Keyword.fetch!(opts, :run_id)
    asset_name = Keyword.fetch!(opts, :asset_name)
    scatter_keys = Keyword.fetch!(opts, :scatter_keys)
    scatter_opts = Keyword.get(opts, :options, %Options{})

    partition =
      case Keyword.get(opts, :partition) do
        nil -> nil
        p -> Partition.serialize(p)
      end

    normalized_keys = Enum.map(scatter_keys, &Key.normalize/1)

    attrs = %{
      run_id: run_id,
      asset_name: to_string(asset_name),
      scatter_source_asset: opts[:scatter_source_asset] && to_string(opts[:scatter_source_asset]),
      partition: partition,
      total_count: length(normalized_keys),
      scatter_keys: normalized_keys,
      options: Options.to_map(scatter_opts),
      metadata: Keyword.get(opts, :metadata, %{}),
      status: :executing
    }

    Repo.transaction(fn ->
      # Create barrier
      barrier =
        %Barrier{}
        |> Barrier.changeset(attrs)
        |> Repo.insert!()

      # Create result records for each scatter key
      now = DateTime.utc_now()

      result_records =
        normalized_keys
        |> Enum.with_index()
        |> Enum.map(fn {key, index} ->
          %{
            id: Ecto.UUID.generate(),
            barrier_id: barrier.id,
            scatter_key_hash: Key.hash(key),
            scatter_key: key,
            scatter_index: index,
            status: :pending,
            inserted_at: now,
            updated_at: now
          }
        end)

      Repo.insert_all(Result, result_records)

      emit_telemetry(:start, barrier)

      barrier
    end)
  end

  @doc """
  Record completion of a scattered instance.
  Atomically updates barrier and checks for gather trigger.

  Returns:
  - `{:ok, :continue}` - More instances pending
  - `{:ok, :gather}` - All instances complete, ready to gather
  - `{:ok, :partial_failure}` - Complete but with failures under threshold
  - `{:error, :threshold_exceeded}` - Too many failures
  """
  @spec complete(barrier() | Ecto.UUID.t(), scatter_key(), term()) ::
          {:ok, :continue | :gather | :partial_failure} | {:error, term()}
  def complete(barrier_or_id, scatter_key, result) do
    barrier_id = get_barrier_id(barrier_or_id)
    key_hash = Key.hash(Key.normalize(scatter_key))
    compressed = Result.compress(result)

    Repo.transaction(fn ->
      # Update result record
      from(r in Result,
        where: r.barrier_id == ^barrier_id and r.scatter_key_hash == ^key_hash
      )
      |> Repo.update_all(
        set: [
          status: :completed,
          result: compressed,
          completed_at: DateTime.utc_now(),
          updated_at: DateTime.utc_now()
        ]
      )

      # Atomically increment completed count and get updated barrier
      {1, [updated]} =
        from(b in Barrier, where: b.id == ^barrier_id, select: b)
        |> Repo.update_all(inc: [completed_count: 1], set: [updated_at: DateTime.utc_now()])

      emit_telemetry(:instance_complete, updated, scatter_key)

      # Check if barrier is complete
      finalize_if_complete(updated)
    end)
  end

  @doc """
  Record failure of a scattered instance.
  """
  @spec fail(barrier() | Ecto.UUID.t(), scatter_key(), term()) ::
          {:ok, :continue | :failed | :partial_failure} | {:error, term()}
  def fail(barrier_or_id, scatter_key, error) do
    barrier_id = get_barrier_id(barrier_or_id)
    key_hash = Key.hash(Key.normalize(scatter_key))

    error_map =
      case error do
        %{message: msg} -> %{"message" => msg, "type" => "error"}
        msg when is_binary(msg) -> %{"message" => msg, "type" => "error"}
        other -> %{"message" => inspect(other), "type" => "error"}
      end

    Repo.transaction(fn ->
      # Update result record
      from(r in Result,
        where: r.barrier_id == ^barrier_id and r.scatter_key_hash == ^key_hash
      )
      |> Repo.update_all(
        set: [
          status: :failed,
          error: error_map,
          completed_at: DateTime.utc_now(),
          updated_at: DateTime.utc_now()
        ]
      )

      # Atomically increment failed count
      {1, [updated]} =
        from(b in Barrier, where: b.id == ^barrier_id, select: b)
        |> Repo.update_all(inc: [failed_count: 1], set: [updated_at: DateTime.utc_now()])

      emit_telemetry(:instance_fail, updated, scatter_key)

      # Check failure threshold
      check_failure_threshold(updated)
    end)
  end

  @doc """
  Gather all results for a completed barrier.
  Returns a map of scatter_key => result.
  """
  @spec gather(barrier() | Ecto.UUID.t()) :: {:ok, map()} | {:error, term()}
  def gather(barrier_or_id) do
    barrier_id = get_barrier_id(barrier_or_id)

    results =
      from(r in Result,
        where: r.barrier_id == ^barrier_id and r.status == :completed,
        select: {r.scatter_key, r.result}
      )
      |> Repo.all()
      |> Enum.map(fn {key, compressed} ->
        {key, Result.decompress(compressed)}
      end)
      |> Map.new()

    {:ok, results}
  end

  @doc """
  Get a barrier by ID.
  """
  @spec get_barrier(Ecto.UUID.t()) :: {:ok, barrier()} | {:error, :not_found}
  def get_barrier(barrier_id) do
    case Repo.get(Barrier, barrier_id) do
      nil -> {:error, :not_found}
      barrier -> {:ok, barrier}
    end
  end

  @doc """
  Get barrier status with counts.
  """
  @spec status(Ecto.UUID.t()) :: {:ok, map()} | {:error, :not_found}
  def status(barrier_id) do
    case Repo.get(Barrier, barrier_id) do
      nil ->
        {:error, :not_found}

      barrier ->
        {:ok,
         %{
           id: barrier.id,
           asset_name: barrier.asset_name,
           status: barrier.status,
           total: barrier.total_count,
           completed: barrier.completed_count,
           failed: barrier.failed_count,
           pending: barrier.total_count - barrier.completed_count - barrier.failed_count,
           progress: Barrier.progress(barrier)
         }}
    end
  end

  @doc """
  Cancel a scatter barrier and all pending instances.
  """
  @spec cancel(barrier() | Ecto.UUID.t()) :: {:ok, barrier()} | {:error, term()}
  def cancel(barrier_or_id) do
    barrier_id = get_barrier_id(barrier_or_id)

    Repo.transaction(fn ->
      # Update barrier status
      {1, [updated]} =
        from(b in Barrier, where: b.id == ^barrier_id, select: b)
        |> Repo.update_all(set: [status: :cancelled, updated_at: DateTime.utc_now()])

      # Cancel pending result records
      from(r in Result,
        where: r.barrier_id == ^barrier_id and r.status in [:pending, :executing]
      )
      |> Repo.update_all(set: [status: :failed, updated_at: DateTime.utc_now()])

      emit_telemetry(:cancel, updated)

      updated
    end)
  end

  @doc """
  List barriers for a run.
  """
  @spec list_barriers(Ecto.UUID.t()) :: [barrier()]
  def list_barriers(run_id) do
    from(b in Barrier, where: b.run_id == ^run_id, order_by: [desc: b.inserted_at])
    |> Repo.all()
  end

  @doc """
  Get pending scatter keys for a barrier (for job enqueueing).
  """
  @spec pending_keys(Ecto.UUID.t()) :: [map()]
  def pending_keys(barrier_id) do
    from(r in Result,
      where: r.barrier_id == ^barrier_id and r.status == :pending,
      select: r.scatter_key,
      order_by: [asc: r.scatter_index]
    )
    |> Repo.all()
  end

  # Private helpers

  defp get_barrier_id(%Barrier{id: id}), do: id
  defp get_barrier_id(id) when is_binary(id), do: id

  defp finalize_if_complete(%Barrier{} = barrier) do
    if Barrier.complete?(barrier) do
      opts = Barrier.get_options(barrier)
      failure_rate = Barrier.failure_rate(barrier)

      cond do
        barrier.failed_count == 0 ->
          update_barrier_status(barrier, :completed)
          emit_telemetry(:complete, barrier)
          :gather

        failure_rate <= opts.failure_threshold ->
          update_barrier_status(barrier, :partial_failure)
          emit_telemetry(:complete, barrier)
          :partial_failure

        true ->
          update_barrier_status(barrier, :failed)
          emit_telemetry(:failed, barrier)
          {:error, :threshold_exceeded}
      end
    else
      :continue
    end
  end

  defp check_failure_threshold(%Barrier{} = barrier) do
    opts = Barrier.get_options(barrier)
    failure_rate = Barrier.failure_rate(barrier)

    cond do
      # Check if we've exceeded threshold (early termination for all_or_nothing)
      opts.failure_mode == :all_or_nothing and barrier.failed_count > 0 ->
        update_barrier_status(barrier, :failed)
        emit_telemetry(:failed, barrier)
        {:error, :threshold_exceeded}

      failure_rate > opts.failure_threshold ->
        update_barrier_status(barrier, :failed)
        emit_telemetry(:failed, barrier)
        {:error, :threshold_exceeded}

      Barrier.complete?(barrier) ->
        finalize_if_complete(barrier)

      true ->
        :continue
    end
  end

  defp update_barrier_status(barrier, status) do
    from(b in Barrier, where: b.id == ^barrier.id)
    |> Repo.update_all(set: [status: status, updated_at: DateTime.utc_now()])
  end

  defp emit_telemetry(event, barrier, scatter_key \\ nil) do
    meta = %{
      barrier_id: barrier.id,
      asset: barrier.asset_name,
      run_id: barrier.run_id
    }

    meta = if scatter_key, do: Map.put(meta, :scatter_key, scatter_key), else: meta

    measurements =
      case event do
        :start -> %{count: barrier.total_count}
        :complete -> %{completed: barrier.completed_count, failed: barrier.failed_count}
        _ -> %{}
      end

    :telemetry.execute([:flowstone, :scatter, event], measurements, meta)
  end
end
