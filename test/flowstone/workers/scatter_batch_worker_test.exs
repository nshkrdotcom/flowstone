defmodule FlowStone.Workers.ScatterBatchWorkerTest do
  use FlowStone.TestCase, isolation: :full_isolation
  import ExUnit.CaptureLog

  alias FlowStone.Scatter
  alias FlowStone.Scatter.{BatchOptions, Result}
  alias FlowStone.Workers.ScatterBatchWorker

  defmodule BatchPipeline do
    use FlowStone.Pipeline

    asset :batched_asset do
      scatter(fn _deps -> Enum.map(1..5, &%{id: &1}) end)

      batch_options do
        max_items_per_batch(2)
        batch_input(fn _deps -> %{env: "test"} end)
      end

      execute fn ctx, _deps ->
        # Return sum of batch item ids
        # batch_items and batch_input use string keys after JSON storage
        sum = Enum.sum(Enum.map(ctx.batch_items, & &1["id"]))
        {:ok, %{sum: sum, env: ctx.batch_input["env"]}}
      end
    end
  end

  setup do
    {:ok, _} = start_supervised({FlowStone.Registry, name: :batch_worker_registry})
    {:ok, _} = start_supervised({FlowStone.IO.Memory, name: :batch_worker_memory})
    FlowStone.register(BatchPipeline, registry: :batch_worker_registry)

    run_config = [
      registry: :batch_worker_registry,
      io_config: %{"config" => %{agent: :batch_worker_memory}}
    ]

    %{run_config: run_config}
  end

  describe "perform/2" do
    test "executes batch and records completion", %{run_config: run_config} do
      run_id = Ecto.UUID.generate()
      batch_items = [%{id: 1}, %{id: 2}]
      batch_input = %{env: "test"}

      # Create barrier with batching enabled using batch_options
      # This will automatically create the batch result records
      {:ok, barrier} =
        Scatter.create_barrier(
          run_id: run_id,
          asset_name: :batched_asset,
          scatter_keys: batch_items,
          options: %Scatter.Options{},
          batch_options: BatchOptions.new(max_items_per_batch: 2),
          batch_input: batch_input
        )

      # Get the batch result that was created
      import Ecto.Query

      [batch_result] =
        FlowStone.Repo.all(
          from r in Result,
            where: r.barrier_id == ^barrier.id
        )

      job = %Oban.Job{
        args: %{
          "barrier_id" => barrier.id,
          "batch_index" => 0,
          "scatter_key" => batch_result.scatter_key,
          "asset_name" => "batched_asset",
          "run_id" => run_id
        }
      }

      result = ScatterBatchWorker.perform(job, run_config)

      assert result == :ok

      # Verify barrier was updated
      {:ok, updated} = Scatter.get_barrier(barrier.id)
      assert updated.completed_count == 1
    end

    test "builds context with batch fields", %{run_config: run_config} do
      run_id = Ecto.UUID.generate()
      batch_items = [%{id: 3}, %{id: 4}]
      batch_input = %{region: "us-east"}

      {:ok, barrier} =
        Scatter.create_barrier(
          run_id: run_id,
          asset_name: :batched_asset,
          scatter_keys: batch_items,
          batch_options: BatchOptions.new(max_items_per_batch: 2),
          batch_input: batch_input
        )

      # Get the batch result that was created
      import Ecto.Query

      [batch_result] =
        FlowStone.Repo.all(
          from r in Result,
            where: r.barrier_id == ^barrier.id
        )

      job = %Oban.Job{
        args: %{
          "barrier_id" => barrier.id,
          "batch_index" => 0,
          "scatter_key" => batch_result.scatter_key,
          "asset_name" => "batched_asset",
          "run_id" => run_id
        }
      }

      # The worker should build context with batch fields
      # This is verified by the execute function receiving them
      result = ScatterBatchWorker.perform(job, run_config)

      assert result == :ok
    end

    test "handles batch failure", %{run_config: run_config} do
      defmodule FailingBatchPipeline do
        use FlowStone.Pipeline

        asset :failing_batch do
          execute fn _ctx, _deps -> {:error, "batch failed"} end
        end
      end

      FlowStone.register(FailingBatchPipeline, registry: :batch_worker_registry)

      run_id = Ecto.UUID.generate()
      batch_items = [%{id: 1}]

      {:ok, barrier} =
        Scatter.create_barrier(
          run_id: run_id,
          asset_name: :failing_batch,
          scatter_keys: batch_items,
          options: %Scatter.Options{failure_mode: :partial, failure_threshold: 0.5},
          batch_options: BatchOptions.new(max_items_per_batch: 1)
        )

      # Get the batch result that was created
      import Ecto.Query

      [batch_result] =
        FlowStone.Repo.all(
          from r in Result,
            where: r.barrier_id == ^barrier.id
        )

      job = %Oban.Job{
        args: %{
          "barrier_id" => barrier.id,
          "batch_index" => 0,
          "scatter_key" => batch_result.scatter_key,
          "asset_name" => "failing_batch",
          "run_id" => run_id
        }
      }

      # Capture the expected error log
      {result, log} =
        with_log(fn ->
          ScatterBatchWorker.perform(job, run_config)
        end)

      assert {:error, _} = result
      assert log =~ "batch failed"

      {:ok, updated} = Scatter.get_barrier(barrier.id)
      assert updated.failed_count == 1
    end
  end

  describe "backoff/1" do
    test "uses exponential backoff" do
      assert ScatterBatchWorker.backoff(%Oban.Job{attempt: 1}) >= 5
      assert ScatterBatchWorker.backoff(%Oban.Job{attempt: 5}) <= 300
    end
  end
end
