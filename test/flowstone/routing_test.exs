defmodule FlowStone.RoutingTest do
  use FlowStone.TestCase, isolation: :full_isolation

  alias FlowStone.{Materialization, Partition, Repo, RouteDecisions}

  defmodule Pipeline do
    use FlowStone.Pipeline

    asset :source do
      execute fn _, _ -> {:ok, %{mode: :a}} end
    end

    asset :router do
      depends_on([:source])

      route(fn _deps ->
        :ets.update_counter(:route_counter, :count, {2, 1})
        :branch_a
      end)
    end

    asset :branch_a do
      routed_from(:router)
      depends_on([:source])
      execute fn _, _ -> {:ok, :a} end
    end

    asset :branch_b do
      routed_from(:router)
      depends_on([:source])
      execute fn _, _ -> {:ok, :b} end
    end

    asset :merge do
      depends_on([:branch_a, :branch_b])
      optional_deps([:branch_a, :branch_b])
      execute fn _, deps -> {:ok, deps} end
    end
  end

  setup do
    {:ok, _} = start_supervised({FlowStone.Registry, name: :routing_registry})
    {:ok, _} = start_supervised({FlowStone.IO.Memory, name: :routing_io})

    FlowStone.register(Pipeline, registry: :routing_registry)

    if :ets.whereis(:route_counter) != :undefined do
      :ets.delete(:route_counter)
    end

    :ets.new(:route_counter, [:named_table, :public])
    :ets.insert(:route_counter, {:count, 0})

    on_exit(fn ->
      if :ets.whereis(:route_counter) != :undefined do
        :ets.delete(:route_counter)
      end
    end)

    :ok
  end

  test "route decisions are persisted and reused" do
    io_opts = [config: %{agent: :routing_io}]
    run_id = Ecto.UUID.generate()
    partition = :p1

    assert {:ok, _} =
             FlowStone.Executor.materialize(:source,
               partition: partition,
               registry: :routing_registry,
               io: io_opts,
               resource_server: nil,
               run_id: run_id
             )

    assert {:ok, decision_output} =
             FlowStone.Executor.materialize(:router,
               partition: partition,
               registry: :routing_registry,
               io: io_opts,
               resource_server: nil,
               run_id: run_id
             )

    assert {:ok, _} =
             FlowStone.Executor.materialize(:router,
               partition: partition,
               registry: :routing_registry,
               io: io_opts,
               resource_server: nil,
               run_id: run_id
             )

    assert [{:count, 1}] = :ets.lookup(:route_counter, :count)
    assert decision_output.selected_branch == :branch_a
    assert :branch_a in decision_output.available_branches
    assert :branch_b in decision_output.available_branches

    assert {:ok, decision} = RouteDecisions.get(run_id, :router, partition)
    assert decision.router_asset == "router"
    assert decision.selected_branch == "branch_a"
  end

  test "skips unselected branches without IO writes" do
    io_opts = [config: %{agent: :routing_io}]
    run_id = Ecto.UUID.generate()
    partition = :p2

    assert {:ok, _} =
             FlowStone.Executor.materialize(:source,
               partition: partition,
               registry: :routing_registry,
               io: io_opts,
               resource_server: nil,
               run_id: run_id
             )

    assert {:ok, _} =
             FlowStone.Executor.materialize(:router,
               partition: partition,
               registry: :routing_registry,
               io: io_opts,
               resource_server: nil,
               run_id: run_id
             )

    assert {:ok, :skipped} =
             FlowStone.Executor.materialize(:branch_b,
               partition: partition,
               registry: :routing_registry,
               io: io_opts,
               resource_server: nil,
               run_id: run_id
             )

    assert {:error, _} = FlowStone.IO.load(:branch_b, partition, io_opts)

    materialization =
      Repo.get_by(Materialization,
        asset_name: "branch_b",
        partition: Partition.serialize(partition),
        run_id: run_id
      )

    assert materialization.status == :skipped
  end

  test "optional deps pass nil for missing branches" do
    io_opts = [config: %{agent: :routing_io}]
    run_id = Ecto.UUID.generate()
    partition = :p3

    assert {:ok, _} =
             FlowStone.Executor.materialize(:source,
               partition: partition,
               registry: :routing_registry,
               io: io_opts,
               resource_server: nil,
               run_id: run_id
             )

    assert {:ok, _} =
             FlowStone.Executor.materialize(:router,
               partition: partition,
               registry: :routing_registry,
               io: io_opts,
               resource_server: nil,
               run_id: run_id
             )

    assert {:ok, _} =
             FlowStone.Executor.materialize(:branch_a,
               partition: partition,
               registry: :routing_registry,
               io: io_opts,
               resource_server: nil,
               run_id: run_id
             )

    assert {:ok, deps} =
             FlowStone.Executor.materialize(:merge,
               partition: partition,
               registry: :routing_registry,
               io: io_opts,
               resource_server: nil,
               run_id: run_id
             )

    assert deps.branch_a == :a
    assert Map.has_key?(deps, :branch_b)
    assert is_nil(deps.branch_b)
  end
end
