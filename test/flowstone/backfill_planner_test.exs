defmodule FlowStone.BackfillPlannerTest do
  use FlowStone.TestCase, isolation: :full_isolation

  defmodule PartitionedPipeline do
    use FlowStone.Pipeline

    asset :with_fn do
      partition(fn _opts -> [:p1, :p2] end)
      execute fn _, _ -> {:ok, :ok} end
    end

    asset :simple do
      execute fn _, _ -> {:ok, :ok} end
    end
  end

  setup do
    {:ok, _} = start_supervised({FlowStone.Registry, name: :bf_registry})
    {:ok, _} = start_supervised({FlowStone.IO.Memory, name: :bf_memory})
    {:ok, _} = start_supervised({FlowStone.MaterializationStore, name: :bf_store})
    FlowStone.register(PartitionedPipeline, registry: :bf_registry)

    %{io_opts: [config: %{agent: :bf_memory}]}
  end

  test "uses asset partition_fn when partitions not provided", %{io_opts: io_opts} do
    {:ok, result} =
      FlowStone.backfill(:with_fn,
        registry: :bf_registry,
        io: io_opts,
        resource_server: nil,
        materialization_store: :bf_store,
        use_repo: false,
        max_parallel: 2
      )

    assert Enum.sort(result.partitions) == [:p1, :p2]
    assert {:ok, :ok} = FlowStone.IO.load(:with_fn, :p1, io_opts)
    assert {:ok, :ok} = FlowStone.IO.load(:with_fn, :p2, io_opts)
  end

  test "skips existing partitions unless forced", %{io_opts: io_opts} do
    run_id = Ecto.UUID.generate()

    :ok =
      FlowStone.Materializations.record_success(:simple, :p1, run_id, 1,
        store: :bf_store,
        use_repo: false
      )

    {:ok, result} =
      FlowStone.backfill(:simple,
        partitions: [:p1, :p2],
        registry: :bf_registry,
        io: io_opts,
        resource_server: nil,
        materialization_store: :bf_store,
        use_repo: false,
        max_parallel: 2
      )

    assert result.skipped == [:p1]
    assert {:ok, :ok} = FlowStone.IO.load(:simple, :p2, io_opts)
  end
end
