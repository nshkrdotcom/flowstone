defmodule FlowStone.Approvals do
  @moduledoc """
  Persistence wrapper for checkpoint approvals (Repo-first, fallback to in-memory checkpoint).
  """

  import Ecto.Query
  alias FlowStone.{Approval, Checkpoint, Repo}

  @default_timeout_seconds 3_600

  @spec request(atom(), map(), keyword()) :: {:ok, Approval.t() | map()} | {:error, term()}
  def request(checkpoint_name, attrs, opts \\ []) do
    if use_repo?(opts) do
      params =
        attrs
        |> Map.put(:checkpoint_name, to_string(checkpoint_name))
        |> Map.put_new(:status, :pending)
        |> Map.put_new(:timeout_at, default_timeout(attrs))

      %Approval{}
      |> Approval.changeset(params)
      |> Repo.insert()
      |> tap(fn
        {:ok, approval} ->
          emit(:requested, approval, opts)
          schedule_timeout(approval)

        _ ->
          :ok
      end)
    else
      server = Keyword.get(opts, :server, Checkpoint)

      with {:ok, approval} = result <- Checkpoint.request(checkpoint_name, attrs, server) do
        emit(:requested, approval, opts)
        result
      end
    end
  end

  @spec approve(binary(), keyword()) :: :ok | {:error, term()}
  def approve(id, opts \\ []) do
    if use_repo?(opts) do
      update_status(id, :approved, opts) |> normalize_status_result()
    else
      server = Keyword.get(opts, :server, Checkpoint)

      with :ok <- Checkpoint.approve(id, opts, server),
           {:ok, approval} <- Checkpoint.get(id, server) do
        emit(:approved, approval, opts)
        :ok
      end
    end
  end

  @spec reject(binary(), keyword()) :: :ok | {:error, term()}
  def reject(id, opts \\ []) do
    if use_repo?(opts) do
      update_status(id, :rejected, opts) |> normalize_status_result()
    else
      server = Keyword.get(opts, :server, Checkpoint)

      with :ok <- Checkpoint.reject(id, opts, server),
           {:ok, approval} <- Checkpoint.get(id, server) do
        emit(:rejected, approval, opts)
        :ok
      end
    end
  end

  @spec timeout(binary(), keyword()) :: :ok | {:error, term()}
  def timeout(id, opts \\ []) do
    if use_repo?(opts) do
      update_status(id, :expired, opts) |> normalize_status_result()
    else
      {:error, :not_supported}
    end
  end

  @spec get(binary(), keyword()) :: {:ok, Approval.t()} | {:error, term()}
  def get(id, opts \\ []) do
    if use_repo?(opts) do
      case Repo.get(Approval, id) do
        nil -> {:error, :not_found}
        approval -> {:ok, approval}
      end
    else
      server = Keyword.get(opts, :server, Checkpoint)
      Checkpoint.get(id, server)
    end
  end

  @spec list_pending(keyword()) :: [Approval.t()] | list()
  def list_pending(opts \\ []) do
    if use_repo?(opts) do
      Repo.all(from a in Approval, where: a.status == :pending)
    else
      server = Keyword.get(opts, :server, Checkpoint)
      Checkpoint.list_pending(server)
    end
  end

  defp update_status(id, status, opts) do
    attrs = %{
      status: status,
      decision_by: Keyword.get(opts, :by),
      decision_at: DateTime.utc_now(),
      reason: Keyword.get(opts, :reason)
    }

    case Repo.get(Approval, id) do
      nil ->
        {:error, :not_found}

      approval ->
        approval
        |> Approval.changeset(attrs)
        |> Repo.update()
        |> case do
          {:ok, updated} ->
            emit(status_event(status), updated, opts)
            {:ok, updated}

          {:error, reason} ->
            {:error, reason}
        end
    end
  end

  defp normalize_status_result({:ok, _approval}), do: :ok
  defp normalize_status_result(other), do: other

  defp status_event(:expired), do: :timeout
  defp status_event(status), do: status

  defp schedule_timeout(%Approval{timeout_at: nil}), do: :ok

  defp schedule_timeout(%Approval{timeout_at: timeout_at} = approval) do
    if oban_running?() do
      %{"approval_id" => approval.id}
      |> FlowStone.Workers.CheckpointTimeout.new(scheduled_at: timeout_at)
      |> Oban.insert()
    else
      :ok
    end
  end

  defp emit(event, approval, opts) do
    telemetry(event, approval)
    notify(event, approval, opts)
  end

  defp use_repo?(opts), do: Keyword.get(opts, :use_repo, true) and repo_running?()

  defp repo_running?,
    do: Application.get_env(:flowstone, :start_repo, false) and Process.whereis(Repo) != nil

  defp oban_running?,
    do: Process.whereis(Oban.Registry) != nil and Process.whereis(Oban.Config) != nil

  defp notify(event, approval, opts) do
    notifier = Keyword.get(opts, :notifier, FlowStone.Checkpoint.Notifier)

    cond do
      is_nil(notifier) -> :ok
      function_exported?(notifier, :notify, 2) -> notifier.notify(event, %{approval: approval})
      true -> :ok
    end
  end

  defp telemetry(event, approval) do
    :telemetry.execute([:flowstone, :checkpoint, event], %{}, %{
      approval_id: Map.get(approval, :id),
      checkpoint: Map.get(approval, :checkpoint_name),
      status: Map.get(approval, :status)
    })
  end

  defp default_timeout(attrs) do
    Map.get(attrs, :timeout_at) ||
      DateTime.add(DateTime.utc_now(), @default_timeout_seconds, :second)
  end
end
