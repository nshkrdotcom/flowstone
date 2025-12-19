defmodule Examples.BackfillExample do
  @moduledoc false

  def run do
    ensure_started(FlowStone.Registry, name: :examples_backfill_registry)
    ensure_started(FlowStone.IO.Memory, name: :examples_backfill_io)
    ensure_started(FlowStone.MaterializationStore, name: :examples_backfill_store)

    FlowStone.register(__MODULE__.Pipeline, registry: :examples_backfill_registry)

    {:ok, result} =
      FlowStone.backfill(:daily_metric,
        registry: :examples_backfill_registry,
        io: [config: %{agent: :examples_backfill_io}],
        resource_server: nil,
        materialization_store: :examples_backfill_store,
        use_repo: false,
        max_parallel: 2
      )

    FlowStone.ObanHelpers.drain()

    loads =
      Enum.map(result.partitions, fn partition ->
        {partition,
         FlowStone.IO.load(:daily_metric, partition, config: %{agent: :examples_backfill_io})}
      end)

    %{result: result, loads: loads}
  end

  defp ensure_started(mod, opts) do
    case Process.whereis(opts[:name]) do
      nil -> mod.start_link(opts)
      pid when is_pid(pid) -> {:ok, pid}
    end
  end

  defmodule Pipeline do
    use FlowStone.Pipeline

    asset :daily_metric do
      partitioned_by(:date)
      partition(fn _opts -> Date.range(~D[2024-01-01], ~D[2024-01-03]) end)
      execute fn ctx, _ -> {:ok, {:value, ctx.partition}} end
    end
  end
end
