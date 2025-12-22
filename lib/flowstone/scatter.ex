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
  alias FlowStone.{Error, Partition, Repo}
  alias FlowStone.Scatter.{Barrier, Batcher, BatchOptions, ItemReader, Key, Options, Result}
  alias FlowStone.Workers.{ItemReaderWorker, ScatterWorker}

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
  - `:batch_options` - BatchOptions struct (optional, enables batching)
  - `:batch_input` - Shared batch input (optional, evaluated value)
  - `:metadata` - Additional metadata (optional)
  """
  @spec create_barrier(keyword()) :: {:ok, barrier()} | {:error, term()}
  def create_barrier(opts) do
    scatter_keys = Keyword.fetch!(opts, :scatter_keys)
    batch_opts = Keyword.get(opts, :batch_options)

    if batch_opts do
      create_batched_barrier(scatter_keys, batch_opts, opts)
    else
      create_standard_barrier(scatter_keys, opts)
    end
  end

  defp create_standard_barrier(scatter_keys, opts) do
    with {:ok, barrier} <- start_barrier(Keyword.put(opts, :emit_start, false)),
         {:ok, _count} <- insert_results(barrier.id, scatter_keys) do
      updated = Repo.get!(Barrier, barrier.id)
      emit_telemetry(:start, updated)
      {:ok, updated}
    end
  end

  defp create_batched_barrier(scatter_keys, batch_opts, opts) do
    batch_opts = normalize_batch_options(batch_opts)
    batches = Batcher.batch(scatter_keys, batch_opts)
    batch_count = length(batches)
    batch_input = Keyword.get(opts, :batch_input)

    barrier_opts =
      opts
      |> Keyword.put(:emit_start, false)
      |> Keyword.put(:batching_enabled, true)
      |> Keyword.put(:batch_count, batch_count)
      |> Keyword.put(:batch_options_map, BatchOptions.to_map(batch_opts))

    with {:ok, barrier} <- start_barrier(barrier_opts),
         {:ok, _count} <- insert_batch_results(barrier.id, batches, batch_input) do
      updated = Repo.get!(Barrier, barrier.id)
      emit_telemetry(:start, updated)
      emit_batch_telemetry(:batch_create, updated, batch_count)
      {:ok, updated}
    end
  end

  defp normalize_batch_options(%BatchOptions{} = opts), do: opts
  defp normalize_batch_options(nil), do: BatchOptions.new()
  defp normalize_batch_options(opts) when is_list(opts), do: BatchOptions.new(opts)
  defp normalize_batch_options(opts) when is_map(opts), do: BatchOptions.new(Map.to_list(opts))

  @doc """
  Create a barrier with zero items for streaming readers.
  """
  @spec start_barrier(keyword()) :: {:ok, barrier()} | {:error, term()}
  def start_barrier(opts) do
    run_id = Keyword.fetch!(opts, :run_id)
    asset_name = Keyword.fetch!(opts, :asset_name)
    scatter_opts = normalize_options(Keyword.get(opts, :options) || %Options{})

    partition =
      case Keyword.get(opts, :partition) do
        nil -> nil
        p -> Partition.serialize(p)
      end

    attrs = %{
      run_id: run_id,
      asset_name: to_string(asset_name),
      scatter_source_asset: opts[:scatter_source_asset] && to_string(opts[:scatter_source_asset]),
      partition: partition,
      total_count: 0,
      scatter_keys: [],
      options: Options.to_map(scatter_opts),
      metadata: Keyword.get(opts, :metadata, %{}),
      status: :executing,
      mode: Keyword.get(opts, :mode, scatter_opts.mode),
      reader_checkpoint: Keyword.get(opts, :reader_checkpoint),
      parent_barrier_id: Keyword.get(opts, :parent_barrier_id),
      batch_index: Keyword.get(opts, :batch_index),
      # Batch fields
      batching_enabled: Keyword.get(opts, :batching_enabled, false),
      batch_count: Keyword.get(opts, :batch_count),
      batch_options: Keyword.get(opts, :batch_options_map)
    }

    emit_start? = Keyword.get(opts, :emit_start, true)

    Repo.transaction(fn ->
      barrier =
        %Barrier{}
        |> Barrier.changeset(attrs)
        |> Repo.insert!()

      if emit_start? do
        emit_telemetry(:start, barrier)
      end

      barrier
    end)
  end

  @doc """
  Insert scatter results for a barrier and increment total_count.
  """
  @spec insert_results(barrier() | Ecto.UUID.t(), [scatter_key()]) ::
          {:ok, non_neg_integer()} | {:error, term()}
  def insert_results(barrier_or_id, scatter_keys) do
    barrier_id = get_barrier_id(barrier_or_id)
    normalized = Enum.map(scatter_keys, &Key.normalize/1)

    keys_with_hash =
      normalized
      |> Enum.map(&{&1, Key.hash(&1)})
      |> Enum.reduce({MapSet.new(), []}, fn {key, hash}, {seen, acc} ->
        if MapSet.member?(seen, hash) do
          {seen, acc}
        else
          {MapSet.put(seen, hash), [{key, hash} | acc]}
        end
      end)
      |> elem(1)
      |> Enum.reverse()

    Repo.transaction(fn ->
      barrier = Repo.get!(Barrier, barrier_id, lock: "FOR UPDATE")
      start_index = barrier.total_count
      now = DateTime.utc_now()

      result_records =
        keys_with_hash
        |> Enum.with_index(start_index)
        |> Enum.map(fn {{key, hash}, index} ->
          %{
            id: Ecto.UUID.generate(),
            barrier_id: barrier_id,
            scatter_key_hash: hash,
            scatter_key: key,
            scatter_index: index,
            status: :pending,
            inserted_at: now,
            updated_at: now
          }
        end)

      {inserted_count, _} =
        Repo.insert_all(Result, result_records,
          on_conflict: :nothing,
          conflict_target: [:barrier_id, :scatter_key_hash]
        )

      from(b in Barrier, where: b.id == ^barrier_id)
      |> Repo.update_all(inc: [total_count: inserted_count], set: [updated_at: now])

      inserted_count
    end)
  end

  @doc """
  Insert batch result records for a barrier.

  Each batch becomes a single result record with batch metadata.
  """
  @spec insert_batch_results(Ecto.UUID.t(), [[map()]], map() | nil) ::
          {:ok, non_neg_integer()} | {:error, term()}
  def insert_batch_results(barrier_id, batches, batch_input) do
    Repo.transaction(fn ->
      # Lock the barrier to ensure consistent updates
      _barrier = Repo.get!(Barrier, barrier_id, lock: "FOR UPDATE")
      now = DateTime.utc_now()
      normalized_input = normalize_batch_input_for_storage(batch_input)

      result_records =
        batches
        |> Enum.with_index()
        |> Enum.map(fn {batch_items, batch_index} ->
          batch_key = Batcher.batch_scatter_key(batch_index, length(batch_items))
          normalized_items = Enum.map(batch_items, &Key.normalize/1)

          %{
            id: Ecto.UUID.generate(),
            barrier_id: barrier_id,
            scatter_key_hash: Key.hash(batch_key),
            scatter_key: batch_key,
            scatter_index: batch_index,
            status: :pending,
            batch_index: batch_index,
            batch_items: normalized_items,
            batch_input: normalized_input,
            inserted_at: now,
            updated_at: now
          }
        end)

      {inserted_count, _} =
        Repo.insert_all(Result, result_records,
          on_conflict: :nothing,
          conflict_target: [:barrier_id, :scatter_key_hash]
        )

      from(b in Barrier, where: b.id == ^barrier_id)
      |> Repo.update_all(inc: [total_count: inserted_count], set: [updated_at: now])

      inserted_count
    end)
  end

  defp normalize_batch_input_for_storage(nil), do: nil

  defp normalize_batch_input_for_storage(input) when is_map(input) do
    input
    |> Enum.map(fn
      {k, v} when is_atom(k) -> {Atom.to_string(k), v}
      kv -> kv
    end)
    |> Map.new()
  end

  @doc """
  Run an ItemReader in inline mode and stream results into a single barrier.
  """
  @spec run_inline_reader(FlowStone.Asset.t(), map(), keyword()) ::
          {:ok, barrier()} | {:error, Error.t()}
  def run_inline_reader(asset, deps, opts) do
    run_reader(:inline, asset, deps, opts)
  end

  @doc """
  Run an ItemReader in distributed mode, creating sub-barriers per batch.
  """
  @spec run_distributed_reader(FlowStone.Asset.t(), map(), keyword()) ::
          {:ok, barrier()} | {:error, Error.t()}
  def run_distributed_reader(asset, deps, opts) do
    run_reader(:distributed, asset, deps, opts)
  end

  @doc """
  Start a distributed ItemReader run using a worker when Oban is running.
  """
  @spec start_distributed_reader(FlowStone.Asset.t(), map(), keyword()) ::
          {:ok, barrier()} | {:error, Error.t()}
  def start_distributed_reader(asset, deps, opts) do
    run_id = Keyword.fetch!(opts, :run_id)
    partition = Keyword.get(opts, :partition)
    scatter_opts = scatter_options_from_asset(asset, Keyword.put(opts, :mode, :distributed))

    with :ok <- ensure_item_reader_asset(asset, :distributed),
         {:ok, barrier} <-
           start_barrier(
             run_id: run_id,
             asset_name: asset.name,
             partition: partition,
             options: scatter_opts,
             mode: :distributed
           ) do
      if oban_running?() and Keyword.get(opts, :enqueue_reader, true) do
        args = %{
          "barrier_id" => barrier.id,
          "run_id" => run_id,
          "asset_name" => to_string(asset.name),
          "partition" => Partition.serialize(partition)
        }

        ItemReaderWorker.new(args, queue: scatter_opts.queue, priority: scatter_opts.priority)
        |> Oban.insert()

        {:ok, barrier}
      else
        run_distributed_reader(asset, deps, Keyword.put(opts, :barrier_id, barrier.id))
      end
    end
  end

  defp run_reader(mode, asset, deps, opts) do
    run_id = Keyword.fetch!(opts, :run_id)
    partition = Keyword.get(opts, :partition)

    with :ok <- ensure_item_reader_asset(asset, mode),
         scatter_opts <- scatter_options_from_asset(asset, Keyword.put(opts, :mode, mode)),
         {:ok, barrier} <-
           get_or_start_barrier(asset, run_id, partition, scatter_opts, mode, opts),
         {:ok, reader_mod, reader_state, reader_config} <-
           init_reader(asset, deps, barrier, mode, opts) do
      case mode do
        :inline ->
          stream_inline(
            reader_mod,
            reader_state,
            reader_config,
            asset,
            deps,
            barrier,
            scatter_opts,
            opts
          )

        :distributed ->
          stream_distributed(
            reader_mod,
            reader_state,
            reader_config,
            asset,
            deps,
            barrier,
            scatter_opts,
            opts
          )
      end
    end
  end

  defp ensure_item_reader_asset(asset, mode) do
    cond do
      is_nil(asset.scatter_source) ->
        {:error, Error.validation_error(asset.name, "scatter_from is required for #{mode} mode")}

      not is_function(asset.item_selector_fn, 2) ->
        {:error, Error.validation_error(asset.name, "item_selector/2 is required")}

      true ->
        :ok
    end
  end

  defp get_or_start_barrier(asset, run_id, partition, scatter_opts, mode, opts) do
    case Keyword.get(opts, :barrier_id) do
      nil ->
        start_barrier(
          run_id: run_id,
          asset_name: asset.name,
          partition: partition,
          options: scatter_opts,
          mode: mode
        )

      barrier_id ->
        case Repo.get(Barrier, barrier_id) do
          nil ->
            {:error,
             Error.validation_error(asset.name, "scatter barrier not found: #{barrier_id}")}

          barrier ->
            {:ok, barrier}
        end
    end
  end

  defp init_reader(asset, deps, barrier, mode, opts) do
    reader_mod = ItemReader.resolve(asset.scatter_source)

    config =
      resolve_config(asset.scatter_source_config || %{}, deps,
        skip_keys: [:init, :read, :count, :checkpoint, :restore, :close, :row_selector]
      )

    meta = %{
      asset: asset.name,
      run_id: barrier.run_id,
      mode: mode,
      source: asset.scatter_source
    }

    start_time = System.monotonic_time(:millisecond)

    case reader_mod.init(config, deps) do
      {:ok, state} ->
        duration = System.monotonic_time(:millisecond) - start_time
        emit_item_reader(:init, %{duration: duration}, meta)
        state = maybe_restore(reader_mod, state, barrier.reader_checkpoint)
        {:ok, reader_mod, state, config}

      {:error, reason} ->
        duration = System.monotonic_time(:millisecond) - start_time
        emit_item_reader(:error, %{duration: duration}, Map.put(meta, :error, reason))
        update_barrier_status(barrier, :failed)
        {:error, reader_error(asset, opts, reason)}
    end
  end

  defp stream_inline(
         reader_mod,
         state,
         config,
         %{item_selector_fn: item_selector} = asset,
         deps,
         barrier,
         scatter_opts,
         opts
       )
       when is_function(item_selector, 2) do
    batch_size = resolve_batch_size(scatter_opts, config, reader_mod)
    max_batches = scatter_opts.max_batches
    max_items = config[:max_items]

    ctx = %{
      reader_mod: reader_mod,
      asset: asset,
      deps: deps,
      barrier: barrier,
      scatter_opts: scatter_opts,
      opts: opts,
      item_selector: item_selector,
      batch_size: batch_size,
      max_batches: max_batches,
      max_items: max_items
    }

    result = read_loop(ctx, state, 0, 0)

    case result do
      {:ok, final_state, :complete} ->
        reader_mod.close(final_state)
        emit_item_reader(:complete, %{}, %{asset: asset.name, run_id: barrier.run_id})
        {:ok, Repo.get!(Barrier, barrier.id)}

      {:ok, final_state, :paused} ->
        reader_mod.close(final_state)
        {:ok, Repo.get!(Barrier, barrier.id)}

      {:error, %Error{} = err} ->
        {:error, err}
    end
  end

  defp stream_inline(
         _reader_mod,
         _state,
         _config,
         asset,
         _deps,
         _barrier,
         _scatter_opts,
         _opts
       ) do
    {:error, Error.validation_error(asset.name, "item_selector/2 is required")}
  end

  defp read_loop(ctx, state, batch_index, total_read) do
    cond do
      batch_limit_reached?(ctx, batch_index) ->
        {:ok, state, :paused}

      item_limit_reached?(ctx, total_read) ->
        {:ok, state, :complete}

      true ->
        read_inline_batch(ctx, state, batch_index, total_read)
    end
  end

  defp read_inline_batch(ctx, state, batch_index, total_read) do
    start_time = System.monotonic_time(:millisecond)

    case safe_reader_read(ctx.reader_mod, state, ctx.batch_size) do
      {:ok, items, next_state} ->
        process_inline_items(ctx, state, next_state, items, batch_index, total_read, start_time)

      {:error, reason} ->
        handle_reader_error(ctx, state, reason)
    end
  end

  defp process_inline_items(ctx, state, next_state, items, batch_index, total_read, start_time) do
    {items, reached_limit?} = apply_max_items(items, total_read, ctx.max_items)
    new_total = total_read + length(items)
    duration = System.monotonic_time(:millisecond) - start_time

    emit_item_reader(:read, %{duration: duration, count: length(items)}, %{
      asset: ctx.asset.name,
      run_id: ctx.barrier.run_id,
      batch_index: batch_index
    })

    with {:ok, scatter_keys} <- safe_select(ctx.item_selector, items, ctx.deps),
         {:ok, _count} <- insert_results(ctx.barrier.id, scatter_keys) do
      maybe_enqueue(ctx.barrier, ctx.asset, scatter_keys, ctx.scatter_opts, ctx.opts)

      checkpoint = ctx.reader_mod.checkpoint(state_for_checkpoint(state, next_state))
      update_reader_checkpoint(ctx.barrier.id, checkpoint)

      if done_reading?(items, reached_limit?, next_state) do
        {:ok, state_for_checkpoint(state, next_state), :complete}
      else
        read_loop(ctx, next_state, batch_index + 1, new_total)
      end
    else
      {:error, reason} ->
        handle_reader_error(ctx, state, reason)
    end
  end

  defp stream_distributed(
         reader_mod,
         state,
         config,
         %{item_selector_fn: item_selector} = asset,
         deps,
         parent_barrier,
         scatter_opts,
         opts
       )
       when is_function(item_selector, 2) do
    batch_size = resolve_batch_size(scatter_opts, config, reader_mod)
    max_batches = scatter_opts.max_batches
    max_items = config[:max_items]

    ctx = %{
      reader_mod: reader_mod,
      asset: asset,
      deps: deps,
      barrier: parent_barrier,
      scatter_opts: scatter_opts,
      opts: opts,
      item_selector: item_selector,
      batch_size: batch_size,
      max_batches: max_batches,
      max_items: max_items
    }

    result = distributed_loop(ctx, state, 0, 0)

    case result do
      {:ok, final_state, :complete} ->
        reader_mod.close(final_state)
        emit_item_reader(:complete, %{}, %{asset: asset.name, run_id: parent_barrier.run_id})
        {:ok, Repo.get!(Barrier, parent_barrier.id)}

      {:ok, final_state, :paused} ->
        reader_mod.close(final_state)
        {:ok, Repo.get!(Barrier, parent_barrier.id)}

      {:error, %Error{} = err} ->
        {:error, err}
    end
  end

  defp stream_distributed(
         _reader_mod,
         _state,
         _config,
         asset,
         _deps,
         _parent,
         _scatter_opts,
         _opts
       ) do
    {:error, Error.validation_error(asset.name, "item_selector/2 is required")}
  end

  defp distributed_loop(ctx, state, batch_index, total_read) do
    cond do
      batch_limit_reached?(ctx, batch_index) ->
        {:ok, state, :paused}

      item_limit_reached?(ctx, total_read) ->
        {:ok, state, :complete}

      true ->
        read_distributed_batch(ctx, state, batch_index, total_read)
    end
  end

  defp read_distributed_batch(ctx, state, batch_index, total_read) do
    start_time = System.monotonic_time(:millisecond)

    case safe_reader_read(ctx.reader_mod, state, ctx.batch_size) do
      {:ok, items, next_state} ->
        process_distributed_items(
          ctx,
          state,
          next_state,
          items,
          batch_index,
          total_read,
          start_time
        )

      {:error, reason} ->
        handle_reader_error(ctx, state, reason)
    end
  end

  defp process_distributed_items(
         ctx,
         state,
         next_state,
         items,
         batch_index,
         total_read,
         start_time
       ) do
    {items, reached_limit?} = apply_max_items(items, total_read, ctx.max_items)
    new_total = total_read + length(items)
    duration = System.monotonic_time(:millisecond) - start_time

    emit_item_reader(:read, %{duration: duration, count: length(items)}, %{
      asset: ctx.asset.name,
      run_id: ctx.barrier.run_id,
      batch_index: batch_index
    })

    with {:ok, scatter_keys} <- safe_select(ctx.item_selector, items, ctx.deps),
         :ok <- handle_distributed_batch(ctx, scatter_keys, batch_index) do
      checkpoint = ctx.reader_mod.checkpoint(state_for_checkpoint(state, next_state))
      update_reader_checkpoint(ctx.barrier.id, checkpoint)

      if done_reading?(items, reached_limit?, next_state) do
        {:ok, state_for_checkpoint(state, next_state), :complete}
      else
        distributed_loop(ctx, next_state, batch_index + 1, new_total)
      end
    else
      {:error, reason} ->
        handle_reader_error(ctx, state, reason)
    end
  end

  defp handle_distributed_batch(_ctx, [], _batch_index), do: :ok

  defp handle_distributed_batch(ctx, scatter_keys, batch_index) do
    emit_batch_event(:batch_start, ctx.barrier, batch_index, length(scatter_keys))

    child_opts = %{ctx.scatter_opts | mode: :inline}

    case create_barrier(
           run_id: ctx.barrier.run_id,
           asset_name: ctx.asset.name,
           partition: Partition.deserialize(ctx.barrier.partition),
           scatter_keys: scatter_keys,
           options: child_opts,
           parent_barrier_id: ctx.barrier.id,
           batch_index: batch_index
         ) do
      {:ok, child_barrier} ->
        increment_total_count(ctx.barrier.id, child_barrier.total_count)

        maybe_enqueue(child_barrier, ctx.asset, scatter_keys, ctx.scatter_opts, ctx.opts)
        emit_batch_event(:batch_complete, ctx.barrier, batch_index, child_barrier.total_count)
        :ok

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp batch_limit_reached?(%{max_batches: nil}, _batch_index), do: false
  defp batch_limit_reached?(%{max_batches: max}, batch_index), do: batch_index >= max

  defp item_limit_reached?(%{max_items: nil}, _total_read), do: false
  defp item_limit_reached?(%{max_items: max}, total_read), do: total_read >= max

  defp done_reading?(items, reached_limit?, next_state) do
    reached_limit? or next_state == :halt or items == []
  end

  defp handle_reader_error(ctx, state, reason) do
    update_barrier_status(ctx.barrier, :failed)
    ctx.reader_mod.close(state)

    emit_item_reader(:error, %{}, %{
      asset: ctx.asset.name,
      run_id: ctx.barrier.run_id,
      error: reason
    })

    {:error, reader_error(ctx.asset, ctx.opts, reason)}
  end

  defp resolve_batch_size(scatter_opts, config, _reader_mod) do
    case {scatter_opts.batch_size, config[:reader_batch_size]} do
      {nil, nil} -> 1000
      {nil, size} -> size
      {size, nil} -> size
      {size, cap} -> min(size, cap)
    end
  end

  defp apply_max_items(items, _total_read, nil), do: {items, false}

  defp apply_max_items(items, total_read, max_items) do
    remaining = max_items - total_read

    cond do
      remaining <= 0 -> {[], true}
      length(items) > remaining -> {Enum.take(items, remaining), true}
      true -> {items, false}
    end
  end

  defp state_for_checkpoint(state, :halt), do: state
  defp state_for_checkpoint(_state, next_state), do: next_state

  defp maybe_restore(_reader_mod, state, nil), do: state

  defp maybe_restore(reader_mod, state, checkpoint) when is_map(checkpoint) do
    reader_mod.restore(state, checkpoint)
  end

  defp update_reader_checkpoint(barrier_id, checkpoint) do
    from(b in Barrier, where: b.id == ^barrier_id)
    |> Repo.update_all(set: [reader_checkpoint: checkpoint, updated_at: DateTime.utc_now()])

    :ok
  end

  defp increment_total_count(barrier_id, count) do
    from(b in Barrier, where: b.id == ^barrier_id)
    |> Repo.update_all(inc: [total_count: count], set: [updated_at: DateTime.utc_now()])
  end

  defp scatter_options_from_asset(asset, opts) do
    base = normalize_options(Map.get(asset, :scatter_options) || %Options{})
    overrides = opts |> Enum.into(%{}) |> Map.take(Map.keys(Map.from_struct(base)))
    struct(base, overrides)
  end

  defp normalize_options(%Options{} = opts), do: opts
  defp normalize_options(nil), do: Options.new()
  defp normalize_options(opts) when is_list(opts), do: Options.new(opts)
  defp normalize_options(opts) when is_map(opts), do: Options.new(Map.to_list(opts))

  defp resolve_config(config, deps, opts) do
    skip_keys = Keyword.get(opts, :skip_keys, [])

    Enum.reduce(config, %{}, fn {key, value}, acc ->
      Map.put(acc, key, resolve_value(key, value, deps, skip_keys))
    end)
  end

  defp resolve_value(key, value, deps, skip_keys) when is_function(value) do
    if key in skip_keys do
      value
    else
      resolve_function_value(value, deps)
    end
  end

  defp resolve_value(_key, value, _deps, _skip_keys), do: value

  defp resolve_function_value(value, deps) when is_function(value, 1), do: value.(deps)
  defp resolve_function_value(value, _deps) when is_function(value, 0), do: value.()
  defp resolve_function_value(value, _deps), do: value

  defp safe_reader_read(reader_mod, state, batch_size) do
    reader_mod.read(state, batch_size)
  rescue
    exception -> {:error, exception}
  catch
    :exit, reason -> {:error, reason}
  end

  defp safe_select(item_selector, items, deps) do
    keys = Enum.map(items, &item_selector.(&1, deps))

    case Enum.find(keys, fn key -> not is_map(key) end) do
      nil -> {:ok, keys}
      invalid -> {:error, {:invalid_scatter_key, invalid}}
    end
  rescue
    exception -> {:error, exception}
  catch
    :exit, reason -> {:error, reason}
  end

  defp maybe_enqueue(barrier, asset, scatter_keys, scatter_opts, opts) do
    cond do
      Keyword.get(opts, :enqueue, true) == false -> :ok
      not oban_running?() -> :ok
      true -> enqueue_scatter_jobs(barrier, asset, scatter_keys, scatter_opts)
    end
  end

  defp enqueue_scatter_jobs(barrier, asset, scatter_keys, scatter_opts) do
    Enum.each(scatter_keys, fn scatter_key ->
      args = %{
        "barrier_id" => barrier.id,
        "scatter_key" => scatter_key,
        "asset_name" => to_string(asset.name),
        "run_id" => barrier.run_id
      }

      ScatterWorker.new(args, queue: scatter_opts.queue, priority: scatter_opts.priority)
      |> Oban.insert()
    end)

    :ok
  end

  defp oban_running? do
    Process.whereis(Oban.Registry) != nil and Process.whereis(Oban.Config) != nil
  end

  defp reader_error(asset, opts, reason) do
    partition = Keyword.get(opts, :partition)
    Error.execution_error(asset.name, partition, Error.wrap_reason(reason), [])
  end

  defp emit_item_reader(event, measurements, meta) do
    :telemetry.execute([:flowstone, :item_reader, event], measurements, meta)
  end

  defp emit_batch_event(event, parent_barrier, batch_index, count) do
    :telemetry.execute(
      [:flowstone, :scatter, event],
      %{count: count},
      %{
        parent_barrier_id: parent_barrier.id,
        asset: parent_barrier.asset_name,
        run_id: parent_barrier.run_id,
        batch_index: batch_index
      }
    )
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

  defp emit_batch_telemetry(event, barrier, batch_count) do
    :telemetry.execute(
      [:flowstone, :scatter, event],
      %{batch_count: batch_count},
      %{
        barrier_id: barrier.id,
        asset: barrier.asset_name,
        run_id: barrier.run_id
      }
    )
  end
end
