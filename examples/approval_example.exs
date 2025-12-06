defmodule Examples.ApprovalExample do
  @moduledoc false

  def run do
    ensure_started(FlowStone.Registry, name: :examples_approval_registry)
    ensure_started(FlowStone.IO.Memory, name: :examples_approval_io)

    FlowStone.register(Pipeline, registry: :examples_approval_registry)

    FlowStone.materialize(:gated,
      partition: :await,
      registry: :examples_approval_registry,
      io: [config: %{agent: :examples_approval_io}],
      resource_server: nil
    )

    FlowStone.ObanHelpers.drain()

    pending = FlowStone.Approvals.list_pending()

    Enum.each(pending, fn approval ->
      FlowStone.Approvals.approve(approval.id, by: "demo@example.com")
    end)

    final =
      Enum.map(pending, fn approval ->
        {approval.id, FlowStone.Approvals.get(approval.id)}
      end)

    %{pending: pending, final: final}
  end

  defp ensure_started(mod, opts) do
    case Process.whereis(opts[:name]) do
      nil -> mod.start_link(opts)
      pid when is_pid(pid) -> {:ok, pid}
    end
  end

  defmodule Pipeline do
    use FlowStone.Pipeline

    asset :gated do
      execute fn _ctx, _deps ->
        {:wait_for_approval,
         %{
           message: "Approve gated asset",
           context: %{requested_by: "example"},
           timeout_at: DateTime.add(DateTime.utc_now(), 300, :second)
         }}
      end
    end
  end
end
