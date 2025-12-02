defmodule FlowStone.PartitionTest do
  use FlowStone.TestCase, isolation: :full_isolation

  alias FlowStone.Partition

  test "serializes common partition types" do
    assert Partition.serialize(~D[2024-01-01]) == "2024-01-01"
    assert Partition.serialize(~U[2024-01-01 00:00:00Z]) == "2024-01-01T00:00:00Z"
    assert Partition.serialize({"tenant", "region", ~D[2024-01-01]}) == "tenant|region|2024-01-01"
  end

  test "deserializes tuples and dates" do
    assert Partition.deserialize("tenant|region|2024-01-01") ==
             {"tenant", "region", ~D[2024-01-01]}

    assert Partition.deserialize("2024-01-01T00:00:00Z") == ~U[2024-01-01 00:00:00Z]
  end
end
