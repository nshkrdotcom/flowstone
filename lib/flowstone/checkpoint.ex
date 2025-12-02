defmodule FlowStone.Checkpoint do
  @moduledoc """
  In-memory checkpoint manager for approvals.
  """

  use GenServer

  alias FlowStone.Approval

  ## Client
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, :ok, name: name)
  end

  def request(checkpoint_name, attrs, server \\ __MODULE__) do
    GenServer.call(server, {:request, checkpoint_name, attrs})
  end

  def approve(id, opts \\ [], server \\ __MODULE__) do
    GenServer.call(server, {:resolve, id, :approved, opts})
  end

  def reject(id, opts \\ [], server \\ __MODULE__) do
    GenServer.call(server, {:resolve, id, :rejected, opts})
  end

  def list_pending(server \\ __MODULE__) do
    GenServer.call(server, :pending)
  end

  def get(id, server \\ __MODULE__) do
    GenServer.call(server, {:get, id})
  end

  ## Server
  @impl true
  def init(:ok) do
    {:ok, %{approvals: %{}}}
  end

  @impl true
  def handle_call({:request, checkpoint, attrs}, _from, state) do
    id = Ecto.UUID.generate()

    approval = %Approval{
      id: id,
      checkpoint_name: checkpoint,
      status: :pending,
      message: attrs[:message],
      context: attrs[:context],
      timeout_at: attrs[:timeout_at] || DateTime.add(DateTime.utc_now(), 3_600, :second)
    }

    approvals = Map.put(state.approvals, id, approval)
    {:reply, {:ok, approval}, %{state | approvals: approvals}}
  end

  def handle_call({:resolve, id, status, opts}, _from, state) do
    case Map.fetch(state.approvals, id) do
      {:ok, approval} ->
        updated =
          %{
            approval
            | status: status,
              decision_by: opts[:by],
              decision_at: DateTime.utc_now(),
              reason: opts[:reason]
          }

        {:reply, :ok, %{state | approvals: Map.put(state.approvals, id, updated)}}

      :error ->
        {:reply, {:error, :not_found}, state}
    end
  end

  def handle_call(:pending, _from, state) do
    pending =
      state.approvals
      |> Map.values()
      |> Enum.filter(&(&1.status == :pending))

    {:reply, pending, state}
  end

  def handle_call({:get, id}, _from, state) do
    {:reply, Map.fetch(state.approvals, id), state}
  end
end
