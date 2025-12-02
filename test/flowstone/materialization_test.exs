defmodule FlowStone.MaterializationTest do
  use Supertester.ExUnitFoundation, isolation: :full_isolation

  test "materialization changeset validates required fields" do
    attrs = %{
      asset_name: "demo",
      partition: "p1",
      run_id: Ecto.UUID.generate(),
      status: :pending
    }

    changeset = FlowStone.Materialization.changeset(%FlowStone.Materialization{}, attrs)

    assert changeset.valid?
  end
end
