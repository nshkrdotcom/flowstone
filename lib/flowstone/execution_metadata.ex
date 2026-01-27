defmodule FlowStone.ExecutionMetadata do
  @moduledoc false

  @spec build(FlowStone.Asset.t(), FlowStone.Context.t(), keyword()) :: map()
  def build(asset, context, opts \\ []) do
    asset_meta = Map.get(asset, :metadata, %{}) || %{}
    context_meta = Map.get(context, :metadata, %{}) || %{}

    %{
      run_id: context.run_id,
      trace_id: coalesce([context_meta[:trace_id], Keyword.get(opts, :trace_id), context.run_id]),
      work_id: coalesce([context_meta[:work_id], Keyword.get(opts, :work_id)]),
      plan_id:
        coalesce([
          asset_meta[:plan_id],
          context_meta[:plan_id],
          Keyword.get(opts, :plan_id)
        ]),
      plan_version:
        coalesce([
          asset_meta[:plan_version],
          context_meta[:plan_version],
          Keyword.get(opts, :plan_version)
        ]),
      plan_hash:
        coalesce([
          asset_meta[:plan_hash],
          context_meta[:plan_hash],
          Keyword.get(opts, :plan_hash)
        ]),
      plan_ref:
        coalesce([
          asset_meta[:plan_ref],
          context_meta[:plan_ref],
          Keyword.get(opts, :plan_ref)
        ]),
      step_id: coalesce([asset_meta[:step_id], context_meta[:step_id]]),
      step_key: coalesce([asset_meta[:step_key], asset.name]),
      action_module: Map.get(asset_meta, :action_module),
      action_name: Map.get(asset_meta, :action_name),
      tool_name: Map.get(asset_meta, :tool_name),
      session_id: coalesce([context_meta[:session_id], Keyword.get(opts, :session_id)]),
      actor_type: coalesce([context_meta[:actor_type], Keyword.get(opts, :actor_type)]),
      actor_id: coalesce([context_meta[:actor_id], Keyword.get(opts, :actor_id)]),
      tenant_id: coalesce([context_meta[:tenant_id], Keyword.get(opts, :tenant_id)])
    }
  end

  defp coalesce([nil | rest]), do: coalesce(rest)
  defp coalesce([value | _rest]), do: value
  defp coalesce([]), do: nil
end
