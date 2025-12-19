# ItemBatcher Example - Batching Scatter Items
#
# This example demonstrates FlowStone's ItemBatcher feature for grouping
# scatter items into batches for more efficient execution patterns.

Logger.configure(level: :info)

defmodule ItemBatcherExample do
  @moduledoc """
  Example pipeline demonstrating ItemBatcher for batch scatter execution.

  ItemBatcher groups scatter items into batches, similar to AWS Step Functions
  ItemBatcher. Each batch becomes a single scatter instance with shared
  batch context.
  """

  use FlowStone.Pipeline

  # Source data - simulates upstream dependency that provides items to scatter
  asset :source_items do
    execute fn _ctx, _deps ->
      # Generate 10 items to be batched
      items =
        Enum.map(1..10, fn i ->
          %{id: i, data: "item_#{i}", size: i * 100}
        end)

      {:ok, items}
    end
  end

  # Batched scatter asset - groups items into batches of 3
  asset :batched_processor do
    depends_on([:source_items])

    scatter(fn %{source_items: items} ->
      Enum.map(items, &%{item_id: &1.id, data: &1.data})
    end)

    batch_options do
      max_items_per_batch(3)

      batch_input(fn deps ->
        %{
          total_items: length(deps.source_items),
          processing_time: DateTime.utc_now()
        }
      end)

      on_item_error(:fail_batch)
    end

    scatter_options do
      max_concurrent(5)
      failure_threshold(0.5)
    end

    execute fn ctx, _deps ->
      # ctx has batch context:
      # - ctx.batch_items: list of items in this batch
      # - ctx.batch_input: shared batch context
      # - ctx.batch_index: zero-based batch index
      # - ctx.batch_count: total number of batches
      # - ctx.scatter_key: batch metadata

      batch_sum =
        Enum.sum(
          Enum.map(ctx.batch_items, fn item ->
            item["item_id"]
          end)
        )

      {:ok,
       %{
         batch_index: ctx.batch_index,
         item_count: length(ctx.batch_items),
         item_ids: Enum.map(ctx.batch_items, & &1["item_id"]),
         batch_sum: batch_sum,
         total_items: ctx.batch_input["total_items"]
       }}
    end

    gather(fn batch_results ->
      # Gather receives batch results (not per-item results)
      total_processed =
        batch_results
        |> Map.values()
        |> Enum.map(& &1.item_count)
        |> Enum.sum()

      %{
        batches_completed: map_size(batch_results),
        total_items_processed: total_processed,
        batch_sums: Enum.map(Map.values(batch_results), & &1.batch_sum)
      }
    end)
  end
end

IO.puts(String.duplicate("=", 60))
IO.puts("FlowStone ItemBatcher Example")
IO.puts(String.duplicate("=", 60))

defmodule ItemBatcherExample.Helper do
  def ensure_started(module, name) do
    case Process.whereis(name) do
      nil ->
        {:ok, _pid} = module.start_link(name: name)
        name

      _pid ->
        name
    end
  end
end

# Start services
registry = ItemBatcherExample.Helper.ensure_started(FlowStone.Registry, FlowStone.Registry)
memory = ItemBatcherExample.Helper.ensure_started(FlowStone.IO.Memory, FlowStone.IO.Memory)

# Register pipeline
FlowStone.register(ItemBatcherExample, registry: registry)

# Get assets
assets = ItemBatcherExample.__flowstone_assets__()
source_asset = Enum.find(assets, &(&1.name == :source_items))
batched_asset = Enum.find(assets, &(&1.name == :batched_processor))

run_id = Ecto.UUID.generate()
io_opts = [config: %{agent: memory}]

IO.puts("\n1. Materializing source items...")

{:ok, source_data} =
  FlowStone.Materializer.execute(
    source_asset,
    %FlowStone.Context{asset: :source_items, run_id: run_id},
    %{}
  )

:ok = FlowStone.IO.store(:source_items, source_data, nil, io_opts)
IO.puts("   Generated #{length(source_data)} items")

IO.puts("\n2. Creating batched scatter...")

# Evaluate scatter function
scatter_keys = batched_asset.scatter_fn.(%{source_items: source_data})
IO.puts("   #{length(scatter_keys)} scatter keys generated")

# Get batch options from asset
batch_opts = batched_asset.batch_options || %{}
batch_options = FlowStone.Scatter.BatchOptions.new(Map.to_list(batch_opts))

# Evaluate batch_input
batch_input_fn = Map.get(batch_opts, :batch_input)

batch_input =
  if is_function(batch_input_fn, 1) do
    batch_input_fn.(%{source_items: source_data})
  else
    nil
  end

IO.puts("   Batch options: max_items_per_batch=#{batch_options.max_items_per_batch}")
IO.puts("   Batch input: #{inspect(batch_input)}")

# Create barrier with batching
{:ok, barrier} =
  FlowStone.Scatter.create_barrier(
    run_id: run_id,
    asset_name: :batched_processor,
    scatter_keys: scatter_keys,
    batch_options: batch_options,
    batch_input: batch_input
  )

IO.puts("\n3. Barrier created with batching:")
IO.puts("   Barrier ID: #{barrier.id}")
IO.puts("   Batching enabled: #{barrier.batching_enabled}")
IO.puts("   Batch count: #{barrier.batch_count}")
IO.puts("   Total count (batches): #{barrier.total_count}")

# Get batch results to see the batches
import Ecto.Query

batch_results =
  FlowStone.Repo.all(
    from(r in FlowStone.Scatter.Result,
      where: r.barrier_id == ^barrier.id,
      order_by: [asc: r.batch_index]
    )
  )

IO.puts("\n4. Batch details:")

Enum.each(batch_results, fn result ->
  item_ids = Enum.map(result.batch_items || [], & &1["item_id"])

  IO.puts(
    "   Batch #{result.batch_index}: #{length(result.batch_items || [])} items - IDs: #{inspect(item_ids, charlists: :as_lists)}"
  )
end)

IO.puts("\n5. Simulating batch execution...")

# Execute each batch (normally done by ScatterBatchWorker)
Enum.each(batch_results, fn result ->
  # Build context with batch fields
  context = %FlowStone.Context{
    asset: :batched_processor,
    run_id: run_id,
    scatter_key: result.scatter_key,
    batch_index: result.batch_index,
    batch_count: barrier.batch_count,
    batch_items: result.batch_items,
    batch_input: result.batch_input
  }

  # Execute
  {:ok, batch_result} = FlowStone.Materializer.execute(batched_asset, context, %{})

  # Record completion
  {:ok, _status} = FlowStone.Scatter.complete(barrier.id, result.scatter_key, batch_result)

  IO.puts(
    "   Batch #{result.batch_index} completed: #{inspect(batch_result, charlists: :as_lists)}"
  )
end)

# Check final status
{:ok, final_status} = FlowStone.Scatter.status(barrier.id)
IO.puts("\n6. Final barrier status:")
IO.puts("   Status: #{final_status.status}")
IO.puts("   Completed: #{final_status.completed}/#{final_status.total}")
IO.puts("   Progress: #{Float.round(final_status.progress, 1)}%")

# Gather results
{:ok, gathered} = FlowStone.Scatter.gather(barrier.id)
IO.puts("\n7. Gathered batch results:")
IO.puts("   Number of batch results: #{map_size(gathered)}")

# Apply gather function
if batched_asset.gather_fn do
  final_result = batched_asset.gather_fn.(gathered)
  IO.puts("   Final aggregated result: #{inspect(final_result)}")
end

IO.puts("\n" <> String.duplicate("=", 60))
IO.puts("ItemBatcher Example Complete!")
IO.puts(String.duplicate("=", 60))
