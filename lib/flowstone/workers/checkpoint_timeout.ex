defmodule FlowStone.Workers.CheckpointTimeout do
  @moduledoc """
  Placeholder worker to handle checkpoint timeouts/escalations.
  """

  use Oban.Worker, queue: :checkpoints, max_attempts: 1

  @impl true
  def perform(_job) do
    :ok
  end
end
