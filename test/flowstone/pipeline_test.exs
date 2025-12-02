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
end
