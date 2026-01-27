defmodule FlowStone.Handlers.AgenticHandler do
  @moduledoc """
  Handler for agentic steps that delegate to Synapse for multi-agent coordination.

  When a FlowStone step has `type: :agentic`, this handler:

  1. Builds a delegation request from the step definition and context
  2. Delegates to `Synapse.coordinate/3` for multi-agent coordination
  3. Processes the result back into FlowStone step outputs

  ## Step Definition

      %FlowStone.Step{
        id: "review-code-changes",
        type: :agentic,
        synapse_spec: %{
          coordinator: :code_review_coordinator,
          agents: [:reviewer_agent, :security_agent],
          max_iterations: 5,
          consensus_threshold: 0.8,
          escalation_policy: :on_no_consensus
        },
        inputs: [:code_diff, :requirements],
        outputs: [:review_result, :approval_status],
        timeout_ms: 300_000
      }

  ## Result Handling

    * `{:ok, result}` - Outputs stored in step context
    * `{:escalate, result}` - Triggers FlowStone approval gate
    * `{:timeout, result}` - Handled per step `timeout_policy`
    * `{:error, reason}` - Step transitions to failed
  """

  @doc """
  Execute an agentic step by delegating to Synapse.

  ## Parameters

    * `step` - Step definition with synapse_spec
    * `context` - Execution context with run_id, inputs, resources, elapsed_ms

  ## Returns

    * `{:ok, outputs}` - Step outputs from successful coordination
    * `{:escalate, result}` - Escalation result for approval gate
    * `{:timeout, result}` - Timeout result with partial outputs
    * `{:error, reason}` - Error reason
  """
  @spec execute(map(), map()) ::
          {:ok, map()}
          | {:escalate, map()}
          | {:timeout, map()}
          | {:error, term()}
  def execute(step, context) do
    synapse_module = Map.get(context, :synapse_module, Synapse)
    {spec, inputs, delegation_context} = build_delegation_request(step, context)

    case synapse_module.coordinate(spec, inputs, delegation_context) do
      {:ok, result} ->
        {:ok, result.outputs}

      {:escalate, result} ->
        {:escalate, result}

      {:timeout, result} ->
        {:timeout, result}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # Build delegation parameters from step and context
  defp build_delegation_request(step, context) do
    spec = step.synapse_spec

    # Collect inputs from context
    input_keys = Map.get(step, :inputs, [])

    inputs =
      if is_list(input_keys) do
        input_keys
        |> Enum.into(%{}, fn key ->
          {key, get_in(context, [:inputs, key])}
        end)
      else
        Map.get(context, :inputs, %{})
      end

    # Calculate timeout remaining
    step_timeout = Map.get(step, :timeout_ms, 300_000)
    elapsed = Map.get(context, :elapsed_ms, 0)
    timeout_remaining = max(step_timeout - elapsed, 0)

    # Build delegation context with resources and timeout
    delegation_context =
      Map.get(context, :resources, %{})
      |> Map.merge(%{
        run_id: Map.get(context, :run_id),
        step_id: Map.get(step, :id),
        timeout_remaining_ms: timeout_remaining
      })

    # Merge any mock/test configuration from context
    delegation_context =
      context
      |> Map.take([:test_mode, :mock_responses, :coordinate_mock, :synapse_module])
      |> Map.merge(delegation_context)

    {spec, inputs, delegation_context}
  end
end
