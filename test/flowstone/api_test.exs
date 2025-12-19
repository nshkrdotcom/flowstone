defmodule FlowStone.APITest do
  @moduledoc """
  Tests for the new FlowStone v0.5.0 simplified API.
  """
  use FlowStone.TestCase, isolation: :full_isolation

  import ExUnit.CaptureLog

  alias FlowStone.API

  # Test pipeline with basic assets
  defmodule BasicPipeline do
    use FlowStone.Pipeline

    asset :greeting do
      execute fn _, _ -> {:ok, "Hello, World!"} end
    end

    asset :numbers do
      execute fn _, _ -> {:ok, [1, 2, 3, 4, 5]} end
    end

    asset :doubled do
      depends_on([:numbers])
      execute fn _, %{numbers: n} -> {:ok, Enum.map(n, &(&1 * 2))} end
    end

    asset :sum do
      depends_on([:doubled])
      execute fn _, %{doubled: n} -> {:ok, Enum.sum(n)} end
    end
  end

  # Test pipeline with partitions
  defmodule PartitionedPipeline do
    use FlowStone.Pipeline

    asset :date_asset do
      execute fn ctx, _ -> {:ok, ctx.partition} end
    end

    asset :partition_data do
      depends_on([:date_asset])
      execute fn _ctx, %{date_asset: d} -> {:ok, "Data for #{d}"} end
    end
  end

  # Test pipeline that fails
  defmodule FailingPipeline do
    use FlowStone.Pipeline

    asset :will_fail do
      execute fn _, _ -> {:error, :intentional_failure} end
    end

    asset :raises do
      execute fn _, _ -> raise "Intentional error" end
    end
  end

  describe "run/2" do
    test "runs asset synchronously with in-memory storage" do
      assert {:ok, "Hello, World!"} = API.run(BasicPipeline, :greeting)
    end

    test "runs asset with dependencies" do
      assert {:ok, 30} = API.run(BasicPipeline, :sum)
    end

    test "returns error for unknown asset" do
      assert {:error, %FlowStone.Error{type: :asset_not_found}} =
               API.run(BasicPipeline, :unknown_asset)
    end

    test "returns error when execute returns error" do
      log =
        capture_log(fn ->
          assert {:error, _reason} = API.run(FailingPipeline, :will_fail)
        end)

      assert log =~ "FlowStone error"
      assert log =~ "will_fail"
    end

    test "handles exceptions in execute function" do
      log =
        capture_log(fn ->
          assert {:error, %FlowStone.Error{type: :execution_error}} =
                   API.run(FailingPipeline, :raises)
        end)

      assert log =~ "FlowStone error"
      assert log =~ "Intentional error"
    end

    test "caches results between runs" do
      # First run
      {:ok, result1} = API.run(BasicPipeline, :greeting)

      # Second run should return cached result
      {:ok, result2} = API.run(BasicPipeline, :greeting)

      assert result1 == result2
    end
  end

  describe "run/3 with partition" do
    test "passes partition to context" do
      assert {:ok, ~D[2025-01-15]} =
               API.run(PartitionedPipeline, :date_asset, partition: ~D[2025-01-15])
    end

    test "different partitions store separate results" do
      {:ok, _} = API.run(PartitionedPipeline, :date_asset, partition: :partition_a)
      {:ok, _} = API.run(PartitionedPipeline, :date_asset, partition: :partition_b)

      assert {:ok, :partition_a} =
               API.get(PartitionedPipeline, :date_asset, partition: :partition_a)

      assert {:ok, :partition_b} =
               API.get(PartitionedPipeline, :date_asset, partition: :partition_b)
    end
  end

  describe "run/3 with force: true" do
    defmodule CounterPipeline do
      use FlowStone.Pipeline

      asset :counter do
        execute fn _, _ ->
          # This will return different values each time
          {:ok, System.unique_integer([:positive])}
        end
      end
    end

    test "re-runs even if cached" do
      {:ok, first_value} = API.run(CounterPipeline, :counter)
      {:ok, cached_value} = API.run(CounterPipeline, :counter)

      # Without force, should return cached
      assert first_value == cached_value

      # With force, should re-run
      {:ok, forced_value} = API.run(CounterPipeline, :counter, force: true)
      assert forced_value != first_value
    end
  end

  describe "run/3 with with_deps: false" do
    test "fails if dependencies not already materialized" do
      # Try to run :sum without running dependencies first
      # The default partition is :default
      assert {:error, %FlowStone.Error{type: :dependency_not_ready}} =
               API.run(BasicPipeline, :sum, with_deps: false)
    end
  end

  describe "get/2" do
    test "retrieves previously run asset" do
      {:ok, _} = API.run(BasicPipeline, :greeting)
      assert {:ok, "Hello, World!"} = API.get(BasicPipeline, :greeting)
    end

    test "returns error if not found" do
      assert {:error, :not_found} = API.get(BasicPipeline, :never_run)
    end
  end

  describe "get/3 with partition" do
    test "retrieves specific partition" do
      {:ok, _} = API.run(PartitionedPipeline, :date_asset, partition: :p1)
      {:ok, _} = API.run(PartitionedPipeline, :date_asset, partition: :p2)

      assert {:ok, :p1} = API.get(PartitionedPipeline, :date_asset, partition: :p1)
      assert {:ok, :p2} = API.get(PartitionedPipeline, :date_asset, partition: :p2)
    end
  end

  describe "exists?/2" do
    test "returns false if asset has not been run" do
      refute API.exists?(BasicPipeline, :greeting)
    end

    test "returns true if asset has been run" do
      {:ok, _} = API.run(BasicPipeline, :greeting)
      assert API.exists?(BasicPipeline, :greeting)
    end
  end

  describe "exists?/3 with partition" do
    test "checks specific partition" do
      {:ok, _} = API.run(PartitionedPipeline, :date_asset, partition: :exists_test)

      assert API.exists?(PartitionedPipeline, :date_asset, partition: :exists_test)
      refute API.exists?(PartitionedPipeline, :date_asset, partition: :other_partition)
    end
  end

  describe "invalidate/2" do
    test "removes cached result" do
      {:ok, _} = API.run(BasicPipeline, :greeting)
      assert API.exists?(BasicPipeline, :greeting)

      {:ok, 1} = API.invalidate(BasicPipeline, :greeting)
      refute API.exists?(BasicPipeline, :greeting)
    end

    test "returns count of invalidated items" do
      {:ok, _} = API.run(BasicPipeline, :greeting)
      assert {:ok, 1} = API.invalidate(BasicPipeline, :greeting)

      # Invalidating non-existent returns 0
      assert {:ok, 0} = API.invalidate(BasicPipeline, :never_existed)
    end
  end

  describe "invalidate/3 with partition" do
    test "invalidates specific partition" do
      {:ok, _} = API.run(PartitionedPipeline, :date_asset, partition: :inv_a)
      {:ok, _} = API.run(PartitionedPipeline, :date_asset, partition: :inv_b)

      {:ok, 1} = API.invalidate(PartitionedPipeline, :date_asset, partition: :inv_a)

      refute API.exists?(PartitionedPipeline, :date_asset, partition: :inv_a)
      assert API.exists?(PartitionedPipeline, :date_asset, partition: :inv_b)
    end
  end

  describe "status/2" do
    test "returns status of completed asset" do
      {:ok, _} = API.run(BasicPipeline, :greeting)

      status = API.status(BasicPipeline, :greeting)
      assert status.state == :completed
      assert status.partition == :default
    end

    test "returns not_found for unrun asset" do
      status = API.status(BasicPipeline, :never_run)
      assert status.state == :not_found
    end
  end

  describe "backfill/3" do
    defmodule BackfillPipeline do
      use FlowStone.Pipeline

      asset :daily do
        execute fn ctx, _ -> {:ok, "data_for_#{ctx.partition}"} end
      end
    end

    test "runs asset for multiple partitions" do
      {:ok, stats} =
        API.backfill(BackfillPipeline, :daily, partitions: [:d1, :d2, :d3])

      assert stats.succeeded == 3
      assert stats.failed == 0

      # Verify all partitions have data
      assert {:ok, "data_for_d1"} = API.get(BackfillPipeline, :daily, partition: :d1)
      assert {:ok, "data_for_d2"} = API.get(BackfillPipeline, :daily, partition: :d2)
      assert {:ok, "data_for_d3"} = API.get(BackfillPipeline, :daily, partition: :d3)
    end

    test "skips already completed partitions unless force: true" do
      # Run one partition first
      {:ok, _} = API.run(BackfillPipeline, :daily, partition: :skip_test_1)

      # Backfill should skip the already-run partition
      {:ok, stats} =
        API.backfill(BackfillPipeline, :daily, partitions: [:skip_test_1, :skip_test_2])

      assert stats.succeeded == 1
      assert stats.skipped == 1
    end

    test "supports parallel execution" do
      {:ok, stats} =
        API.backfill(BackfillPipeline, :daily,
          partitions: [:par1, :par2, :par3, :par4],
          parallel: 2
        )

      assert stats.succeeded == 4
    end
  end

  describe "graph/1" do
    test "returns ASCII DAG representation" do
      graph = API.graph(BasicPipeline)
      assert graph =~ "greeting"
      assert graph =~ "numbers"
      assert graph =~ "doubled"
      assert graph =~ "sum"
    end
  end

  describe "graph/2 with format" do
    test "returns mermaid format" do
      graph = API.graph(BasicPipeline, format: :mermaid)
      assert graph =~ "graph TD" or graph =~ "flowchart"
    end
  end

  describe "assets/1" do
    test "returns list of asset names" do
      assets = API.assets(BasicPipeline)
      assert :greeting in assets
      assert :numbers in assets
      assert :doubled in assets
      assert :sum in assets
    end
  end

  describe "asset_info/2" do
    test "returns detailed asset information" do
      info = API.asset_info(BasicPipeline, :doubled)
      assert info.name == :doubled
      assert info.depends_on == [:numbers]
    end

    test "returns error for unknown asset" do
      assert {:error, :not_found} = API.asset_info(BasicPipeline, :unknown)
    end
  end
end
