defmodule FlowStone.HealthTest do
  use FlowStone.TestCase, isolation: :full_isolation

  test "returns subsystem statuses" do
    status = FlowStone.Health.status()
    assert Map.has_key?(status, :repo)
    assert Map.has_key?(status, :oban)
    assert Map.has_key?(status, :resources)
  end
end
