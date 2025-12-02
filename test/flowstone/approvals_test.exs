defmodule FlowStone.ApprovalsTest do
  use FlowStone.TestCase, isolation: :full_isolation

  setup do
    {:ok, _} = start_supervised({FlowStone.Checkpoint, name: :checkpoint_approvals})
    :ok
  end

  test "falls back to checkpoint server when repo not running" do
    opts = [server: :checkpoint_approvals, use_repo: false]

    {:ok, approval} =
      FlowStone.Approvals.request(:check, %{message: "m"}, opts)

    assert approval.status == :pending

    assert :ok = FlowStone.Approvals.approve(approval.id, Keyword.merge(opts, by: "user"))
    assert {:ok, %{status: :approved}} = FlowStone.Approvals.get(approval.id, opts)
    assert [] == FlowStone.Approvals.list_pending(opts)
  end

  test "persists approvals via Repo by default" do
    {:ok, approval} = FlowStone.Approvals.request(:gate, %{message: "hi"})

    assert approval.status == :pending

    assert :ok = FlowStone.Approvals.reject(approval.id, by: "user", reason: "nope")
    assert {:ok, %{status: :rejected, decision_by: "user"}} = FlowStone.Approvals.get(approval.id)
    assert [] == FlowStone.Approvals.list_pending()
  end
end
