defmodule FlowStone.RouteDecisions do
  @moduledoc """
  Persistence wrapper for routing decisions.
  """

  alias FlowStone.{Partition, Repo, RouteDecision}

  @spec get(binary(), atom(), term()) :: {:ok, RouteDecision.t()} | {:error, :not_found}
  def get(run_id, router_asset, partition) do
    router_asset_str = to_string(router_asset)
    partition_str = normalize_partition(partition)

    case Repo.get_by(RouteDecision,
           run_id: run_id,
           router_asset: router_asset_str,
           partition: partition_str
         ) do
      nil -> {:error, :not_found}
      decision -> {:ok, decision}
    end
  end

  @spec record(binary(), atom(), term(), atom() | nil, [atom()], keyword()) ::
          {:ok, RouteDecision.t()} | {:error, term()}
  def record(run_id, router_asset, partition, selected_branch, available_branches, opts \\ []) do
    attrs = %{
      run_id: run_id,
      router_asset: to_string(router_asset),
      partition: normalize_partition(partition),
      selected_branch: normalize_branch(selected_branch),
      available_branches: Enum.map(available_branches, &to_string/1),
      input_hash: Keyword.get(opts, :input_hash),
      metadata: Keyword.get(opts, :metadata, %{})
    }

    %RouteDecision{}
    |> RouteDecision.changeset(attrs)
    |> Repo.insert(
      on_conflict: :nothing,
      conflict_target: [:run_id, :router_asset, :partition]
    )
    |> case do
      {:ok, _decision} -> get(run_id, router_asset, partition)
      {:error, reason} -> {:error, reason}
    end
  end

  @spec to_output(RouteDecision.t()) :: map()
  def to_output(%RouteDecision{} = decision) do
    %{
      decision_id: decision.id,
      router_asset: safe_to_existing_atom(decision.router_asset),
      selected_branch: safe_to_existing_atom(decision.selected_branch),
      available_branches: Enum.map(decision.available_branches, &safe_to_existing_atom/1)
    }
  end

  defp normalize_partition(nil), do: nil
  defp normalize_partition(partition), do: Partition.serialize(partition)

  defp normalize_branch(nil), do: nil
  defp normalize_branch(branch) when is_atom(branch), do: Atom.to_string(branch)
  defp normalize_branch(branch) when is_binary(branch), do: branch

  defp safe_to_existing_atom(nil), do: nil

  defp safe_to_existing_atom(string) when is_binary(string) do
    String.to_existing_atom(string)
  rescue
    ArgumentError -> string
  end
end
