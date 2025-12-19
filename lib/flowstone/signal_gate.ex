defmodule FlowStone.SignalGate do
  @moduledoc """
  Core Signal Gate functionality for durable external suspension.

  Signal Gate enables FlowStone assets to durably suspend execution while
  waiting for external signals (webhooks, callbacks, human approvals).
  Unlike polling-based approaches, Signal Gate consumes zero resources
  while waiting and provides immediate resumption upon signal receipt.

  ## Overview

  1. Asset returns `{:signal_gate, opts}` to enter gate
  2. Gate record created with signed token
  3. Worker exits, no resources held
  4. External system calls webhook with token
  5. Signal processed, downstream triggered

  ## Example

      asset :embedded_documents do
        execute fn ctx, deps ->
          task_id = ECS.start_task(deps.data)
          {:signal_gate, token: task_id, timeout: :timer.hours(1)}
        end

        on_signal fn _ctx, payload ->
          {:ok, payload.result}
        end
      end
  """

  import Ecto.Query
  alias FlowStone.Repo
  alias FlowStone.SignalGate.{Gate, Token}
  alias FlowStone.Workers.SignalGateTimeoutWorker

  @type gate :: Gate.t()

  @doc """
  Create a signal gate for a materialization.

  ## Options

  - `:materialization_id` - The materialization entering gate (required)
  - `:token` - Base token for external service (required)
  - `:timeout` - Timeout in milliseconds (default: 1 hour)
  - `:timeout_action` - :retry | :fail | :cancel (default: :fail)
  - `:max_timeout_retries` - Max retries if timeout_action is :retry (default: 3)
  - `:metadata` - Additional data to store (optional)
  """
  @spec create(keyword()) :: {:ok, gate()} | {:error, term()}
  def create(opts) do
    materialization_id = Keyword.fetch!(opts, :materialization_id)
    base_token = Keyword.fetch!(opts, :token)
    timeout = Keyword.get(opts, :timeout, :timer.hours(1))

    timeout_at = DateTime.add(DateTime.utc_now(), timeout, :millisecond)
    signed_token = Token.generate(base_token, timeout_at)

    attrs = %{
      materialization_id: materialization_id,
      token: signed_token,
      token_hash: Token.hash(signed_token),
      timeout_at: timeout_at,
      timeout_action: Keyword.get(opts, :timeout_action, :fail),
      max_timeout_retries: Keyword.get(opts, :max_timeout_retries, 3),
      metadata: Keyword.get(opts, :metadata, %{})
    }

    case %Gate{}
         |> Gate.create_changeset(attrs)
         |> Repo.insert() do
      {:ok, gate} ->
        schedule_timeout_check(gate)
        emit_telemetry(:create, gate)
        {:ok, gate}

      {:error, _} = error ->
        error
    end
  end

  @doc """
  Receive a signal for a gate.
  Called from webhook controller.

  ## Options

  - `:source_ip` - Source IP of the request
  - `:headers` - Relevant request headers
  """
  @spec receive_signal(String.t(), map(), keyword()) :: {:ok, gate()} | {:error, term()}
  def receive_signal(signed_token, payload, opts \\ []) do
    source_ip = Keyword.get(opts, :source_ip)
    headers = Keyword.get(opts, :headers, %{})

    Repo.transaction(fn ->
      with {:ok, %{token: _base}} <- Token.validate(signed_token),
           token_hash = Token.hash(signed_token),
           {:ok, gate} <- get_gate_by_hash(token_hash),
           :ok <- validate_gate_status(gate) do
        # Update gate with signal
        {:ok, updated} =
          gate
          |> Gate.signal_changeset(payload, source_ip, headers)
          |> Repo.update()

        emit_telemetry(:signal, updated)

        updated
      else
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
  end

  @doc """
  Get a gate by its token (validates signature).
  """
  @spec get_by_token(String.t()) :: {:ok, gate()} | {:error, term()}
  def get_by_token(signed_token) do
    with {:ok, _} <- Token.validate(signed_token) do
      token_hash = Token.hash(signed_token)
      get_gate_by_hash(token_hash)
    end
  end

  @doc """
  Get a gate by ID.
  """
  @spec get(Ecto.UUID.t()) :: {:ok, gate()} | {:error, :not_found}
  def get(gate_id) do
    case Repo.get(Gate, gate_id) do
      nil -> {:error, :not_found}
      gate -> {:ok, gate}
    end
  end

  @doc """
  Get gate by materialization ID.
  """
  @spec get_by_materialization(Ecto.UUID.t()) :: {:ok, gate()} | {:error, :not_found}
  def get_by_materialization(materialization_id) do
    case Repo.get_by(Gate, materialization_id: materialization_id) do
      nil -> {:error, :not_found}
      gate -> {:ok, gate}
    end
  end

  @doc """
  Cancel a waiting gate.
  """
  @spec cancel(gate() | Ecto.UUID.t()) :: {:ok, gate()} | {:error, term()}
  def cancel(gate_or_id) do
    gate = get_gate!(gate_or_id)

    gate
    |> Ecto.Changeset.change(%{status: :cancelled})
    |> Repo.update()
    |> tap(fn {:ok, g} -> emit_telemetry(:cancel, g) end)
  end

  @doc """
  Process expired gates (called by timeout worker).
  """
  @spec process_expired_gates() :: {:ok, non_neg_integer()}
  def process_expired_gates do
    now = DateTime.utc_now()

    gates =
      from(g in Gate,
        where: g.status == :waiting,
        where: g.timeout_at <= ^now
      )
      |> Repo.all()

    for gate <- gates do
      handle_timeout(gate)
    end

    {:ok, length(gates)}
  end

  @doc """
  Handle timeout for a specific gate.
  """
  @spec handle_timeout(gate()) :: {:ok, gate()} | {:error, term()}
  def handle_timeout(gate) do
    case gate.timeout_action do
      :retry when gate.timeout_retries < gate.max_timeout_retries ->
        {:ok, updated} = gate |> Gate.timeout_changeset() |> Repo.update()
        schedule_timeout_check(updated)
        emit_telemetry(:timeout_retry, updated)
        {:ok, updated}

      _ ->
        {:ok, updated} = gate |> Gate.timeout_changeset() |> Repo.update()
        emit_telemetry(:timeout, updated)
        {:ok, updated}
    end
  end

  @doc """
  Generate callback URL for a gate.
  """
  @spec callback_url(gate(), keyword()) :: String.t()
  def callback_url(%Gate{token: token}, opts \\ []) do
    base_url =
      Keyword.get(opts, :base_url) ||
        Application.get_env(:flowstone, :webhook_base_url, "http://localhost:4000")

    path = Keyword.get(opts, :path, "/hooks/flowstone/signal")

    "#{base_url}#{path}/#{URI.encode(token)}"
  end

  @doc """
  List waiting gates (for monitoring).
  """
  @spec list_waiting(keyword()) :: [gate()]
  def list_waiting(opts \\ []) do
    limit = Keyword.get(opts, :limit, 100)

    from(g in Gate,
      where: g.status == :waiting,
      order_by: [asc: g.timeout_at],
      limit: ^limit
    )
    |> Repo.all()
  end

  # Private helpers

  defp get_gate_by_hash(token_hash) do
    case Repo.get_by(Gate, token_hash: token_hash) do
      nil -> {:error, :not_found}
      gate -> {:ok, gate}
    end
  end

  defp get_gate!(%Gate{} = gate), do: gate
  defp get_gate!(id) when is_binary(id), do: Repo.get!(Gate, id)

  defp validate_gate_status(gate) do
    case gate.status do
      :waiting -> :ok
      :signaled -> {:error, :already_signaled}
      :timeout -> {:error, :expired}
      :cancelled -> {:error, :cancelled}
      :expired -> {:error, :expired}
    end
  end

  defp schedule_timeout_check(gate) do
    delay = DateTime.diff(gate.timeout_at, DateTime.utc_now(), :second)

    if delay > 0 do
      %{gate_id: gate.id}
      |> SignalGateTimeoutWorker.new(schedule_in: max(delay, 1))
      |> Oban.insert()
    end

    :ok
  rescue
    # Oban might not be running in tests
    _ -> :ok
  end

  defp emit_telemetry(event, gate) do
    meta = %{
      gate_id: gate.id,
      materialization_id: gate.materialization_id
    }

    measurements =
      case event do
        :create -> %{timeout_ms: DateTime.diff(gate.timeout_at, DateTime.utc_now(), :millisecond)}
        :signal -> %{wait_duration_ms: Gate.wait_duration_ms(gate)}
        _ -> %{}
      end

    :telemetry.execute([:flowstone, :signal_gate, event], measurements, meta)
  end
end
