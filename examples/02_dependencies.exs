# FlowStone v0.5.0 - Dependencies Example
# ========================================
#
# A pipeline with dependent assets showing automatic dependency resolution.
#
# Run: mix run examples/02_dependencies.exs

defmodule TransformPipeline do
  use FlowStone.Pipeline

  # Raw data asset
  asset :numbers do
    execute fn _, _ ->
      {:ok, [1, 2, 3, 4, 5, 6, 7, 8, 9, 10]}
    end
  end

  # Filter even numbers (depends on :numbers)
  asset :evens do
    depends_on([:numbers])

    execute fn _, %{numbers: nums} ->
      {:ok, Enum.filter(nums, &(rem(&1, 2) == 0))}
    end
  end

  # Square the numbers (depends on :evens)
  asset :squared do
    depends_on([:evens])

    execute fn _, %{evens: nums} ->
      {:ok, Enum.map(nums, &(&1 * &1))}
    end
  end

  # Sum all values (depends on :squared)
  asset :sum do
    depends_on([:squared])

    execute fn _, %{squared: nums} ->
      {:ok, Enum.sum(nums)}
    end
  end
end

IO.puts("TransformPipeline - Dependencies Example")
IO.puts("=========================================\n")

# Running :sum automatically runs all dependencies
IO.puts("Running TransformPipeline:sum (with dependencies)...")
{:ok, result} = FlowStone.run(TransformPipeline, :sum)
IO.puts("Sum of squared evens: #{result}\n")

# Check intermediate results
IO.puts("Intermediate results (all cached from the run above):")
{:ok, numbers} = FlowStone.get(TransformPipeline, :numbers)
{:ok, evens} = FlowStone.get(TransformPipeline, :evens)
{:ok, squared} = FlowStone.get(TransformPipeline, :squared)

IO.puts("  Numbers: #{inspect(numbers)}")
IO.puts("  Evens:   #{inspect(evens)}")
IO.puts("  Squared: #{inspect(squared)}")
IO.puts("  Sum:     #{result}")

# Show the pipeline graph
IO.puts("\nPipeline Graph:")
IO.puts(FlowStone.graph(TransformPipeline))

IO.puts("\nDone!")
