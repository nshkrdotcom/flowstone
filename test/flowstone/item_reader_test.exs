defmodule FlowStone.ItemReaderTest do
  use FlowStone.TestCase, isolation: :full_isolation

  import Ecto.Query

  alias FlowStone.Repo
  alias FlowStone.Scatter
  alias FlowStone.Scatter.{Barrier, Result}
  alias FlowStone.Scatter.ItemReaders.{DynamoDB, S3}

  defmodule DslPipeline do
    use FlowStone.Pipeline

    asset :items do
      scatter_from :s3 do
        bucket(fn deps -> deps.bucket end)
        prefix(fn deps -> deps.prefix end)
        max_items(250)
        reader_batch_size(1000)
        start_after("cursor")
      end

      item_selector(fn item, deps -> %{key: item, bucket: deps.bucket} end)

      execute fn _ctx, _deps -> {:ok, :noop} end
    end
  end

  defmodule InlinePipeline do
    use FlowStone.Pipeline

    asset :inline_items do
      scatter_from :custom do
        init(fn _config, _deps ->
          {:ok, %{items: [1, 2, 3], index: 0}}
        end)

        read(fn state, batch_size ->
          items = Enum.drop(state.items, state.index)
          batch = Enum.take(items, batch_size)
          new_state = %{state | index: state.index + length(batch)}

          if batch == [] do
            {:ok, [], :halt}
          else
            {:ok, batch, new_state}
          end
        end)

        count(fn state -> {:ok, length(state.items)} end)
        checkpoint(fn state -> %{"index" => state.index} end)
        restore(fn state, checkpoint -> %{state | index: checkpoint["index"]} end)
        close(fn _state -> :ok end)
      end

      item_selector(fn item, _deps -> %{value: item} end)

      scatter_options do
        batch_size(2)
      end

      execute fn _ctx, _deps -> {:ok, :ok} end
    end
  end

  defmodule ErrorPipeline do
    use FlowStone.Pipeline

    asset :error_items do
      scatter_from :custom do
        init(fn _config, _deps -> {:ok, %{}} end)
        read(fn _state, _batch_size -> {:error, :boom} end)
      end

      item_selector(fn _item, _deps -> %{value: :error} end)

      execute fn _ctx, _deps -> {:ok, :ok} end
    end
  end

  defmodule DistributedPipeline do
    use FlowStone.Pipeline

    asset :distributed_items do
      scatter_from :custom do
        init(fn _config, _deps ->
          {:ok, %{items: [1, 2, 3], index: 0}}
        end)

        read(fn state, batch_size ->
          items = Enum.drop(state.items, state.index)
          batch = Enum.take(items, batch_size)
          new_state = %{state | index: state.index + length(batch)}

          if batch == [] do
            {:ok, [], :halt}
          else
            {:ok, batch, new_state}
          end
        end)

        checkpoint(fn state -> %{"index" => state.index} end)
        restore(fn state, checkpoint -> %{state | index: checkpoint["index"]} end)
        close(fn _state -> :ok end)
      end

      item_selector(fn item, _deps -> %{value: item} end)

      scatter_options do
        mode(:distributed)
        batch_size(2)
      end

      execute fn _ctx, _deps -> {:ok, :ok} end
    end
  end

  test "scatter_from stores source config and item_selector" do
    [asset] = DslPipeline.__flowstone_assets__()

    assert asset.scatter_source == :s3
    assert is_function(asset.item_selector_fn, 2)
    assert asset.scatter_source_config[:max_items] == 250
    assert asset.scatter_source_config[:reader_batch_size] == 1000
    assert asset.scatter_source_config[:start_after] == "cursor"
    assert is_function(asset.scatter_source_config[:bucket], 1)
    assert is_function(asset.scatter_source_config[:prefix], 1)
  end

  test "inline mode streams results without storing keys in barrier" do
    [asset] = InlinePipeline.__flowstone_assets__()
    run_id = Ecto.UUID.generate()

    {:ok, barrier} =
      Scatter.run_inline_reader(asset, %{},
        run_id: run_id,
        partition: :default,
        enqueue: false
      )

    stored = Repo.get!(Barrier, barrier.id)
    assert stored.total_count == 3
    assert stored.scatter_keys == []
    assert length(Scatter.pending_keys(stored.id)) == 3

    results =
      from(r in Result, where: r.barrier_id == ^stored.id, select: r.scatter_key)
      |> Repo.all()

    assert Enum.sort(results) == Enum.sort([%{"value" => 1}, %{"value" => 2}, %{"value" => 3}])
  end

  test "checkpoint and restore resume reads" do
    [asset] = InlinePipeline.__flowstone_assets__()
    run_id = Ecto.UUID.generate()

    {:ok, barrier} =
      Scatter.run_inline_reader(asset, %{},
        run_id: run_id,
        partition: :default,
        enqueue: false,
        batch_size: 1,
        max_batches: 1
      )

    stored = Repo.get!(Barrier, barrier.id)
    assert stored.total_count == 1
    assert stored.reader_checkpoint == %{"index" => 1}

    {:ok, _barrier} =
      Scatter.run_inline_reader(asset, %{},
        run_id: run_id,
        partition: :default,
        enqueue: false,
        barrier_id: stored.id,
        batch_size: 1
      )

    resumed = Repo.get!(Barrier, stored.id)
    assert resumed.total_count == 3
  end

  test "distributed mode creates parent and sub barriers with checkpoints" do
    [asset] = DistributedPipeline.__flowstone_assets__()
    run_id = Ecto.UUID.generate()

    {:ok, parent} =
      Scatter.run_distributed_reader(asset, %{},
        run_id: run_id,
        partition: :default,
        enqueue: false
      )

    parent = Repo.get!(Barrier, parent.id)
    assert parent.mode == :distributed
    assert parent.reader_checkpoint == %{"index" => 3}

    children =
      from(b in Barrier, where: b.parent_barrier_id == ^parent.id, order_by: b.batch_index)
      |> Repo.all()

    assert Enum.map(children, & &1.total_count) == [2, 1]
    assert Enum.map(children, & &1.batch_index) == [0, 1]
  end

  test "reader errors propagate as failures" do
    [asset] = ErrorPipeline.__flowstone_assets__()
    run_id = Ecto.UUID.generate()

    assert {:error, %FlowStone.Error{type: :execution_error}} =
             Scatter.run_inline_reader(asset, %{},
               run_id: run_id,
               partition: :default,
               enqueue: false
             )
  end

  test "missing optional dependencies return clear errors" do
    assert {:error, {:missing_dependency, :ex_aws_s3}} =
             S3.init(%{s3_module: MissingExAwsS3}, %{})

    assert {:error, {:missing_dependency, :ex_aws_dynamo}} =
             DynamoDB.init(
               %{dynamo_module: MissingExAwsDynamo},
               %{}
             )
  end
end
