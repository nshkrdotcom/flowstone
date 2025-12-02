defmodule FlowStone.CheckpointTest do
  use Supertester.ExUnitFoundation, isolation: :full_isolation

  setup do
    {:ok, pid} = start_supervised(FlowStone.Checkpoint)
    %{server: pid}
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
end
