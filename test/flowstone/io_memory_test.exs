defmodule FlowStone.IOMemoryTest do
  use FlowStone.TestCase, isolation: :full_isolation

  alias FlowStone.IO.Memory

  setup do
    {:ok, _pid} = start_supervised(Memory)
    :ok
  end

  test "stores and loads data" do
    assert :ok = Memory.store(:demo, %{value: 1}, :partition, %{})
    assert {:ok, %{value: 1}} = Memory.load(:demo, :partition, %{})
    assert Memory.exists?(:demo, :partition, %{})
  end

  test "delete removes stored data" do
    assert :ok = Memory.store(:demo, :data, :p1, %{})
    assert :ok = Memory.delete(:demo, :p1, %{})
    assert {:error, :not_found} = Memory.load(:demo, :p1, %{})
  end
end
