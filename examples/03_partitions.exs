# FlowStone v0.5.0 - Partitions Example
# ======================================
#
# Demonstrates using partitions for date-based or segment-based processing.
#
# Run: mix run examples/03_partitions.exs

defmodule DailyPipeline do
  use FlowStone.Pipeline

  # Asset that processes data for a specific partition (date)
  asset :daily_data do
    execute fn ctx, _ ->
      date = ctx.partition
      {:ok, "Data generated for #{date}"}
    end
  end

  # Asset that depends on daily_data
  asset :daily_summary do
    depends_on([:daily_data])

    execute fn ctx, %{daily_data: data} ->
      {:ok, "Summary for #{ctx.partition}: #{data}"}
    end
  end
end

IO.puts("DailyPipeline - Partitions Example")
IO.puts("===================================\n")

# Run for different dates
dates = [~D[2025-01-15], ~D[2025-01-16], ~D[2025-01-17]]

for date <- dates do
  IO.puts("Running for partition: #{date}")
  {:ok, result} = FlowStone.run(DailyPipeline, :daily_summary, partition: date)
  IO.puts("  Result: #{result}\n")
end

# Check which partitions exist
IO.puts("Checking partition existence:")

for date <- dates do
  exists? = FlowStone.exists?(DailyPipeline, :daily_summary, partition: date)
  IO.puts("  #{date}: #{exists?}")
end

# Retrieve specific partition
IO.puts("\nRetrieving cached result for 2025-01-16:")
{:ok, cached} = FlowStone.get(DailyPipeline, :daily_summary, partition: ~D[2025-01-16])
IO.puts("  #{cached}")

IO.puts("\nDone!")
