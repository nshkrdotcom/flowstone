# FlowStone v0.5.0 - Backfill Example
# ====================================
#
# Demonstrates backfilling data across multiple partitions.
#
# Run: mix run examples/04_backfill.exs

defmodule BackfillPipeline do
  use FlowStone.Pipeline

  asset :metrics do
    execute fn ctx, _ ->
      # Simulate generating metrics for a date
      date = ctx.partition
      {:ok, %{date: date, value: :rand.uniform(100), generated_at: DateTime.utc_now()}}
    end
  end

  asset :aggregated do
    depends_on([:metrics])

    execute fn ctx, %{metrics: m} ->
      {:ok, %{date: ctx.partition, processed_value: m.value * 2}}
    end
  end
end

IO.puts("BackfillPipeline - Backfill Example")
IO.puts("====================================\n")

# Generate a range of dates to backfill
partitions = [:day1, :day2, :day3, :day4, :day5]

IO.puts("Backfilling #{length(partitions)} partitions...")
{:ok, stats} = FlowStone.backfill(BackfillPipeline, :aggregated, partitions: partitions)

IO.puts("Backfill complete!")
IO.puts("  Succeeded: #{stats.succeeded}")
IO.puts("  Failed:    #{stats.failed}")
IO.puts("  Skipped:   #{stats.skipped}")

# Show results for each partition
IO.puts("\nResults by partition:")

for partition <- partitions do
  {:ok, result} = FlowStone.get(BackfillPipeline, :aggregated, partition: partition)
  IO.puts("  #{partition}: #{inspect(result)}")
end

# Run another backfill - should skip already-completed partitions
IO.puts("\nRunning backfill again (should skip all)...")
{:ok, stats2} = FlowStone.backfill(BackfillPipeline, :aggregated, partitions: partitions)
IO.puts("  Succeeded: #{stats2.succeeded}")
IO.puts("  Failed:    #{stats2.failed}")
IO.puts("  Skipped:   #{stats2.skipped}")

# Force re-run with force: true
IO.puts("\nRunning backfill with force: true...")

{:ok, stats3} =
  FlowStone.backfill(BackfillPipeline, :aggregated, partitions: [:day1], force: true)

IO.puts("  Succeeded: #{stats3.succeeded}")

IO.puts("\nDone!")
