defmodule FlowStone.ParallelBranchesTest do
  use FlowStone.TestCase, isolation: :full_isolation

  import ExUnit.CaptureLog

  alias FlowStone.MaterializationContext

  defmodule SuccessPipeline do
    use FlowStone.Pipeline

    asset :success_dep do
      execute fn _, _ -> {:ok, :dep} end
    end

    asset :success_branch_a do
      depends_on([:success_dep])
      execute fn _, %{success_dep: dep} -> {:ok, {:a, dep}} end
    end

    asset :success_branch_b do
      depends_on([:success_dep])
      execute fn _, %{success_dep: dep} -> {:ok, {:b, dep}} end
    end

    asset :success_parallel do
      depends_on([:success_dep])

      parallel do
        branch(:a, final: :success_branch_a)
        branch(:b, final: :success_branch_b)
      end

      parallel_options do
        failure_mode(:all_or_nothing)
      end

      join(fn branches, deps ->
        %{branches: branches, dep: deps.success_dep}
      end)
    end
  end

  defmodule PartialPipeline do
    use FlowStone.Pipeline

    asset :partial_source do
      execute fn _, _ -> {:ok, :source} end
    end

    asset :partial_router do
      depends_on([:partial_source])
      route(fn _deps -> :partial_selected end)
    end

    asset :partial_selected do
      routed_from(:partial_router)
      depends_on([:partial_source])
      execute fn _, _ -> {:ok, :ok} end
    end

    asset :partial_skipped do
      routed_from(:partial_router)
      depends_on([:partial_source])
      execute fn _, _ -> {:ok, :skip} end
    end

    asset :partial_failed do
      depends_on([:partial_source])
      execute fn _, _ -> {:error, "boom"} end
    end

    asset :partial_parallel do
      depends_on([:partial_source, :partial_router])

      parallel do
        branch(:good, final: :partial_selected)
        branch(:skipped, final: :partial_skipped)
        branch(:bad, final: :partial_failed)
      end

      parallel_options do
        failure_mode(:partial)
      end

      join(fn branches -> branches end)
    end
  end

  defmodule AllOrNothingPipeline do
    use FlowStone.Pipeline

    asset :fail_dep do
      execute fn _, _ -> {:ok, :dep} end
    end

    asset :fail_good do
      depends_on([:fail_dep])
      execute fn _, %{fail_dep: dep} -> {:ok, {:good, dep}} end
    end

    asset :fail_bad do
      depends_on([:fail_dep])
      execute fn _, _ -> {:error, "nope"} end
    end

    asset :fail_parallel do
      depends_on([:fail_dep])

      parallel do
        branch(:good, final: :fail_good)
        branch(:bad, final: :fail_bad)
      end

      parallel_options do
        failure_mode(:all_or_nothing)
      end

      join(fn branches -> branches end)
    end
  end

  defmodule LineagePipeline do
    use FlowStone.Pipeline

    asset :lineage_dep do
      execute fn _, _ -> {:ok, :dep} end
    end

    asset :lineage_branch_a do
      depends_on([:lineage_dep])
      execute fn _, %{lineage_dep: dep} -> {:ok, {:a, dep}} end
    end

    asset :lineage_branch_b do
      depends_on([:lineage_dep])
      execute fn _, %{lineage_dep: dep} -> {:ok, {:b, dep}} end
    end

    asset :lineage_parallel do
      depends_on([:lineage_dep])

      parallel do
        branch(:a, final: :lineage_branch_a)
        branch(:b, final: :lineage_branch_b)
      end

      parallel_options do
        failure_mode(:all_or_nothing)
      end

      join(fn branches -> branches end)
    end
  end

  defmodule TelemetryPipeline do
    use FlowStone.Pipeline

    asset :tele_dep do
      execute fn _, _ -> {:ok, :dep} end
    end

    asset :tele_branch_a do
      depends_on([:tele_dep])
      execute fn _, %{tele_dep: dep} -> {:ok, {:a, dep}} end
    end

    asset :tele_branch_b do
      depends_on([:tele_dep])
      execute fn _, %{tele_dep: dep} -> {:ok, {:b, dep}} end
    end

    asset :tele_parallel do
      depends_on([:tele_dep])

      parallel do
        branch(:a, final: :tele_branch_a)
        branch(:b, final: :tele_branch_b)
      end

      parallel_options do
        failure_mode(:all_or_nothing)
      end

      join(fn branches -> branches end)
    end
  end

  defp unique_name(prefix) do
    :"#{prefix}_#{System.unique_integer([:positive])}"
  end

  defp setup_registry_io(pipeline) do
    registry = unique_name(:parallel_registry)
    io_agent = unique_name(:parallel_io)

    {:ok, _} = start_supervised({FlowStone.Registry, name: registry})
    {:ok, _} = start_supervised({FlowStone.IO.Memory, name: io_agent})

    FlowStone.register(pipeline, registry: registry)

    {registry, [config: %{agent: io_agent}]}
  end

  defp compile_pipeline(body) do
    module_name = "ParallelDsl#{System.unique_integer([:positive])}"

    source = """
    defmodule #{module_name} do
      use FlowStone.Pipeline

      #{body}
    end
    """

    Code.compile_string(source)
  end

  test "parallel branch names must be unique" do
    assert_raise ArgumentError, ~r/branch name/i, fn ->
      compile_pipeline("""
      asset :dup_asset do
        parallel do
          branch :dup, final: :dup_a
          branch :dup, final: :dup_b
        end

        join fn branches -> branches end
      end

      asset :dup_a do
        execute fn _, _ -> {:ok, :a} end
      end

      asset :dup_b do
        execute fn _, _ -> {:ok, :b} end
      end
      """)
    end
  end

  test "parallel branch requires final asset" do
    assert_raise ArgumentError, ~r/final/i, fn ->
      compile_pipeline("""
      asset :missing_final do
        parallel do
          branch :oops
        end

        join fn branches -> branches end
      end

      asset :downstream do
        execute fn _, _ -> {:ok, :ok} end
      end
      """)
    end
  end

  test "adds implicit edge from parallel asset to branch finals" do
    assets = SuccessPipeline.__flowstone_assets__()
    assert {:ok, graph} = FlowStone.DAG.from_assets(assets)

    assert :success_parallel in Map.fetch!(graph.edges, :success_branch_a)
    assert :success_parallel in Map.fetch!(graph.edges, :success_branch_b)
  end

  test "schedules branch assets with the same run_id" do
    {registry, io_opts} = setup_registry_io(SuccessPipeline)
    run_id = Ecto.UUID.generate()
    partition = :p1

    result =
      FlowStone.materialize(:success_dep,
        partition: partition,
        registry: registry,
        io: io_opts,
        resource_server: nil,
        run_id: run_id
      )

    assert result == :ok or match?({:ok, %Oban.Job{}}, result)
    FlowStone.ObanHelpers.drain()

    result =
      FlowStone.materialize(:success_parallel,
        partition: partition,
        registry: registry,
        io: io_opts,
        resource_server: nil,
        run_id: run_id
      )

    assert result == :ok or match?({:ok, %Oban.Job{}}, result)
    FlowStone.ObanHelpers.drain()

    assert %FlowStone.Materialization{run_id: ^run_id} =
             MaterializationContext.get(:success_branch_a, partition, run_id)

    assert %FlowStone.Materialization{run_id: ^run_id} =
             MaterializationContext.get(:success_branch_b, partition, run_id)
  end

  test "stores joined result when all branches succeed" do
    {registry, io_opts} = setup_registry_io(SuccessPipeline)
    run_id = Ecto.UUID.generate()
    partition = :p2

    result =
      FlowStone.materialize(:success_dep,
        partition: partition,
        registry: registry,
        io: io_opts,
        resource_server: nil,
        run_id: run_id
      )

    assert result == :ok or match?({:ok, %Oban.Job{}}, result)
    FlowStone.ObanHelpers.drain()

    result =
      FlowStone.materialize(:success_parallel,
        partition: partition,
        registry: registry,
        io: io_opts,
        resource_server: nil,
        run_id: run_id
      )

    assert result == :ok or match?({:ok, %Oban.Job{}}, result)
    FlowStone.ObanHelpers.drain()

    assert {:ok, result} = FlowStone.IO.load(:success_parallel, partition, io_opts)
    assert %{branches: %{a: {:a, :dep}, b: {:b, :dep}}, dep: :dep} = result
  end

  test "partial failure mode returns status tuples and skipped" do
    {registry, io_opts} = setup_registry_io(PartialPipeline)
    run_id = Ecto.UUID.generate()
    partition = :p3

    for asset <- [:partial_source, :partial_router] do
      result =
        FlowStone.materialize(asset,
          partition: partition,
          registry: registry,
          io: io_opts,
          resource_server: nil,
          run_id: run_id
        )

      assert result == :ok or match?({:ok, %Oban.Job{}}, result)
      FlowStone.ObanHelpers.drain()
    end

    log =
      capture_log(fn ->
        result =
          FlowStone.materialize(:partial_parallel,
            partition: partition,
            registry: registry,
            io: io_opts,
            resource_server: nil,
            run_id: run_id
          )

        assert result == :ok or match?({:ok, %Oban.Job{}}, result)
        FlowStone.ObanHelpers.drain()
      end)

    assert log =~ "Asset execution failed: boom"

    assert {:ok, branches} = FlowStone.IO.load(:partial_parallel, partition, io_opts)
    assert branches.good == {:ok, :ok}
    assert branches.skipped == :skipped

    assert {:error, reason} = branches.bad
    assert is_binary(reason)
    assert String.contains?(reason, "boom")
  end

  test "all_or_nothing fails when a required branch fails" do
    {registry, io_opts} = setup_registry_io(AllOrNothingPipeline)
    run_id = Ecto.UUID.generate()
    partition = :p4

    result =
      FlowStone.materialize(:fail_dep,
        partition: partition,
        registry: registry,
        io: io_opts,
        resource_server: nil,
        run_id: run_id
      )

    assert result == :ok or match?({:ok, %Oban.Job{}}, result)
    FlowStone.ObanHelpers.drain()

    log =
      capture_log(fn ->
        result =
          FlowStone.materialize(:fail_parallel,
            partition: partition,
            registry: registry,
            io: io_opts,
            resource_server: nil,
            run_id: run_id
          )

        assert result == :ok or match?({:ok, %Oban.Job{}}, result)
        FlowStone.ObanHelpers.drain()
      end)

    assert log =~ "Asset execution failed: nope"

    assert %FlowStone.Materialization{status: :failed} =
             MaterializationContext.get(:fail_parallel, partition, run_id)

    assert {:error, _} = FlowStone.IO.load(:fail_parallel, partition, io_opts)
  end

  test "lineage includes branch final assets" do
    {registry, io_opts} = setup_registry_io(LineagePipeline)
    lineage_server = unique_name(:parallel_lineage)
    mat_store = unique_name(:parallel_mat_store)

    {:ok, _} = start_supervised({FlowStone.Lineage, name: lineage_server})
    {:ok, _} = start_supervised({FlowStone.MaterializationStore, name: mat_store})

    run_id = Ecto.UUID.generate()
    partition = :p5

    for asset <- [:lineage_dep, :lineage_parallel] do
      result =
        FlowStone.materialize(asset,
          partition: partition,
          registry: registry,
          io: io_opts,
          resource_server: nil,
          run_id: run_id,
          use_repo: false,
          lineage_server: lineage_server,
          materialization_store: mat_store
        )

      assert result == :ok or match?({:ok, %Oban.Job{}}, result)
      FlowStone.ObanHelpers.drain()
    end

    upstream = FlowStone.Lineage.upstream(:lineage_parallel, partition, lineage_server)

    assert Enum.any?(upstream, &(&1.asset == :lineage_dep))
    assert Enum.any?(upstream, &(&1.asset == :lineage_branch_a))
    assert Enum.any?(upstream, &(&1.asset == :lineage_branch_b))
  end

  test "emits telemetry events for start/stop and branch completion" do
    {registry, io_opts} = setup_registry_io(TelemetryPipeline)
    run_id = Ecto.UUID.generate()
    partition = :p6
    self = self()

    handler = fn event, meas, meta, pid ->
      send(pid, {:event, event, meas, meta})
    end

    :telemetry.attach_many(
      "parallel-telemetry-test",
      [
        [:flowstone, :parallel, :start],
        [:flowstone, :parallel, :stop],
        [:flowstone, :parallel, :branch_start],
        [:flowstone, :parallel, :branch_complete]
      ],
      handler,
      self
    )

    result =
      FlowStone.materialize(:tele_dep,
        partition: partition,
        registry: registry,
        io: io_opts,
        resource_server: nil,
        run_id: run_id
      )

    assert result == :ok or match?({:ok, %Oban.Job{}}, result)
    FlowStone.ObanHelpers.drain()

    result =
      FlowStone.materialize(:tele_parallel,
        partition: partition,
        registry: registry,
        io: io_opts,
        resource_server: nil,
        run_id: run_id
      )

    assert result == :ok or match?({:ok, %Oban.Job{}}, result)
    FlowStone.ObanHelpers.drain()

    assert_receive {:event, [:flowstone, :parallel, :start], _, %{asset: :tele_parallel}}
    assert_receive {:event, [:flowstone, :parallel, :stop], _, %{asset: :tele_parallel}}
    assert_receive {:event, [:flowstone, :parallel, :branch_start], _, %{branch: :a}}
    assert_receive {:event, [:flowstone, :parallel, :branch_complete], _, %{branch: :a}}
  after
    :telemetry.detach("parallel-telemetry-test")
  end

  test "emits telemetry error and branch failure events" do
    {registry, io_opts} = setup_registry_io(AllOrNothingPipeline)
    run_id = Ecto.UUID.generate()
    partition = :p7
    self = self()

    handler = fn event, meas, meta, pid ->
      send(pid, {:event, event, meas, meta})
    end

    :telemetry.attach_many(
      "parallel-telemetry-error-test",
      [
        [:flowstone, :parallel, :start],
        [:flowstone, :parallel, :error],
        [:flowstone, :parallel, :branch_fail]
      ],
      handler,
      self
    )

    result =
      FlowStone.materialize(:fail_dep,
        partition: partition,
        registry: registry,
        io: io_opts,
        resource_server: nil,
        run_id: run_id
      )

    assert result == :ok or match?({:ok, %Oban.Job{}}, result)
    FlowStone.ObanHelpers.drain()

    log =
      capture_log(fn ->
        result =
          FlowStone.materialize(:fail_parallel,
            partition: partition,
            registry: registry,
            io: io_opts,
            resource_server: nil,
            run_id: run_id
          )

        assert result == :ok or match?({:ok, %Oban.Job{}}, result)
        FlowStone.ObanHelpers.drain()
      end)

    assert log =~ "Asset execution failed: nope"

    assert_receive {:event, [:flowstone, :parallel, :start], _, %{asset: :fail_parallel}}
    assert_receive {:event, [:flowstone, :parallel, :error], _, %{asset: :fail_parallel}}
    assert_receive {:event, [:flowstone, :parallel, :branch_fail], _, %{branch: :bad}}
  after
    :telemetry.detach("parallel-telemetry-error-test")
  end
end
