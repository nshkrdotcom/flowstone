defmodule FlowStone.Scatter.BatcherTest do
  use FlowStone.TestCase, isolation: :full_isolation

  alias FlowStone.Scatter.{Batcher, BatchOptions}

  describe "BatchOptions" do
    test "new/0 creates default options" do
      opts = BatchOptions.new()

      assert opts.max_items_per_batch == 10
      assert opts.max_bytes_per_batch == nil
      assert opts.size_fn == nil
      assert opts.group_by == nil
      assert opts.max_items_per_group == nil
      assert opts.batch_fn == nil
      assert opts.batch_input == nil
      assert opts.on_item_error == :fail_batch
    end

    test "new/1 accepts custom options" do
      opts = BatchOptions.new(max_items_per_batch: 20, on_item_error: :collect_errors)

      assert opts.max_items_per_batch == 20
      assert opts.on_item_error == :collect_errors
    end

    test "to_map/1 and from_map/1 round-trip correctly" do
      opts =
        BatchOptions.new(
          max_items_per_batch: 25,
          on_item_error: :fail_batch
        )

      map = BatchOptions.to_map(opts)
      restored = BatchOptions.from_map(map)

      assert restored.max_items_per_batch == 25
      assert restored.on_item_error == :fail_batch
    end

    test "validates max_items_per_batch is positive" do
      assert_raise ArgumentError, fn ->
        BatchOptions.new(max_items_per_batch: 0)
      end
    end
  end

  describe "Batcher.batch/2 with fixed size" do
    test "batches items by max_items_per_batch" do
      items = [%{id: 1}, %{id: 2}, %{id: 3}, %{id: 4}, %{id: 5}]
      opts = BatchOptions.new(max_items_per_batch: 2)

      batches = Batcher.batch(items, opts)

      assert length(batches) == 3
      assert Enum.at(batches, 0) == [%{id: 1}, %{id: 2}]
      assert Enum.at(batches, 1) == [%{id: 3}, %{id: 4}]
      assert Enum.at(batches, 2) == [%{id: 5}]
    end

    test "handles empty items list" do
      batches = Batcher.batch([], BatchOptions.new())

      assert batches == []
    end

    test "handles items less than batch size" do
      items = [%{id: 1}, %{id: 2}]
      opts = BatchOptions.new(max_items_per_batch: 10)

      batches = Batcher.batch(items, opts)

      assert length(batches) == 1
      assert Enum.at(batches, 0) == [%{id: 1}, %{id: 2}]
    end
  end

  describe "Batcher.batch/2 with size-based batching" do
    test "batches items by max_bytes_per_batch" do
      items = [
        %{id: 1, data: "small"},
        %{id: 2, data: "medium data here"},
        %{id: 3, data: "x"},
        %{id: 4, data: "another item"}
      ]

      size_fn = fn item -> byte_size(item.data) end
      opts = BatchOptions.new(max_bytes_per_batch: 20, size_fn: size_fn)

      batches = Batcher.batch(items, opts)

      # First batch: "small" (5) + "medium data here" (16) = 21 > 20, so just "small"
      # Second batch: "medium data here" (16) + "x" (1) = 17 <= 20
      # Third batch: "another item" (12)
      assert length(batches) >= 2
    end

    test "single item exceeding max_bytes becomes its own batch" do
      items = [
        %{id: 1, data: "small"},
        %{id: 2, data: String.duplicate("x", 100)},
        %{id: 3, data: "tiny"}
      ]

      size_fn = fn item -> byte_size(item.data) end
      opts = BatchOptions.new(max_bytes_per_batch: 20, size_fn: size_fn)

      batches = Batcher.batch(items, opts)

      # The large item should be in its own batch
      large_batch =
        Enum.find(batches, fn batch ->
          Enum.any?(batch, fn item -> item.id == 2 end)
        end)

      assert length(large_batch) == 1
    end
  end

  describe "Batcher.batch/2 with group_by" do
    test "groups items before batching" do
      items = [
        %{region: "us", id: 1},
        %{region: "eu", id: 2},
        %{region: "us", id: 3},
        %{region: "eu", id: 4},
        %{region: "us", id: 5}
      ]

      group_fn = fn item -> item.region end
      opts = BatchOptions.new(group_by: group_fn, max_items_per_group: 2)

      batches = Batcher.batch(items, opts)

      # Should create batches respecting groups
      # us: [1, 3, 5] -> batches of 2: [1, 3], [5]
      # eu: [2, 4] -> batch: [2, 4]
      assert length(batches) >= 2
    end

    test "respects max_items_per_group" do
      items = Enum.map(1..10, fn i -> %{group: :a, id: i} end)

      group_fn = fn item -> item.group end
      opts = BatchOptions.new(group_by: group_fn, max_items_per_group: 3)

      batches = Batcher.batch(items, opts)

      Enum.each(batches, fn batch ->
        assert length(batch) <= 3
      end)
    end
  end

  describe "Batcher.batch/2 with custom batch_fn" do
    test "uses custom batching function" do
      items = [%{id: 1}, %{id: 2}, %{id: 3}, %{id: 4}]

      # Custom function that creates batches of odd and even ids
      batch_fn = fn items_list ->
        {odds, evens} = Enum.split_with(items_list, fn item -> rem(item.id, 2) == 1 end)
        [odds, evens]
      end

      opts = BatchOptions.new(batch_fn: batch_fn)

      batches = Batcher.batch(items, opts)

      assert length(batches) == 2
      assert Enum.at(batches, 0) == [%{id: 1}, %{id: 3}]
      assert Enum.at(batches, 1) == [%{id: 2}, %{id: 4}]
    end
  end

  describe "Batcher.batch/2 filters empty batches" do
    test "removes empty batches from result" do
      items = [%{id: 1}, %{id: 2}]

      # Custom function that might produce empty batches
      batch_fn = fn items_list ->
        [items_list, [], []]
      end

      opts = BatchOptions.new(batch_fn: batch_fn)

      batches = Batcher.batch(items, opts)

      assert length(batches) == 1
      refute Enum.any?(batches, fn b -> b == [] end)
    end
  end

  describe "Batcher.build_batch_context/4" do
    test "creates context with batch fields" do
      items = [%{id: 1}, %{id: 2}, %{id: 3}]
      batch_input = %{region: "us-east", env: "prod"}

      ctx = Batcher.build_batch_context(items, 2, 5, batch_input)

      assert ctx.batch_index == 2
      assert ctx.batch_count == 5
      assert ctx.batch_items == items
      assert ctx.batch_input == batch_input
    end

    test "generates batch scatter_key" do
      items = [%{id: 1}, %{id: 2}]

      ctx = Batcher.build_batch_context(items, 0, 3, %{})

      assert is_map(ctx.scatter_key)
      assert ctx.scatter_key["_batch"] == true
      assert ctx.scatter_key["index"] == 0
      assert ctx.scatter_key["item_count"] == 2
    end
  end

  describe "Batcher.evaluate_batch_input/2" do
    test "evaluates batch_input function with deps" do
      deps = %{region: %{id: 123, name: "us-east"}}

      batch_input_fn = fn d ->
        %{region_id: d.region.id, region_name: d.region.name}
      end

      result = Batcher.evaluate_batch_input(batch_input_fn, deps)

      assert result == %{region_id: 123, region_name: "us-east"}
    end

    test "returns nil when batch_input is nil" do
      result = Batcher.evaluate_batch_input(nil, %{})

      assert result == nil
    end

    test "returns map directly when batch_input is not a function" do
      batch_input = %{static: "value"}

      result = Batcher.evaluate_batch_input(batch_input, %{})

      assert result == %{static: "value"}
    end
  end
end
