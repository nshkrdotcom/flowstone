defmodule FlowStone.RouteDecisions do
  @moduledoc """
  Persistence wrapper for routing decisions.

  ## Cleanup

  Route decisions accumulate over time as pipelines run. Use the cleanup functions
  to prevent unbounded table growth:

      # Remove decisions older than 7 days
      {:ok, count} = FlowStone.RouteDecisions.cleanup_older_than(days: 7)

      # Remove all decisions for a completed run
      {:ok, count} = FlowStone.RouteDecisions.cleanup_by_run_id(run_id)

  For automated cleanup, consider scheduling a periodic job via Oban or a GenServer
  that calls `cleanup_older_than/1` on a regular interval.
  """

  import Ecto.Query
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

  # Cleanup functions

  @doc """
  Remove routing decisions older than the specified duration.

  ## Options

    * `:days` - Number of days to keep decisions (default: 7)
    * `:hours` - Number of hours to keep decisions (overrides `:days` if both provided)

  ## Examples

      # Remove decisions older than 7 days (default)
      {:ok, count} = RouteDecisions.cleanup_older_than([])

      # Remove decisions older than 30 days
      {:ok, count} = RouteDecisions.cleanup_older_than(days: 30)

      # Remove decisions older than 24 hours
      {:ok, count} = RouteDecisions.cleanup_older_than(hours: 24)

  ## Returns

    * `{:ok, count}` - Number of decisions deleted

  """
  @spec cleanup_older_than(keyword()) :: {:ok, non_neg_integer()}
  def cleanup_older_than(opts \\ []) do
    cutoff = calculate_cutoff(opts)

    {count, _} =
      from(d in RouteDecision, where: d.inserted_at < ^cutoff)
      |> Repo.delete_all()

    :telemetry.execute(
      [:flowstone, :route_decisions, :cleanup],
      %{count: count},
      %{cutoff: cutoff, type: :time_based}
    )

    {:ok, count}
  end

  @doc """
  Remove all routing decisions for a specific run.

  Use this to clean up decisions when a pipeline run is fully complete
  and the decisions are no longer needed.

  ## Examples

      {:ok, count} = RouteDecisions.cleanup_by_run_id(run_id)

  ## Returns

    * `{:ok, count}` - Number of decisions deleted

  """
  @spec cleanup_by_run_id(binary()) :: {:ok, non_neg_integer()}
  def cleanup_by_run_id(run_id) when is_binary(run_id) do
    {count, _} =
      from(d in RouteDecision, where: d.run_id == ^run_id)
      |> Repo.delete_all()

    :telemetry.execute(
      [:flowstone, :route_decisions, :cleanup],
      %{count: count},
      %{run_id: run_id, type: :run_based}
    )

    {:ok, count}
  end

  defp calculate_cutoff(opts) do
    cond do
      hours = Keyword.get(opts, :hours) ->
        DateTime.add(DateTime.utc_now(), -hours * 3600, :second)

      days = Keyword.get(opts, :days) ->
        DateTime.add(DateTime.utc_now(), -days * 24 * 3600, :second)

      true ->
        # Default: 7 days
        DateTime.add(DateTime.utc_now(), -7 * 24 * 3600, :second)
    end
  end
end
