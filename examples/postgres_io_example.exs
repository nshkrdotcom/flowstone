defmodule Examples.PostgresIOExample do
  @moduledoc false
  alias FlowStone.Repo

  @table "flowstone_pg_example"

  def run do
    ensure_table()
    ensure_started(FlowStone.Registry, name: :examples_pg_registry)

    FlowStone.register(Pipeline, registry: :examples_pg_registry)

    partition = {:tenant_1, "west"}
    io_opts = [io_manager: :postgres, config: %{table: @table, format: :binary}]

    FlowStone.materialize(:pg_asset,
      partition: partition,
      registry: :examples_pg_registry,
      io: io_opts,
      resource_server: nil
    )

    FlowStone.ObanHelpers.drain()

    load = FlowStone.IO.load(:pg_asset, partition, io_opts)

    %{loaded: load, partition: partition}
  end

  defp ensure_started(mod, opts) do
    case Process.whereis(opts[:name]) do
      nil -> mod.start_link(opts)
      pid when is_pid(pid) -> {:ok, pid}
    end
  end

  defp ensure_table do
    Repo.query!("""
    CREATE TABLE IF NOT EXISTS #{@table} (
      partition text PRIMARY KEY,
      data bytea,
      updated_at timestamp
    )
    """)
  end

  defmodule Pipeline do
    use FlowStone.Pipeline

    asset :pg_asset do
      partitioned_by({:tenant, :region})

      execute fn ctx, _deps ->
        {:ok, %{partition: ctx.partition, stored_at: DateTime.utc_now()}}
      end
    end
  end
end
