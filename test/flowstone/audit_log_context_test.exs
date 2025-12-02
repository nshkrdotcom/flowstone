defmodule FlowStone.AuditLogContextTest do
  use FlowStone.TestCase, isolation: :full_isolation

  alias FlowStone.{AuditLog, AuditLogContext, Repo}

  test "writes audit events via Repo" do
    assert :ok =
             AuditLogContext.log("asset.materialized",
               actor_id: "user-1",
               actor_type: "user",
               resource_type: "asset",
               resource_id: "demo",
               action: "write",
               details: %{run_id: "123"}
             )

    [entry] = Repo.all(AuditLog)
    assert entry.event_type == "asset.materialized"
    assert entry.actor_id == "user-1"
    assert entry.resource_id == "demo"
  end
end
