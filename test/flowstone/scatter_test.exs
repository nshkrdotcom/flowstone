defmodule FlowStone.ScatterTest do
  use FlowStone.TestCase, isolation: :full_isolation

  alias FlowStone.Scatter
  alias FlowStone.Scatter.{Barrier, Key, Options, Result}

  describe "Key" do
    test "serialize/1 creates consistent JSON output" do
      key = %{url: "https://example.com", page: 1}
      json = Key.serialize(key)

      assert is_binary(json)
      assert json == Key.serialize(key)
    end

    test "serialize/1 sorts keys for consistency" do
      key1 = %{b: 2, a: 1}
      key2 = %{a: 1, b: 2}

      assert Key.serialize(key1) == Key.serialize(key2)
    end

    test "hash/1 generates deterministic hashes" do
      key = %{url: "https://example.com"}

      hash1 = Key.hash(key)
      hash2 = Key.hash(key)

      assert hash1 == hash2
      assert String.length(hash1) == 16
    end

    test "deserialize/1 round-trips correctly" do
      key = %{url: "https://example.com", page: 1}
      json = Key.serialize(key)
      restored = Key.deserialize(json)

      # Keys become strings after JSON round-trip
      assert restored["url"] == "https://example.com"
      assert restored["page"] == 1
    end

    test "normalize/1 converts atom keys to strings" do
      key = %{url: "https://example.com", nested: %{foo: "bar"}}
      normalized = Key.normalize(key)

      assert normalized["url"] == "https://example.com"
      assert normalized["nested"]["foo"] == "bar"
    end

    test "equal?/2 compares keys correctly" do
      key1 = %{a: 1, b: 2}
      key2 = %{b: 2, a: 1}
      key3 = %{a: 1, b: 3}

      assert Key.equal?(key1, key2)
      refute Key.equal?(key1, key3)
    end
  end

  describe "Options" do
    test "new/1 creates default options" do
      opts = Options.new()

      assert opts.max_concurrent == :unlimited
      assert opts.rate_limit == nil
      assert opts.failure_threshold == 0.0
      assert opts.failure_mode == :all_or_nothing
    end

    test "new/1 accepts custom options" do
      opts = Options.new(max_concurrent: 50, failure_threshold: 0.05)

      assert opts.max_concurrent == 50
      assert opts.failure_threshold == 0.05
    end

    test "to_map/1 and from_map/1 round-trip correctly" do
      opts =
        Options.new(
          max_concurrent: 50,
          rate_limit: {10, :second},
          failure_threshold: 0.05,
          failure_mode: :partial
        )

      map = Options.to_map(opts)
      restored = Options.from_map(map)

      assert restored.max_concurrent == 50
      assert restored.rate_limit == {10, :second}
      assert restored.failure_threshold == 0.05
      assert restored.failure_mode == :partial
    end
  end

  describe "Barrier" do
    test "new/1 creates a barrier struct" do
      barrier =
        Barrier.new(
          id: Ecto.UUID.generate(),
          run_id: Ecto.UUID.generate(),
          asset_name: "test_asset",
          total_count: 10
        )

      assert barrier.asset_name == "test_asset"
      assert barrier.total_count == 10
      assert barrier.completed_count == 0
      assert barrier.failed_count == 0
      assert barrier.status == :pending
    end

    test "progress/1 calculates percentage" do
      barrier = Barrier.new(total_count: 100, completed_count: 25, failed_count: 5)

      assert Barrier.progress(barrier) == 30.0
    end

    test "complete?/1 detects completion" do
      incomplete = Barrier.new(total_count: 10, completed_count: 5, failed_count: 0)
      complete = Barrier.new(total_count: 10, completed_count: 8, failed_count: 2)

      refute Barrier.complete?(incomplete)
      assert Barrier.complete?(complete)
    end

    test "failure_rate/1 calculates correctly" do
      barrier = Barrier.new(total_count: 100, completed_count: 0, failed_count: 5)

      assert Barrier.failure_rate(barrier) == 0.05
    end

    test "get_options/1 returns Options struct" do
      opts = Options.new(max_concurrent: 50)
      barrier = Barrier.new(total_count: 10, options: Options.to_map(opts))

      result = Barrier.get_options(barrier)

      assert result.max_concurrent == 50
    end
  end

  describe "Result" do
    test "compress/1 and decompress/1 round-trip" do
      value = %{data: [1, 2, 3], nested: %{key: "value"}}

      compressed = Result.compress(value)
      decompressed = Result.decompress(compressed)

      assert decompressed == value
    end

    test "decompress/1 handles nil" do
      assert Result.decompress(nil) == nil
    end
  end

  describe "Scatter.create_barrier/1" do
    test "creates barrier with result records" do
      run_id = Ecto.UUID.generate()
      scatter_keys = [%{url: "url1"}, %{url: "url2"}, %{url: "url3"}]

      {:ok, barrier} =
        Scatter.create_barrier(
          run_id: run_id,
          asset_name: :test_scatter,
          scatter_keys: scatter_keys
        )

      assert barrier.run_id == run_id
      assert barrier.asset_name == "test_scatter"
      assert barrier.total_count == 3
      assert barrier.status == :executing

      # Check result records were created
      pending_keys = Scatter.pending_keys(barrier.id)
      assert length(pending_keys) == 3
    end

    test "creates barrier with options" do
      run_id = Ecto.UUID.generate()
      opts = Options.new(max_concurrent: 50, failure_threshold: 0.1)

      {:ok, barrier} =
        Scatter.create_barrier(
          run_id: run_id,
          asset_name: :test_scatter,
          scatter_keys: [%{url: "url1"}],
          options: opts
        )

      stored_opts = Barrier.get_options(barrier)
      assert stored_opts.max_concurrent == 50
      assert stored_opts.failure_threshold == 0.1
    end
  end

  describe "Scatter.complete/3" do
    test "records completion and increments count" do
      run_id = Ecto.UUID.generate()
      scatter_keys = [%{url: "url1"}, %{url: "url2"}]

      {:ok, barrier} =
        Scatter.create_barrier(
          run_id: run_id,
          asset_name: :test_scatter,
          scatter_keys: scatter_keys
        )

      {:ok, status} = Scatter.complete(barrier.id, %{url: "url1"}, %{data: "result1"})
      assert status == :continue

      # Check barrier was updated
      {:ok, updated} = Scatter.get_barrier(barrier.id)
      assert updated.completed_count == 1
    end

    test "returns :gather when all complete" do
      run_id = Ecto.UUID.generate()
      scatter_keys = [%{url: "url1"}, %{url: "url2"}]

      {:ok, barrier} =
        Scatter.create_barrier(
          run_id: run_id,
          asset_name: :test_scatter,
          scatter_keys: scatter_keys
        )

      {:ok, :continue} = Scatter.complete(barrier.id, %{url: "url1"}, %{data: "result1"})
      {:ok, :gather} = Scatter.complete(barrier.id, %{url: "url2"}, %{data: "result2"})

      {:ok, updated} = Scatter.get_barrier(barrier.id)
      assert updated.status == :completed
    end
  end

  describe "Scatter.fail/3" do
    test "records failure and increments count" do
      run_id = Ecto.UUID.generate()
      scatter_keys = [%{url: "url1"}, %{url: "url2"}]

      {:ok, barrier} =
        Scatter.create_barrier(
          run_id: run_id,
          asset_name: :test_scatter,
          scatter_keys: scatter_keys,
          options: Options.new(failure_mode: :partial, failure_threshold: 0.5)
        )

      {:ok, :continue} = Scatter.fail(barrier.id, %{url: "url1"}, "error message")

      {:ok, updated} = Scatter.get_barrier(barrier.id)
      assert updated.failed_count == 1
    end

    test "returns error when threshold exceeded" do
      run_id = Ecto.UUID.generate()
      scatter_keys = [%{url: "url1"}, %{url: "url2"}]

      {:ok, barrier} =
        Scatter.create_barrier(
          run_id: run_id,
          asset_name: :test_scatter,
          scatter_keys: scatter_keys,
          options: Options.new(failure_mode: :all_or_nothing)
        )

      # all_or_nothing fails on first failure
      {:ok, result} = Scatter.fail(barrier.id, %{url: "url1"}, "error")
      assert result == {:error, :threshold_exceeded}
    end
  end

  describe "Scatter.gather/1" do
    test "returns all completed results" do
      run_id = Ecto.UUID.generate()
      scatter_keys = [%{url: "url1"}, %{url: "url2"}]

      {:ok, barrier} =
        Scatter.create_barrier(
          run_id: run_id,
          asset_name: :test_scatter,
          scatter_keys: scatter_keys
        )

      Scatter.complete(barrier.id, %{url: "url1"}, %{data: "result1"})
      Scatter.complete(barrier.id, %{url: "url2"}, %{data: "result2"})

      {:ok, results} = Scatter.gather(barrier.id)

      assert map_size(results) == 2
    end
  end

  describe "Scatter.cancel/1" do
    test "cancels barrier and pending results" do
      run_id = Ecto.UUID.generate()
      scatter_keys = [%{url: "url1"}, %{url: "url2"}]

      {:ok, barrier} =
        Scatter.create_barrier(
          run_id: run_id,
          asset_name: :test_scatter,
          scatter_keys: scatter_keys
        )

      {:ok, cancelled} = Scatter.cancel(barrier.id)
      assert cancelled.status == :cancelled
    end
  end

  describe "Scatter.status/1" do
    test "returns status map" do
      run_id = Ecto.UUID.generate()
      scatter_keys = [%{url: "url1"}, %{url: "url2"}, %{url: "url3"}]

      {:ok, barrier} =
        Scatter.create_barrier(
          run_id: run_id,
          asset_name: :test_scatter,
          scatter_keys: scatter_keys
        )

      Scatter.complete(barrier.id, %{url: "url1"}, %{data: "result1"})

      {:ok, status} = Scatter.status(barrier.id)

      assert status.total == 3
      assert status.completed == 1
      assert status.pending == 2
      assert status.failed == 0
    end
  end

  describe "Scatter with batching" do
    import Ecto.Query
    alias FlowStone.Scatter.BatchOptions

    test "create_barrier with batching enabled stores batch metadata" do
      run_id = Ecto.UUID.generate()
      scatter_keys = [%{id: 1}, %{id: 2}, %{id: 3}, %{id: 4}, %{id: 5}]
      batch_opts = BatchOptions.new(max_items_per_batch: 2)

      {:ok, barrier} =
        Scatter.create_barrier(
          run_id: run_id,
          asset_name: :batched_scatter,
          scatter_keys: scatter_keys,
          batch_options: batch_opts
        )

      assert barrier.batching_enabled == true
      assert barrier.batch_count == 3
    end

    test "batched scatter creates batch result records" do
      run_id = Ecto.UUID.generate()
      scatter_keys = [%{id: 1}, %{id: 2}, %{id: 3}, %{id: 4}]
      batch_opts = BatchOptions.new(max_items_per_batch: 2)
      batch_input = %{env: "test"}

      {:ok, barrier} =
        Scatter.create_barrier(
          run_id: run_id,
          asset_name: :batched_scatter,
          scatter_keys: scatter_keys,
          batch_options: batch_opts,
          batch_input: batch_input
        )

      # Should have 2 batch records (4 items / 2 per batch)
      results =
        FlowStone.Repo.all(
          from r in Result,
            where: r.barrier_id == ^barrier.id,
            order_by: [asc: r.scatter_index]
        )

      assert length(results) == 2

      # Each result should have batch metadata
      Enum.each(results, fn result ->
        assert result.batch_index != nil
        assert is_list(result.batch_items)
        assert result.batch_input == %{"env" => "test"}
      end)
    end

    test "complete/3 works with batch keys" do
      run_id = Ecto.UUID.generate()
      scatter_keys = [%{id: 1}, %{id: 2}]
      batch_opts = BatchOptions.new(max_items_per_batch: 2)

      {:ok, barrier} =
        Scatter.create_barrier(
          run_id: run_id,
          asset_name: :batched_scatter,
          scatter_keys: scatter_keys,
          batch_options: batch_opts
        )

      # Get the batch key
      [result] =
        FlowStone.Repo.all(
          from r in Result,
            where: r.barrier_id == ^barrier.id
        )

      batch_key = result.scatter_key

      {:ok, status} = Scatter.complete(barrier.id, batch_key, %{processed: 2})

      assert status == :gather

      {:ok, updated} = Scatter.get_barrier(barrier.id)
      assert updated.completed_count == 1
      assert updated.status == :completed
    end

    test "gather/1 returns batch results" do
      run_id = Ecto.UUID.generate()
      scatter_keys = [%{id: 1}, %{id: 2}, %{id: 3}, %{id: 4}]
      batch_opts = BatchOptions.new(max_items_per_batch: 2)

      {:ok, barrier} =
        Scatter.create_barrier(
          run_id: run_id,
          asset_name: :batched_scatter,
          scatter_keys: scatter_keys,
          batch_options: batch_opts
        )

      # Complete all batches
      results =
        FlowStone.Repo.all(
          from r in Result,
            where: r.barrier_id == ^barrier.id
        )

      Enum.each(results, fn result ->
        Scatter.complete(barrier.id, result.scatter_key, %{
          batch_index: result.batch_index,
          processed: length(result.batch_items)
        })
      end)

      {:ok, gathered} = Scatter.gather(barrier.id)

      # Should have batch results, not per-item results
      assert map_size(gathered) == 2
    end
  end
end
