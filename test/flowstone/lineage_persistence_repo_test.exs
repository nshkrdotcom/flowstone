defmodule FlowStone.LineagePersistenceRepoTest do
  use FlowStone.TestCase, isolation: :full_isolation

  alias FlowStone.LineagePersistence
  alias FlowStone.Materializations

  test "recursive upstream/downstream and impact use Repo" do
    run_root = Ecto.UUID.generate()
    run_dep = Ecto.UUID.generate()
    run_target = Ecto.UUID.generate()

    Materializations.record_start(:root, "p1", run_root)
    Materializations.record_success(:root, "p1", run_root, 1)

    Materializations.record_start(:dep, "p1", run_dep)
    Materializations.record_success(:dep, "p1", run_dep, 1)

    Materializations.record_start(:target, "p1", run_target)
    Materializations.record_success(:target, "p1", run_target, 1)

    assert :ok = LineagePersistence.record(:target, "p1", run_target, [{:dep, "p1"}])
    assert :ok = LineagePersistence.record(:dep, "p1", run_dep, [{:root, "p1"}])

    upstream = LineagePersistence.upstream(:target, "p1")
    assert Enum.any?(upstream, &(&1.asset == :dep and &1.partition == "p1" and &1.depth == 1))
    assert Enum.any?(upstream, &(&1.asset == :root and &1.partition == "p1" and &1.depth == 2))

    downstream = LineagePersistence.downstream(:root, "p1")
    assert Enum.any?(downstream, &(&1.asset == :dep and &1.depth == 1))
    assert Enum.any?(downstream, &(&1.asset == :target and &1.depth == 2))

    impact = LineagePersistence.impact(:root, "p1")
    assert Enum.any?(impact, &(&1.asset == :target and &1.status == :success))
  end
end
