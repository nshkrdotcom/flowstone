defmodule FlowStone.PlanRunnerTest do
  use FlowStone.TestCase, isolation: :full_isolation

  alias FlowStone.PlanRunner
  alias Jido.Plan

  defmodule Actions do
    defmodule Source do
      use Jido.Action,
        name: "source",
        description: "Returns a base value"

      @impl true
      def run(params, _context) do
        {:ok, %{value: params.value}}
      end
    end

    defmodule Add do
      use Jido.Action,
        name: "add",
        description: "Adds a value from dependencies"

      @impl true
      def run(params, context) do
        deps = get_in(context, [:flowstone, :deps]) || %{}
        source = Map.get(deps, :source, %{})
        sum = Map.get(source, :value, 0) + Map.get(params, :delta, 0)
        {:ok, %{sum: sum, user_id: context.user_id}}
      end
    end

    defmodule NeedsApproval do
      use Jido.Action,
        name: "needs_approval",
        description: "Requires approval"

      def policy do
        %{approval_class: "high", description: "Sensitive operation"}
      end

      @impl true
      def run(_params, _context) do
        Agent.update(:approval_action_called, fn _ -> true end)
        {:ok, %{ok: true}}
      end
    end
  end

  setup do
    {:ok, _} =
      start_supervised(%{
        id: :approval_action_called,
        start: {Agent, :start_link, [fn -> false end, [name: :approval_action_called]]},
        restart: :temporary
      })

    :ok
  end

  test "runs a plan step with dependency outputs in context" do
    plan =
      Plan.new(context: %{user_id: "user-1"})
      |> Plan.add(:source, {Actions.Source, %{value: 4}})
      |> Plan.add(:add, {Actions.Add, %{delta: 3}}, depends_on: :source)

    assert {:ok, %{sum: 7, user_id: "user-1"}} = PlanRunner.run(plan, :add)
  end

  test "requests approval when policy requires it" do
    plan =
      Plan.new()
      |> Plan.add(:needs_approval, Actions.NeedsApproval)

    assert {:error, %FlowStone.Error{}} = PlanRunner.run(plan, :needs_approval)
    refute Agent.get(:approval_action_called, & &1)

    assert [%{status: :pending, checkpoint_name: "needs_approval"}] =
             FlowStone.Approvals.list_pending()
  end
end
