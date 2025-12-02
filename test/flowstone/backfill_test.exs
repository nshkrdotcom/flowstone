defmodule FlowStone.BackfillTest do
  use FlowStone.TestCase, isolation: :full_isolation

  test "generates date range partitions" do
    start_d = ~D[2024-01-01]
    end_d = ~D[2024-01-03]

    assert FlowStone.Backfill.generate(start_partition: start_d, end_partition: end_d) ==
             [~D[2024-01-01], ~D[2024-01-02], ~D[2024-01-03]]
  end

  test "raises when missing options" do
    assert_raise ArgumentError, fn -> FlowStone.Backfill.generate([]) end
  end

  test "uses partition_fn to generate partitions" do
    fun = fn _opts -> [:a, :b] end
    assert FlowStone.Backfill.generate(partition_fn: fun) == [:a, :b]
  end
end
