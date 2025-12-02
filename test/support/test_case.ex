defmodule FlowStone.TestCase do
  @moduledoc """
  Shared ExUnit case that wires Supertester isolation with the Ecto sandbox.
  """

  use ExUnit.CaseTemplate

  using opts do
    isolation = Keyword.get(opts, :isolation, :full_isolation)

    quote do
      use Supertester.ExUnitFoundation, isolation: unquote(isolation)
    end
  end

  setup tags do
    owner = Ecto.Adapters.SQL.Sandbox.start_owner!(FlowStone.Repo, shared: not tags[:async])
    on_exit(fn -> Ecto.Adapters.SQL.Sandbox.stop_owner(owner) end)
    :ok
  end
end
