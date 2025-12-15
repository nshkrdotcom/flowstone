defmodule FlowStone.DAG do
  @moduledoc """
  DAG utilities for ordering assets.
  """

  alias FlowStone.Asset

  @type asset_name :: Asset.name()
  @type edge_map :: %{asset_name() => [asset_name()]}
  @type graph :: %{nodes: %{asset_name() => Asset.t()}, edges: edge_map()}

  @spec from_assets([Asset.t()]) :: {:ok, graph()} | {:error, {:cycle, [asset_name()]}}
  def from_assets(assets) do
    nodes = Map.new(assets, &{&1.name, &1})
    edges = Map.new(assets, fn asset -> {asset.name, asset.depends_on || []} end)

    with :ok <- detect_cycle(edges) do
      {:ok, %{nodes: nodes, edges: edges}}
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
end
