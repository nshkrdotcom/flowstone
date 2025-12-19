defmodule FlowStone.Workers.SignalGateTimeoutWorker do
  @moduledoc """
  Oban worker that checks for and processes expired signal gates.

  This worker runs on a per-gate schedule to handle timeouts
  at the appropriate time.
  """

  use Oban.Worker,
    queue: :flowstone_system,
    max_attempts: 3

  alias FlowStone.SignalGate

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"gate_id" => gate_id}}) do
    case SignalGate.get(gate_id) do
      {:ok, %{status: :waiting} = gate} ->
        handle_waiting_gate(gate)

      {:ok, _gate} ->
        # Already signaled/cancelled, nothing to do
        :ok

      {:error, :not_found} ->
        # Gate was deleted
        :ok
    end
  end

  defp handle_waiting_gate(gate) do
    if SignalGate.Gate.timed_out?(gate) do
      SignalGate.handle_timeout(gate)
      :ok
    else
      reschedule_or_timeout(gate)
    end
  end

  defp reschedule_or_timeout(gate) do
    delay = DateTime.diff(gate.timeout_at, DateTime.utc_now(), :second)

    if delay > 0 do
      {:snooze, max(delay, 1)}
    else
      SignalGate.handle_timeout(gate)
      :ok
    end
  end
end

defmodule FlowStone.Workers.SignalGateSweeper do
  @moduledoc """
  Periodic sweep for any gates that might have been missed.
  Runs as a safety net to catch gates whose timeout jobs failed.
  """

  use Oban.Worker,
    queue: :flowstone_system,
    max_attempts: 1

  require Logger

  @impl Oban.Worker
  def perform(_job) do
    {:ok, count} = FlowStone.SignalGate.process_expired_gates()

    if count > 0 do
      Logger.info("SignalGateSweeper processed #{count} expired gates")
    end

    :ok
  end
end
