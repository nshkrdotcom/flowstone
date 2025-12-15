defmodule FlowStone.MaterializationStoreTest do
  use FlowStone.TestCase, isolation: :full_isolation

  alias FlowStone.MaterializationStore

  setup do
    {:ok, _} = start_supervised({MaterializationStore, name: :mat_store_test})
    :ok
  end

  test "records start/success/failure" do
    :ok = MaterializationStore.record_start(:a, :p, "run", :mat_store_test)
    assert %{status: :running} = MaterializationStore.get(:a, :p, "run", :mat_store_test)

    :ok = MaterializationStore.record_success(:a, :p, "run", 10, :mat_store_test)

    assert %{status: :success, duration_ms: 10} =
             MaterializationStore.get(:a, :p, "run", :mat_store_test)

    :ok = MaterializationStore.record_failure(:a, :p, "run2", %{}, :mat_store_test)
    assert %{status: :failed} = MaterializationStore.get(:a, :p, "run2", :mat_store_test)
  end
end
