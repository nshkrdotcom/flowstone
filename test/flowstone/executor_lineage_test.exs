defmodule FlowStone.ExecutorLineageTest do
  use FlowStone.TestCase, isolation: :full_isolation

  defmodule Pipeline do
    use FlowStone.Pipeline

    asset :dep do
      execute fn _, _ -> {:ok, :dep} end
    end

    asset :target do
      depends_on([:dep])
      execute fn _, %{dep: dep} -> {:ok, {:done, dep}} end
    end
  end

  setup do
    {:ok, _} = start_supervised({FlowStone.Registry, name: :lineage_registry})
    {:ok, _} = start_supervised({FlowStone.IO.Memory, name: :lineage_mem})
    {:ok, _} = start_supervised({FlowStone.Lineage, name: :lineage_server})
    {:ok, _} = start_supervised({FlowStone.MaterializationStore, name: :mat_store})
    FlowStone.register(Pipeline, registry: :lineage_registry)
    %{io_opts: [config: %{agent: :lineage_mem}]}
  end

  test "records lineage when materializing", %{io_opts: io_opts} do
    :ok = FlowStone.IO.store(:dep, :v, :p, io_opts)
    run_id = Ecto.UUID.generate()

    result =
      FlowStone.materialize(:target,
        partition: :p,
        registry: :lineage_registry,
        io: io_opts,
        materialization_store: :mat_store,
        lineage_server: :lineage_server,
        resource_server: nil,
        use_repo: false,
        run_id: run_id
      )

    assert result == :ok or match?({:ok, %Oban.Job{}}, result)

    FlowStone.ObanHelpers.drain()

    assert [%{asset: :dep, partition: "p"}] =
             FlowStone.Lineage.upstream(:target, :p, :lineage_server)

    assert [%{asset: :target}] = FlowStone.Lineage.downstream(:dep, :p, :lineage_server)

    assert %{status: :success} =
             FlowStone.MaterializationStore.get(:target, :p, run_id, :mat_store)
  end
end
