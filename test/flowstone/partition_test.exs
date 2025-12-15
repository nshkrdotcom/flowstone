defmodule FlowStone.PartitionTest do
  use FlowStone.TestCase, isolation: :full_isolation

  alias FlowStone.Partition

  describe "new tagged format" do
    test "serializes dates with tag" do
      assert Partition.serialize(~D[2024-01-01]) == "d:2024-01-01"
    end

    test "serializes datetimes with tag" do
      assert Partition.serialize(~U[2024-01-01 00:00:00Z]) == "dt:2024-01-01T00:00:00Z"
    end

    test "serializes naive datetimes with tag" do
      ndt = ~N[2024-01-01 12:30:00]
      assert Partition.serialize(ndt) == "ndt:2024-01-01T12:30:00"
    end

    test "serializes tuples with base64-encoded JSON" do
      serialized = Partition.serialize({"tenant", "region", ~D[2024-01-01]})
      assert String.starts_with?(serialized, "t:")
    end

    test "simple strings pass through unchanged" do
      assert Partition.serialize("simple") == "simple"
      assert Partition.serialize("tenant_123") == "tenant_123"
    end

    test "strings with colons are base64 encoded" do
      serialized = Partition.serialize("value:with:colons")
      assert String.starts_with?(serialized, "s:")
    end
  end

  describe "round-trip" do
    test "dates round-trip correctly" do
      date = ~D[2024-01-01]
      assert Partition.deserialize(Partition.serialize(date)) == date
    end

    test "datetimes round-trip correctly" do
      dt = ~U[2024-01-01 00:00:00Z]
      assert Partition.deserialize(Partition.serialize(dt)) == dt
    end

    test "naive datetimes round-trip correctly" do
      ndt = ~N[2024-01-01 12:30:00]
      assert Partition.deserialize(Partition.serialize(ndt)) == ndt
    end

    test "tuples round-trip correctly" do
      tuple = {"tenant", "region", ~D[2024-01-01]}
      assert Partition.deserialize(Partition.serialize(tuple)) == tuple
    end

    test "tuples with dates round-trip correctly" do
      tuple = {~D[2024-01-01], "tenant"}
      assert Partition.deserialize(Partition.serialize(tuple)) == tuple
    end

    test "nested tuples round-trip correctly" do
      tuple = {{"a", "b"}, "c"}
      assert Partition.deserialize(Partition.serialize(tuple)) == tuple
    end

    test "strings containing | round-trip correctly (no collision)" do
      # This was a bug in the old format
      str = "value|with|pipes"
      assert Partition.deserialize(Partition.serialize(str)) == str
    end

    test "strings containing : round-trip correctly" do
      str = "value:with:colons"
      assert Partition.deserialize(Partition.serialize(str)) == str
    end

    test "simple strings round-trip correctly" do
      str = "simple"
      assert Partition.deserialize(Partition.serialize(str)) == str
    end

    test "integers round-trip as strings" do
      # Integers become strings after serialization
      assert Partition.deserialize(Partition.serialize(123)) == "123"
    end

    test "atoms round-trip as strings" do
      # Atoms become strings after serialization
      assert Partition.deserialize(Partition.serialize(:foo)) == "foo"
    end
  end

  describe "legacy format backward compatibility" do
    test "deserializes legacy date format" do
      # Old format without tag
      assert Partition.deserialize("2024-01-01") == ~D[2024-01-01]
    end

    test "deserializes legacy datetime format" do
      # Old format without tag
      assert Partition.deserialize("2024-01-01T00:00:00Z") == ~U[2024-01-01 00:00:00Z]
    end

    test "deserializes legacy tuple format with pipe separator" do
      # Old format using | separator
      assert Partition.deserialize("tenant|region|2024-01-01") ==
               {"tenant", "region", ~D[2024-01-01]}
    end
  end

  describe "edge cases" do
    test "nil serializes to empty string" do
      assert Partition.serialize(nil) == ""
    end

    test "empty string deserializes to nil" do
      assert Partition.deserialize("") == nil
    end

    test "nil deserializes to nil" do
      assert Partition.deserialize(nil) == nil
    end

    test "already structured types pass through deserialize" do
      date = ~D[2024-01-01]
      assert Partition.deserialize(date) == date

      dt = ~U[2024-01-01 00:00:00Z]
      assert Partition.deserialize(dt) == dt

      tuple = {"a", "b"}
      assert Partition.deserialize(tuple) == tuple
    end
  end
end
