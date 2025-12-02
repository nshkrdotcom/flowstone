Ecto.Adapters.SQL.Sandbox.mode(FlowStone.Repo, :manual)

case Application.ensure_all_started(:flowstone) do
  {:ok, _} -> :ok
  {:error, {:already_started, _app}} -> :ok
end

ExUnit.start()
