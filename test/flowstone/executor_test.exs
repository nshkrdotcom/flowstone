defmodule FlowStone.ExecutorTest do
  use Supertester.ExUnitFoundation, isolation: :full_isolation

  defmodule Pipeline do
    use FlowStone.Pipeline

    asset :dep do
      execute fn _, _ -> {:ok, :dep} end
    end

    asset :target do
      depends_on([:dep])
      execute fn _ctx, %{dep: dep} -> {:ok, {:result, dep}} end
    end
  end

  setup do
    {:ok, _} = start_supervised({FlowStone.Registry, name: :executor_registry})
    {:ok, _} = start_supervised({FlowStone.IO.Memory, name: :executor_memory})

    FlowStone.register(Pipeline, registry: :executor_registry)

    :ok
  end

  test "materializes asset with loaded dependencies" do
    io_opts = [config: %{agent: :executor_memory}]

    assert :ok = FlowStone.IO.store(:dep, :value, :p1, io_opts)

    assert {:ok, {:result, :value}} =
             FlowStone.Executor.materialize(:target,
               partition: :p1,
               registry: :executor_registry,
               io: io_opts,
               resource_server: nil
             )

    assert {:ok, {:result, :value}} = FlowStone.IO.load(:target, :p1, io_opts)
  end

  test "returns dependency_not_ready when missing upstream" do
    io_opts = [config: %{agent: :executor_memory}]

    assert {:error, %FlowStone.Error{type: :dependency_not_ready}} =
             FlowStone.Executor.materialize(:target,
               partition: :p2,
               registry: :executor_registry,
               io: io_opts,
               resource_server: nil
             )
  end
end
