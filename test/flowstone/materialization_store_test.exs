defmodule FlowStone.MaterializationStoreTest do
  use FlowStone.TestCase, isolation: :full_isolation

  setup do
    {:ok, _} = start_supervised({FlowStone.MaterializationStore, name: :mat_store})
    :ok
  end

  test "records start/success/failure" do
    :ok = FlowStone.MaterializationStore.record_start(:a, :p, "run", :mat_store)
    assert %{status: :running} = FlowStone.MaterializationStore.get(:a, :p, "run", :mat_store)

    :ok = FlowStone.MaterializationStore.record_success(:a, :p, "run", 10, :mat_store)

    assert %{status: :success, duration_ms: 10} =
             FlowStone.MaterializationStore.get(:a, :p, "run", :mat_store)

    :ok = FlowStone.MaterializationStore.record_failure(:a, :p, "run2", %{}, :mat_store)
    assert %{status: :failed} = FlowStone.MaterializationStore.get(:a, :p, "run2", :mat_store)
  end
end
