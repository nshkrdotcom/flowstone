defmodule FlowStone.RoutingTest do
  use FlowStone.TestCase, isolation: :full_isolation

  import Ecto.Query
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

  describe "RouteDecisions cleanup" do
    test "cleanup_older_than/1 removes decisions older than specified time" do
      run_id = Ecto.UUID.generate()

      # Create a decision
      {:ok, decision} =
        RouteDecisions.record(run_id, :test_router, :partition1, :branch_a, [:branch_a, :branch_b])

      assert {:ok, _} = RouteDecisions.get(run_id, :test_router, :partition1)

      # Manually backdate the decision
      Repo.update_all(
        from(d in FlowStone.RouteDecision, where: d.id == ^decision.id),
        set: [inserted_at: DateTime.add(DateTime.utc_now(), -7 * 24 * 3600, :second)]
      )

      # Cleanup decisions older than 1 day
      {:ok, count} = RouteDecisions.cleanup_older_than(days: 1)
      assert count >= 1

      # Decision should be gone
      assert {:error, :not_found} = RouteDecisions.get(run_id, :test_router, :partition1)
    end

    test "cleanup_older_than/1 preserves recent decisions" do
      run_id = Ecto.UUID.generate()

      # Create a fresh decision
      {:ok, _} =
        RouteDecisions.record(run_id, :test_router2, :partition2, :branch_b, [
          :branch_a,
          :branch_b
        ])

      # Cleanup decisions older than 1 day - should not delete fresh decision
      {:ok, _count} = RouteDecisions.cleanup_older_than(days: 1)

      # Decision should still exist
      assert {:ok, _} = RouteDecisions.get(run_id, :test_router2, :partition2)
    end

    test "cleanup_by_run_id/1 removes all decisions for a run" do
      run_id = Ecto.UUID.generate()

      # Create multiple decisions for the same run
      {:ok, _} =
        RouteDecisions.record(run_id, :router1, :p1, :branch_a, [:branch_a, :branch_b])

      {:ok, _} =
        RouteDecisions.record(run_id, :router2, :p1, :branch_b, [:branch_a, :branch_b])

      # Both should exist
      assert {:ok, _} = RouteDecisions.get(run_id, :router1, :p1)
      assert {:ok, _} = RouteDecisions.get(run_id, :router2, :p1)

      # Cleanup by run_id
      {:ok, count} = RouteDecisions.cleanup_by_run_id(run_id)
      assert count == 2

      # Both should be gone
      assert {:error, :not_found} = RouteDecisions.get(run_id, :router1, :p1)
      assert {:error, :not_found} = RouteDecisions.get(run_id, :router2, :p1)
    end
  end
end
