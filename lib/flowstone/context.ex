defmodule FlowStone.Context do
  @moduledoc """
  Execution context passed to asset functions.
  """

  defstruct [
    :asset,
    :partition,
    :run_id,
    :resources,
    :metadata,
    :started_at
  ]

  @doc """
  Build a context for an asset, injecting only required resources.
  """
  def build(asset, partition, run_id, opts \\ []) do
    required = Map.get(asset, :requires, [])

    server =
      Keyword.get(
        opts,
        :resource_server,
        Application.get_env(:flowstone, :resources_server, FlowStone.Resources)
      )

    resources = load_resources(required, server)

    %__MODULE__{
      asset: asset.name,
      partition: partition,
      run_id: run_id,
      resources: resources,
      started_at: DateTime.utc_now()
    }
  end

  defp load_resources(_required, nil), do: %{}

  defp load_resources(required, server) when is_pid(server) do
    if Process.alive?(server) do
      FlowStone.Resources.load(server) |> Map.take(required)
    else
      %{}
    end
  end

  defp load_resources(required, server) when is_atom(server) do
    if Code.ensure_loaded?(FlowStone.Resources) and Process.whereis(server) do
      FlowStone.Resources.load(server) |> Map.take(required)
    else
      %{}
    end
  end
end
