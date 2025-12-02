defmodule FlowStone.Health do
  @moduledoc """
  Simple health checks for core dependencies.
  """

  alias FlowStone.Repo

  @doc """
  Return a map of subsystem health statuses.
  """
  def status do
    %{
      repo: repo_status(),
      oban: oban_status(),
      resources: resources_status()
    }
  end

  defp repo_status do
    case Repo.query("SELECT 1") do
      {:ok, _} -> :ok
      {:error, _} -> :error
    end
  rescue
    _ -> :error
  end

  defp oban_status do
    if Process.whereis(Oban.Config), do: :ok, else: :stopped
  end

  defp resources_status do
    if Process.whereis(FlowStone.Resources), do: :ok, else: :stopped
  end
end
