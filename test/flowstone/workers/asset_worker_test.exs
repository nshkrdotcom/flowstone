defmodule FlowStone.Workers.AssetWorkerTest do
  use FlowStone.TestCase, isolation: :full_isolation

  alias FlowStone.Partition
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

    io_opts = [config: %{agent: :worker_memory}]

    run_config = [
      registry: :worker_registry,
      io_config: %{"config" => %{agent: :worker_memory}}
    ]

    %{io_opts: io_opts, run_config: run_config}
  end

  test "snoozes when dependency missing", %{run_config: run_config} do
    # Build JSON-safe args
    job = %Oban.Job{
      args: %{
        "asset_name" => "target",
        "partition" => Partition.serialize(:p1),
        "run_id" => Ecto.UUID.generate(),
        "use_repo" => false
      }
    }

    assert {:snooze, 30} = AssetWorker.perform(job, run_config)
  end

  test "executes when dependency exists", %{io_opts: io_opts, run_config: run_config} do
    assert :ok = FlowStone.IO.store(:dep, :value, :p1, io_opts)

    job = %Oban.Job{
      args: %{
        "asset_name" => "target",
        "partition" => Partition.serialize(:p1),
        "run_id" => Ecto.UUID.generate(),
        "use_repo" => false
      }
    }

    assert :ok = AssetWorker.perform(job, run_config)
    assert {:ok, {:done, :value}} = FlowStone.IO.load(:target, :p1, io_opts)
  end

  test "discards unknown assets", %{run_config: run_config} do
    job = %Oban.Job{
      args: %{
        "asset_name" => "unknown_asset_that_does_not_exist",
        "partition" => Partition.serialize(:p1),
        "run_id" => Ecto.UUID.generate(),
        "use_repo" => false
      }
    }

    # Should discard with error message about unknown asset
    assert {:discard, _reason} = AssetWorker.perform(job, run_config)
  end

  test "uses exponential backoff" do
    assert AssetWorker.backoff(%Oban.Job{attempt: 1}) >= 5
    assert AssetWorker.backoff(%Oban.Job{attempt: 5}) <= 300
  end

  describe "JSON round-trip safety" do
    test "args survive JSON encoding/decoding", %{io_opts: io_opts, run_config: run_config} do
      # Store dependency
      :ok = FlowStone.IO.store(:dep, :value, :p1, io_opts)

      # Create args as FlowStone.build_args would
      original_args = %{
        "asset_name" => "target",
        "partition" => Partition.serialize(:p1),
        "run_id" => Ecto.UUID.generate(),
        "use_repo" => false
      }

      # Simulate JSON round-trip (what Oban does)
      json_encoded = Jason.encode!(original_args)
      decoded_args = Jason.decode!(json_encoded)

      # Should work with decoded args
      job = %Oban.Job{args: decoded_args}
      assert :ok = AssetWorker.perform(job, run_config)
    end
  end
end
