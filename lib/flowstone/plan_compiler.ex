defmodule FlowStone.PlanCompiler do
  @moduledoc """
  Compiles Jido plans into FlowStone assets.
  """

  alias FlowStone.Asset
  alias FlowStone.Policy
  alias Jido.{Instruction, Plan}
  alias Jido.Plan.PlanInstruction

  @spec compile(Plan.t(), keyword()) :: {:ok, [Asset.t()]} | {:error, term()}
  def compile(plan, opts \\ [])

  def compile(%Plan{} = plan, opts) do
    assets =
      plan.steps
      |> Enum.map(fn {_name, step} -> build_asset(plan, step, opts) end)

    {:ok, assets}
  end

  def compile(other, _opts), do: {:error, {:invalid_plan, other}}

  @doc false
  def execute_instruction(%Instruction{} = instruction, plan_context, step, context, deps, _opts) do
    action = instruction.action
    policy = Policy.from_action(action)

    if Policy.approval_required?(policy) do
      {:wait_for_approval,
       approval_attrs(action, step, context, deps, instruction, Policy.normalize(policy))}
    else
      exec_context = build_action_context(plan_context, instruction.context, context, deps, step)
      Jido.Exec.run(action, instruction.params, exec_context, instruction.opts)
    end
  end

  defp build_asset(%Plan{} = plan, %PlanInstruction{} = step, opts) do
    instruction = step.instruction
    action = instruction.action

    %Asset{
      name: step.name,
      module: __MODULE__,
      line: 0,
      description: action_description(action),
      execute_fn: build_execute_fn(plan, step, instruction, opts),
      depends_on: step.depends_on,
      metadata: build_metadata(plan, step, instruction, opts)
    }
  end

  defp build_execute_fn(plan, step, instruction, opts) do
    plan_context = plan.context || %{}

    fn context, deps ->
      execute_instruction(instruction, plan_context, step, context, deps, opts)
    end
  end

  defp build_metadata(
         %Plan{} = plan,
         %PlanInstruction{} = step,
         %Instruction{} = instruction,
         opts
       ) do
    action = instruction.action

    %{
      plan_id: plan.id,
      plan_version: Keyword.get(opts, :plan_version),
      plan_hash: Keyword.get(opts, :plan_hash),
      plan_ref: Keyword.get(opts, :plan_ref),
      step_id: step.id,
      step_key: step.name,
      action_module: action,
      action_name: action_name(action),
      tool_name: action_tool_name(action),
      instruction_opts: step.opts
    }
  end

  defp build_action_context(plan_context, instruction_context, flow_context, deps, step) do
    base_context =
      plan_context
      |> Map.merge(instruction_context || %{})

    flowstone_context = %{
      asset: step.name,
      deps: deps,
      partition: flow_context.partition,
      run_id: flow_context.run_id,
      trace_id: Map.get(flow_context.metadata, :trace_id),
      work_id: Map.get(flow_context.metadata, :work_id),
      plan_id: Map.get(flow_context.metadata, :plan_id),
      step_id: step.id,
      metadata: flow_context.metadata
    }

    Map.update(base_context, :flowstone, flowstone_context, fn existing ->
      Map.merge(existing, flowstone_context)
    end)
  end

  defp approval_attrs(action, step, context, _deps, instruction, policy) do
    action_name = action_name(action)
    metadata = context.metadata || %{}

    approval_context =
      metadata
      |> Map.merge(%{
        policy: policy,
        description: Map.get(policy, "description") || Map.get(policy, :description),
        action: %{
          name: action_name,
          module: inspect(action)
        },
        step: %{
          key: step.name,
          id: step.id
        },
        plan_id: Map.get(metadata, :plan_id),
        run_id: context.run_id,
        trace_id: Map.get(metadata, :trace_id) || context.run_id,
        work_id: Map.get(metadata, :work_id),
        params: instruction.params
      })

    %{
      message: "Approval required for #{action_name}",
      context: approval_context
    }
  end

  defp action_description(action) do
    if function_exported?(action, :description, 0), do: action.description(), else: nil
  end

  defp action_name(action) do
    if function_exported?(action, :name, 0), do: action.name(), else: inspect(action)
  end

  defp action_tool_name(action) do
    if function_exported?(action, :tool_name, 0), do: action.tool_name(), else: nil
  end
end
