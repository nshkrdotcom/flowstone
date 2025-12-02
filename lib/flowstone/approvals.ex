defmodule FlowStone.Approvals do
  @moduledoc """
  Persistence wrapper for checkpoint approvals (Repo-first, fallback to in-memory checkpoint).
  """

  import Ecto.Query
  alias FlowStone.{Approval, Checkpoint, Repo}

  @spec request(atom(), map(), keyword()) :: {:ok, Approval.t() | map()} | {:error, term()}
  def request(checkpoint_name, attrs, opts \\ []) do
    if use_repo?(opts) do
      params =
        attrs
        |> Map.put(:checkpoint_name, to_string(checkpoint_name))
        |> Map.put_new(:status, :pending)

      %Approval{}
      |> Approval.changeset(params)
      |> Repo.insert()
      |> tap(fn
        {:ok, approval} -> notify(:requested, approval, opts)
        _ -> :ok
      end)
    else
      server = Keyword.get(opts, :server, Checkpoint)
      Checkpoint.request(checkpoint_name, attrs, server)
    end
  end

  @spec approve(binary(), keyword()) :: :ok | {:error, term()}
  def approve(id, opts \\ []) do
    if use_repo?(opts) do
      update_status(id, :approved, opts)
    else
      server = Keyword.get(opts, :server, Checkpoint)
      Checkpoint.approve(id, opts, server)
    end
  end

  @spec reject(binary(), keyword()) :: :ok | {:error, term()}
  def reject(id, opts \\ []) do
    if use_repo?(opts) do
      update_status(id, :rejected, opts)
    else
      server = Keyword.get(opts, :server, Checkpoint)
      Checkpoint.reject(id, opts, server)
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
            notify(status, updated, opts)
            :ok

          {:error, reason} ->
            {:error, reason}
        end
    end
  end

  defp use_repo?(opts), do: Keyword.get(opts, :use_repo, true) and repo_running?()

  defp repo_running?,
    do: Application.get_env(:flowstone, :start_repo, false) and Process.whereis(Repo) != nil

  defp notify(event, approval, opts) do
    notifier = Keyword.get(opts, :notifier, FlowStone.Checkpoint.Notifier)

    if function_exported?(notifier, :notify, 2) do
      notifier.notify(event, %{approval: approval})
    else
      :ok
    end
  end
end
