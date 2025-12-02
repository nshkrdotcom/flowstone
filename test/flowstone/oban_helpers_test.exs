defmodule FlowStone.ObanHelpersTest do
  use FlowStone.TestCase, isolation: :full_isolation

  test "drains queues without error" do
    result = FlowStone.ObanHelpers.drain()
    assert is_map(result)
  end
end
