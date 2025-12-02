defmodule FlowStone.MaterializeAsyncTest do
  use FlowStone.TestCase, isolation: :full_isolation

  defmodule Pipeline do
    use FlowStone.Pipeline

    asset :a do
      execute fn _, _ -> {:ok, :a} end
    end
  end

  setup do
    {:ok, _} = start_supervised({FlowStone.Registry, name: :async_registry})
    {:ok, _} = start_supervised({FlowStone.IO.Memory, name: :async_mem})
    FlowStone.register(Pipeline, registry: :async_registry)
    %{io_opts: [config: %{agent: :async_mem}]}
  end

  test "executes inline", %{io_opts: io_opts} do
    result =
      FlowStone.materialize_async(:a,
        partition: :p,
        registry: :async_registry,
        io: io_opts,
        resource_server: nil
      )

    assert result == :ok or match?({:ok, %Oban.Job{}}, result)
    FlowStone.ObanHelpers.drain()

    assert {:ok, :a} = FlowStone.IO.load(:a, :p, io_opts)
  end
end
