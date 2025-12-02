defmodule FlowStone.LineageTest do
  use FlowStone.TestCase, isolation: :full_isolation

  setup do
    {:ok, pid} = start_supervised(FlowStone.Lineage)
    %{server: pid}
  end

  test "records upstream dependencies", %{server: server} do
    FlowStone.Lineage.record(:target, :p1, "run", [dep: :p1], server)

    upstream = FlowStone.Lineage.upstream(:target, :p1, server)
    assert Enum.any?(upstream, &match?(%{asset: :dep}, &1))

    downstream = FlowStone.Lineage.downstream(:dep, :p1, server)
    assert Enum.any?(downstream, &match?(%{asset: :target}, &1))
  end
end
