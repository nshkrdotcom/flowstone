defmodule FlowStone.PlanCompilerTest do
  use ExUnit.Case, async: true

  alias FlowStone.PlanCompiler
  alias Jido.Plan

  defmodule Actions do
    defmodule Fetch do
      use Jido.Action,
        name: "fetch",
        description: "Fetches a value"

      @impl true
      def run(params, _context) do
        {:ok, %{value: params.value}}
      end
    end

    defmodule Double do
      use Jido.Action,
        name: "double",
        description: "Doubles a value"

      @impl true
      def run(params, _context) do
        {:ok, %{value: params.value * 2}}
      end
    end
  end

  test "compiles plan steps into assets with dependencies and metadata" do
    plan =
      Plan.new(context: %{user_id: "user-1"})
      |> Plan.add(:fetch, {Actions.Fetch, %{value: 2}})
      |> Plan.add(:double, Actions.Double, depends_on: :fetch)

    assert {:ok, assets} = PlanCompiler.compile(plan)

    fetch = Enum.find(assets, &(&1.name == :fetch))
    double = Enum.find(assets, &(&1.name == :double))

    assert fetch.depends_on == []
    assert fetch.metadata.plan_id == plan.id
    assert fetch.metadata.step_id == plan.steps[:fetch].id
    assert fetch.metadata.action_module == Actions.Fetch

    assert double.depends_on == [:fetch]
    assert is_function(double.execute_fn, 2)
  end
end
