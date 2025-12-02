defmodule FlowStoneTest do
  use Supertester.ExUnitFoundation, isolation: :full_isolation

  defmodule Pipeline do
    use FlowStone.Pipeline

    asset :first do
      execute fn _, _ -> {:ok, :one} end
    end

    asset :second do
      depends_on([:first])
      execute fn _, %{first: first} -> {:ok, {:two, first}} end
    end
  end

  setup do
    {:ok, _pid} = start_supervised({FlowStone.Registry, name: :flowstone_registry})
    :ok
  end

  test "registers pipeline assets into registry" do
    FlowStone.register(Pipeline, registry: :flowstone_registry)

    assert {:ok, asset} = FlowStone.Registry.fetch(:second, server: :flowstone_registry)
    assert asset.depends_on == [:first]
  end
end
