defmodule Examples.PlanRunnerExample do
  @moduledoc false

  alias FlowStone.PlanRunner
  alias Jido.Plan

  def run do
    plan =
      Plan.new(context: %{user_id: "user-1"})
      |> Plan.add(:source, {Actions.Source, %{value: 3}})
      |> Plan.add(:double, Actions.Double, depends_on: :source)

    PlanRunner.run(plan, :double)
  end

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

    defmodule Double do
      use Jido.Action,
        name: "double",
        description: "Doubles a value from dependencies"

      @impl true
      def run(_params, context) do
        deps = get_in(context, [:flowstone, :deps]) || %{}
        source = Map.get(deps, :source, %{})
        value = Map.get(source, :value, 0)
        {:ok, %{double: value * 2, user_id: context.user_id}}
      end
    end
  end
end
