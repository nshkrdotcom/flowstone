# ItemReader Example - Streaming Scatter Inputs
#
# This example demonstrates FlowStone's ItemReader support for Scatter using
# a custom reader to avoid external dependencies.

Logger.configure(level: :info)

defmodule ItemReaderExample do
  @moduledoc """
  Example pipeline demonstrating ItemReader for streaming scatter inputs.
  """

  use FlowStone.Pipeline

  asset :streamed_items do
    description("Stream items via a custom ItemReader")

    scatter_from :custom do
      init(fn _config, _deps ->
        {:ok, %{items: [1, 2, 3, 4, 5], index: 0}}
      end)

      read(fn state, batch_size ->
        remaining = Enum.drop(state.items, state.index)
        batch = Enum.take(remaining, batch_size)
        new_state = %{state | index: state.index + length(batch)}

        if batch == [] do
          {:ok, [], :halt}
        else
          {:ok, batch, new_state}
        end
      end)

      checkpoint(fn state -> %{"index" => state.index} end)
      restore(fn state, checkpoint -> %{state | index: checkpoint["index"] || 0} end)
      close(fn _state -> :ok end)
    end

    item_selector(fn item, _deps -> %{value: item} end)

    scatter_options do
      batch_size(2)
    end

    execute fn ctx, _deps ->
      {:ok, ctx.scatter_key["value"] * 2}
    end
  end
end

IO.puts(String.duplicate("=", 60))
IO.puts("FlowStone ItemReader Example")
IO.puts(String.duplicate("=", 60))

defmodule ItemReaderExample.Helper do
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

registry = ItemReaderExample.Helper.ensure_started(FlowStone.Registry, FlowStone.Registry)

FlowStone.register(ItemReaderExample, registry: registry)

[asset] = ItemReaderExample.__flowstone_assets__()
run_id = Ecto.UUID.generate()

{:ok, barrier} =
  FlowStone.Scatter.run_inline_reader(asset, %{},
    run_id: run_id,
    partition: :demo,
    enqueue: false
  )

stored = FlowStone.Repo.get!(FlowStone.Scatter.Barrier, barrier.id)

IO.puts("\nReader completed with #{stored.total_count} scatter items.")
IO.puts("Checkpoint: #{inspect(stored.reader_checkpoint)}")
IO.puts("Pending keys: #{inspect(FlowStone.Scatter.pending_keys(stored.id))}")

IO.puts("\n" <> String.duplicate("=", 60))
IO.puts("ItemReader Example Complete!")
IO.puts(String.duplicate("=", 60))
