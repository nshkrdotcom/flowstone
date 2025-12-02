defmodule FlowStone.PubSubTest do
  use FlowStone.TestCase, isolation: :full_isolation

  test "broadcast delivers to subscribers" do
    {:ok, _} = start_supervised({FlowStone.PubSub, name: :ps_test, adapter: Phoenix.PubSub.PG2})
    :ok = FlowStone.PubSub.subscribe("topic", :ps_test)
    FlowStone.PubSub.broadcast("topic", :hello, :ps_test)
    assert_receive :hello
  end
end
