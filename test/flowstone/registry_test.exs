defmodule FlowStone.RegistryTest do
  use FlowStone.TestCase, isolation: :full_isolation

  defmodule DemoPipeline do
    use FlowStone.Pipeline

    asset :a do
      execute fn _, _ -> {:ok, :a} end
    end

    asset :b do
      depends_on([:a])
      execute fn _, %{a: a} -> {:ok, {:b, a}} end
    end
  end

  setup do
    {:ok, pid} = start_supervised({FlowStone.Registry, name: :registry_test})
    %{server: pid}
  end

  test "registers assets and fetches by name", %{server: server} do
    FlowStone.Registry.register_assets(DemoPipeline.__flowstone_assets__(), server: server)

    assert {:ok, asset} = FlowStone.Registry.fetch(:b, server: server)
    assert asset.depends_on == [:a]
    assert length(FlowStone.Registry.list(server: server)) == 2
  end
end
