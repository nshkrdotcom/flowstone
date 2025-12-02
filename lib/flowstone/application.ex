defmodule FlowStone.Application do
  @moduledoc false
  use Application

  @impl true
  def start(_type, _args) do
    children = [
      # The repo and other runtime services can be added when configured.
      # Keeping the default tree minimal avoids failures when no database
      # is available (common in library/test environments).
    ]

    Supervisor.start_link(children, strategy: :one_for_one, name: FlowStone.Supervisor)
  end
end
