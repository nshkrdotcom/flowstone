defmodule FlowStone.MaterializeAllTest do
  use FlowStone.TestCase, isolation: :full_isolation

  defmodule Pipeline do
    use FlowStone.Pipeline

    asset :raw do
      execute fn _, _ -> {:ok, :raw} end
    end

    asset :clean do
      depends_on([:raw])
      execute fn _, %{raw: raw} -> {:ok, {:clean, raw}} end
    end
  end

  setup do
    {:ok, _} = start_supervised({FlowStone.Registry, name: :mat_registry})
    {:ok, _} = start_supervised({FlowStone.IO.Memory, name: :mat_memory})
    FlowStone.register(Pipeline, registry: :mat_registry)
    %{io_opts: [config: %{agent: :mat_memory}]}
  end

  test "materialize_all executes dependencies first", %{io_opts: io_opts} do
    assert :ok =
             FlowStone.materialize_all(:clean,
               partition: :p1,
               registry: :mat_registry,
               io: io_opts,
               resource_server: nil
             )

    assert {:ok, :raw} = FlowStone.IO.load(:raw, :p1, io_opts)
    assert {:ok, {:clean, :raw}} = FlowStone.IO.load(:clean, :p1, io_opts)
  end

  test "backfill processes multiple partitions", %{io_opts: io_opts} do
    {:ok, result} =
      FlowStone.backfill(:raw,
        partitions: [:p1, :p2],
        registry: :mat_registry,
        io: io_opts,
        resource_server: nil
      )

    assert result.partitions == [:p1, :p2]
    assert {:ok, :raw} = FlowStone.IO.load(:raw, :p1, io_opts)
    assert {:ok, :raw} = FlowStone.IO.load(:raw, :p2, io_opts)
  end
end
