defmodule FlowStone.PipelineTest do
  use FlowStone.TestCase, isolation: :full_isolation

  alias FlowStone.DAG

  defmodule DemoPipeline do
    use FlowStone.Pipeline

    asset :raw_events do
      description("Raw inbound events")
      execute fn _ctx, _deps -> {:ok, :raw} end
    end

    asset :clean_events do
      description("Validated events")
      depends_on([:raw_events])
      execute fn _ctx, %{raw_events: raw} -> {:ok, {:clean, raw}} end
    end
  end

  test "collects asset definitions with dependencies" do
    assets = DemoPipeline.__flowstone_assets__()

    assert Enum.map(assets, & &1.name) == [:raw_events, :clean_events]

    clean = Enum.find(assets, &(&1.name == :clean_events))
    assert clean.depends_on == [:raw_events]
    assert clean.description == "Validated events"
    assert is_function(clean.execute_fn, 2)
  end

  test "derives DAG and topological order" do
    assets = DemoPipeline.__flowstone_assets__()

    assert {:ok, graph} = DAG.from_assets(assets)
    assert DAG.topological_names(graph) == [:raw_events, :clean_events]
  end

  defmodule PartitionPipeline do
    use FlowStone.Pipeline

    asset :daily do
      partitioned_by(:date)
      partition(fn _opts -> [~D[2024-01-01], ~D[2024-01-02]] end)
      execute fn _, _ -> {:ok, :p} end
    end
  end

  test "captures partition metadata and fn" do
    [asset] = PartitionPipeline.__flowstone_assets__()
    assert asset.partitioned_by == :date
    assert is_function(asset.partition_fn, 1)
  end

  defmodule CyclicPipeline do
    use FlowStone.Pipeline

    asset :a do
      depends_on([:b])
      execute fn _, _ -> {:ok, :a} end
    end

    asset :b do
      depends_on([:a])
      execute fn _, _ -> {:ok, :b} end
    end
  end

  test "detects cycles in DAG" do
    assert {:error, {:cycle, _}} = DAG.from_assets(CyclicPipeline.__flowstone_assets__())
  end

  defmodule RoutingPipeline do
    use FlowStone.Pipeline

    asset :source do
      execute fn _, _ -> {:ok, :source} end
    end

    asset :router do
      depends_on([:source])

      route do
        choice(:branch_a, when: fn _deps -> true end)
        default(:branch_b)
        on_error({:fallback, :branch_b})
      end
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
  end

  test "captures route choices and defaults" do
    router = Enum.find(RoutingPipeline.__flowstone_assets__(), &(&1.name == :router))

    assert %{choices: [{:branch_a, when_fn}], default: :branch_b} = router.route_rules
    assert is_function(when_fn, 1)
    assert router.route_error_policy == {:fallback, :branch_b}
  end

  test "adds implicit edge from router to routed assets" do
    assert {:ok, graph} = DAG.from_assets(RoutingPipeline.__flowstone_assets__())
    assert :router in Map.fetch!(graph.edges, :branch_a)
    assert :router in Map.fetch!(graph.edges, :branch_b)
  end

  defmodule OptionalDepsInvalidPipeline do
    use FlowStone.Pipeline

    asset :upstream do
      execute fn _, _ -> {:ok, :up} end
    end

    asset :merge do
      depends_on([:upstream])
      optional_deps([:upstream, :missing])
      execute fn _, _ -> {:ok, :merged} end
    end
  end

  test "validates optional_deps are subset of depends_on" do
    assert {:error, {:invalid, _}} =
             DAG.from_assets(OptionalDepsInvalidPipeline.__flowstone_assets__())
  end

  defmodule RoutedFromInvalidPipeline do
    use FlowStone.Pipeline

    asset :not_router do
      execute fn _, _ -> {:ok, :noop} end
    end

    asset :branch do
      routed_from(:not_router)
      execute fn _, _ -> {:ok, :branch} end
    end
  end

  test "validates routed_from references a router asset" do
    assert {:error, {:invalid, _}} =
             DAG.from_assets(RoutedFromInvalidPipeline.__flowstone_assets__())
  end
end
