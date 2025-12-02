defmodule FlowStone.IOMemoryTest do
  use Supertester.ExUnitFoundation, isolation: :full_isolation

  setup do
    {:ok, _pid} = start_supervised(FlowStone.IO.Memory)
    :ok
  end

  test "stores and loads data" do
    assert :ok = FlowStone.IO.Memory.store(:demo, %{value: 1}, :partition, %{})
    assert {:ok, %{value: 1}} = FlowStone.IO.Memory.load(:demo, :partition, %{})
    assert FlowStone.IO.Memory.exists?(:demo, :partition, %{})
  end

  test "delete removes stored data" do
    assert :ok = FlowStone.IO.Memory.store(:demo, :data, :p1, %{})
    assert :ok = FlowStone.IO.Memory.delete(:demo, :p1, %{})
    assert {:error, :not_found} = FlowStone.IO.Memory.load(:demo, :p1, %{})
  end
end
