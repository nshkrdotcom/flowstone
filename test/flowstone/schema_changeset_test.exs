defmodule FlowStone.SchemaChangesetTest do
  use FlowStone.TestCase, isolation: :full_isolation

  test "materialization changeset" do
    attrs = %{asset_name: "a", run_id: Ecto.UUID.generate(), status: :pending}

    assert %{valid?: true} =
             FlowStone.Materialization.changeset(%FlowStone.Materialization{}, attrs)
  end

  test "approval changeset" do
    attrs = %{checkpoint_name: "check", status: :pending}
    assert %{valid?: true} = FlowStone.Approval.changeset(%FlowStone.Approval{}, attrs)
  end

  test "lineage entry changeset" do
    attrs = %{
      asset_name: "a",
      upstream_asset: "b",
      consumed_at: DateTime.utc_now()
    }

    assert %{valid?: true} = FlowStone.Lineage.Entry.changeset(%FlowStone.Lineage.Entry{}, attrs)
  end

  test "audit log changeset" do
    attrs = %{event_type: "event", actor_id: "user", actor_type: "system"}
    assert %{valid?: true} = FlowStone.AuditLog.changeset(%FlowStone.AuditLog{}, attrs)
  end
end
