defmodule FlowStone.Workers.AssetWorkerTest do
  use FlowStone.TestCase, isolation: :full_isolation

  alias FlowStone.Workers.AssetWorker

  defmodule Pipeline do
    use FlowStone.Pipeline

    asset :dep do
      execute fn _, _ -> {:ok, :dep} end
    end

    asset :target do
      depends_on([:dep])
      execute fn _, %{dep: dep} -> {:ok, {:done, dep}} end
    end
  end

  setup do
    {:ok, _} = start_supervised({FlowStone.Registry, name: :worker_registry})
    {:ok, _} = start_supervised({FlowStone.IO.Memory, name: :worker_memory})
    FlowStone.register(Pipeline, registry: :worker_registry)
    %{io_opts: [config: %{agent: :worker_memory}]}
  end

  test "snoozes when dependency missing", %{io_opts: io_opts} do
    job = %Oban.Job{
      args: %{
        "asset_name" => "target",
        "partition" => :p1,
        "registry" => :worker_registry,
        "io" => io_opts
      }
    }

    assert {:snooze, 30} = AssetWorker.perform(job)
  end

  test "executes when dependency exists", %{io_opts: io_opts} do
    assert :ok = FlowStone.IO.store(:dep, :value, :p1, io_opts)

    job = %Oban.Job{
      args: %{
        "asset_name" => "target",
        "partition" => :p1,
        "registry" => :worker_registry,
        "io" => io_opts
      }
    }

    assert :ok = AssetWorker.perform(job)
    assert {:ok, {:done, :value}} = FlowStone.IO.load(:target, :p1, io_opts)
  end
end
