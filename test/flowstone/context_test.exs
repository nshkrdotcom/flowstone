defmodule FlowStone.ContextTest do
  use Supertester.ExUnitFoundation, isolation: :full_isolation

  defmodule DummyRes do
    use FlowStone.Resource
    def setup(_), do: {:ok, :res}
  end

  setup do
    {:ok, pid} =
      start_supervised(
        {FlowStone.Resources, name: :context_resources, resources: %{dummy: {DummyRes, %{}}}}
      )

    %{server: pid}
  end

  test "injects only required resources", %{server: server} do
    asset = %FlowStone.Asset{name: :demo, module: __MODULE__, line: 1, requires: [:dummy]}
    ctx = FlowStone.Context.build(asset, :partition, "run-1", resource_server: server)

    assert ctx.partition == :partition
    assert ctx.run_id == "run-1"
    assert ctx.resources == %{dummy: :res}
  end

  test "falls back to empty resources when manager not running", %{server: server} do
    # Stop the running server to assert fallback path.
    GenServer.stop(server)

    asset = %FlowStone.Asset{name: :demo, module: __MODULE__, line: 1, requires: [:dummy]}
    ctx = FlowStone.Context.build(asset, :p1, "run-2")

    assert ctx.resources == %{}
  end
end
