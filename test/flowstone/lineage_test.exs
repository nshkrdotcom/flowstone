defmodule FlowStone.LineageTest do
  use Supertester.ExUnitFoundation, isolation: :full_isolation

  setup do
    {:ok, pid} = start_supervised(FlowStone.Lineage)
    %{server: pid}
  end

  test "records upstream dependencies", %{server: server} do
    FlowStone.Lineage.record(:target, :p1, "run", [dep: :p1], server)

    assert [%{asset: :dep}] = FlowStone.Lineage.upstream(:target, :p1, server)
    assert [%{asset: :target}] = FlowStone.Lineage.downstream(:dep, :p1, server)
  end
end
