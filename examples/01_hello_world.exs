# FlowStone v0.5.0 - Hello World Example
# ========================================
#
# The simplest possible FlowStone pipeline.
#
# Run: mix run examples/01_hello_world.exs

defmodule HelloPipeline do
  use FlowStone.Pipeline

  # Short-form asset - the simplest syntax
  asset(:greeting, do: {:ok, "Hello, World!"})
end

# Run the asset
IO.puts("Running HelloPipeline:greeting...")
{:ok, result} = FlowStone.run(HelloPipeline, :greeting)
IO.puts("Result: #{result}")

# The same pipeline module can also be called directly
IO.puts("\nUsing pipeline module methods:")
{:ok, result2} = HelloPipeline.run(:greeting)
IO.puts("Result: #{result2}")

IO.puts("\nDone!")
