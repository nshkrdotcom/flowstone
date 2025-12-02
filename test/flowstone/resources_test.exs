defmodule FlowStone.ResourcesTest do
  use Supertester.ExUnitFoundation, isolation: :full_isolation

  defmodule DummyResource do
    use FlowStone.Resource

    @impl true
    def setup(config), do: {:ok, Map.fetch!(config, :value)}
  end

  setup do
    {:ok, pid} =
      start_supervised(
        {FlowStone.Resources,
         name: :resources_test, resources: %{dummy: {DummyResource, %{value: 42}}}}
      )

    %{server: pid}
  end

  test "loads configured resources", %{server: server} do
    assert {:ok, 42} = FlowStone.Resources.get(:dummy, server)
    assert %{dummy: 42} = FlowStone.Resources.load(server)
  end

  test "override replaces resources", %{server: server} do
    FlowStone.Resources.override(%{dummy: :new}, server)
    assert {:ok, :new} = FlowStone.Resources.get(:dummy, server)
  end
end
