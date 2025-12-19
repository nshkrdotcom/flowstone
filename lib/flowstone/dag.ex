defmodule FlowStone.DAG do
  @moduledoc """
  DAG utilities for ordering assets.
  """

  alias FlowStone.Asset

  @type asset_name :: Asset.name()
  @type edge_map :: %{asset_name() => [asset_name()]}
  @type graph :: %{nodes: %{asset_name() => Asset.t()}, edges: edge_map()}

  @spec from_assets([Asset.t()]) ::
          {:ok, graph()} | {:error, {:cycle, [asset_name()]}} | {:error, {:invalid, String.t()}}
  def from_assets(assets) do
    nodes = Map.new(assets, &{&1.name, &1})

    with :ok <- validate_optional_deps(assets),
         :ok <- validate_routed_assets(assets, nodes) do
      edges =
        Map.new(assets, fn asset ->
          deps = asset.depends_on || []
          deps = maybe_add_router_dep(asset, deps)
          {asset.name, deps}
        end)

      with :ok <- detect_cycle(edges) do
        {:ok, %{nodes: nodes, edges: edges}}
      end
    end
  end

  @doc """
  Return a topological ordering of asset names.
  """
  @spec topological_names(%{edges: edge_map()}) :: [asset_name()]
  def topological_names(%{edges: edges}) do
    {order, _} =
      Enum.reduce(edges, {[], edges}, fn {node, _}, {acc, remaining} ->
        {sorted, rest} = visit(node, remaining, %{}, [])
        {sorted ++ acc, rest}
      end)

    order |> Enum.reverse() |> Enum.uniq()
  end

  @type visit_state :: %{optional(asset_name()) => true}

  @spec visit(asset_name(), edge_map(), visit_state(), [asset_name()]) ::
          {[asset_name()], edge_map()}
  defp visit(node, edges, visiting, acc) do
    cond do
      Map.has_key?(visiting, node) ->
        raise ArgumentError, "cycle detected involving #{inspect(node)}"

      not Map.has_key?(edges, node) ->
        {acc, edges}

      true ->
        deps = Map.get(edges, node, [])
        visiting = Map.put(visiting, node, true)

        {acc, edges} =
          Enum.reduce(deps, {acc, edges}, fn dep, {a, e} ->
            visit(dep, e, visiting, a)
          end)

        {[node | acc], Map.delete(edges, node)}
    end
  end

  @spec detect_cycle(edge_map()) :: :ok | {:error, {:cycle, [asset_name()]}}
  defp detect_cycle(edges) do
    topological_names(%{edges: edges})
    :ok
  rescue
    ArgumentError -> {:error, {:cycle, []}}
  end

  defp validate_optional_deps(assets) do
    Enum.reduce_while(assets, :ok, fn asset, :ok ->
      optional = Map.get(asset, :optional_deps, [])
      depends_on = Map.get(asset, :depends_on, [])
      invalid = optional -- depends_on

      if invalid == [] do
        {:cont, :ok}
      else
        {:halt,
         {:error,
          {:invalid, "optional_deps must be subset of depends_on for #{inspect(asset.name)}"}}}
      end
    end)
  end

  defp validate_routed_assets(assets, nodes) do
    Enum.reduce_while(assets, :ok, fn asset, :ok ->
      case Map.get(asset, :routed_from) do
        nil -> {:cont, :ok}
        router_name -> validate_router_reference(asset, router_name, nodes)
      end
    end)
  end

  defp validate_router_reference(asset, router_name, nodes) do
    error =
      {:error, {:invalid, "routed_from must reference a router asset for #{inspect(asset.name)}"}}

    case Map.fetch(nodes, router_name) do
      {:ok, router_asset} when router_asset != nil ->
        if router?(router_asset), do: {:cont, :ok}, else: {:halt, error}

      _ ->
        {:halt, error}
    end
  end

  defp router?(asset) do
    not is_nil(Map.get(asset, :route_fn)) or not is_nil(Map.get(asset, :route_rules))
  end

  defp maybe_add_router_dep(asset, deps) do
    case Map.get(asset, :routed_from) do
      nil -> deps
      router -> Enum.uniq([router | deps])
    end
  end
end
