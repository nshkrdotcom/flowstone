defmodule FlowStone.RunIndex.Adapters.Noop do
  @moduledoc false

  @behaviour FlowStone.RunIndex.Adapter

  @impl true
  def write_run(_attrs, _opts), do: :ok

  @impl true
  def write_step(_attrs, _opts), do: :ok
end
