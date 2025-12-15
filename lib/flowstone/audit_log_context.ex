defmodule FlowStone.AuditLogContext do
  @moduledoc """
  Repo-backed audit log writer with no-op fallback.
  """

  alias FlowStone.{AuditLog, Repo}

  def log(event_type, opts \\ []) do
    entry = %{
      event_type: event_type,
      actor_id: opts[:actor_id] || "system",
      actor_type: opts[:actor_type] || "system",
      resource_type: opts[:resource_type],
      resource_id: opts[:resource_id],
      action: opts[:action],
      details: opts[:details] || %{},
      correlation_id: opts[:correlation_id],
      client_ip: opts[:client_ip],
      user_agent: opts[:user_agent],
      inserted_at: DateTime.utc_now()
    }

    if use_repo?(opts) do
      %AuditLog{}
      |> AuditLog.changeset(entry)
      |> Repo.insert()
      |> case do
        {:ok, _} -> :ok
        {:error, reason} -> {:error, reason}
      end
    else
      :ok
    end
  end

  defp use_repo?(opts), do: Keyword.get(opts, :use_repo, true) and repo_running?()

  defp repo_running?,
    do: Application.get_env(:flowstone, :start_repo, false) and Process.whereis(Repo) != nil
end
