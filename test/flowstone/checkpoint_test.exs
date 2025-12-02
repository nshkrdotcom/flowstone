defmodule FlowStone.CheckpointTest do
  use FlowStone.TestCase, isolation: :full_isolation

  setup do
    {:ok, _pid} = start_supervised({FlowStone.Checkpoint, name: :checkpoint_test})
    %{server: :checkpoint_test}
  end

  test "creates and lists pending approvals", %{server: server} do
    {:ok, approval} = FlowStone.Checkpoint.request(:quality, %{message: "Review"}, server)
    assert approval.status == :pending
    assert [%{id: id}] = FlowStone.Checkpoint.list_pending(server)
    assert id == approval.id
  end

  test "approves and rejects", %{server: server} do
    {:ok, approval} = FlowStone.Checkpoint.request(:quality, %{}, server)
    :ok = FlowStone.Checkpoint.approve(approval.id, [by: "user"], server)
    assert {:ok, %{status: :approved}} = FlowStone.Checkpoint.get(approval.id, server)

    {:ok, approval2} = FlowStone.Checkpoint.request(:quality, %{}, server)
    :ok = FlowStone.Checkpoint.reject(approval2.id, [reason: "bad"], server)

    assert {:ok, %{status: :rejected, reason: "bad"}} =
             FlowStone.Checkpoint.get(approval2.id, server)
  end

  test "repo-backed approvals update status" do
    {:ok, approval} = FlowStone.Approvals.request(:gate, %{message: "hi"})
    assert approval.status == :pending

    assert :ok = FlowStone.Approvals.approve(approval.id, by: "repo-user")

    assert {:ok, %{status: :approved, decision_by: "repo-user"}} =
             FlowStone.Approvals.get(approval.id)
  end
end
