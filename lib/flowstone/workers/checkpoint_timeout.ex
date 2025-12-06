defmodule FlowStone.Workers.CheckpointTimeout do
  @moduledoc """
  Placeholder worker to handle checkpoint timeouts/escalations.
  """

  use Oban.Worker, queue: :checkpoints, max_attempts: 1
  alias FlowStone.Approvals

  @impl true
  def perform(%Oban.Job{args: %{"approval_id" => approval_id}}) do
    case Approvals.get(approval_id) do
      {:ok, %{status: :pending} = approval} ->
        maybe_timeout(approval)

      {:ok, _} ->
        :ok

      {:error, _} ->
        :ok
    end
  end

  defp maybe_timeout(%{timeout_at: nil, id: id}), do: Approvals.timeout(id)

  defp maybe_timeout(%{timeout_at: timeout_at, id: id}) do
    case DateTime.compare(timeout_at, DateTime.utc_now()) do
      :gt ->
        {:snooze, DateTime.diff(timeout_at, DateTime.utc_now(), :second)}

      _ ->
        Approvals.timeout(id)
    end
  end
end
