defmodule FlowStone.Context do
  @moduledoc """
  Execution context passed to asset functions.

  ## Scatter Context

  When executing a scattered instance, the context includes:
  - `scatter_key` - The key identifying this scatter instance

  ## Batch Context

  When executing a batched scatter instance, the context includes:
  - `scatter_key` - Batch metadata: `%{"_batch" => true, "index" => N, "item_count" => M}`
  - `batch_index` - Zero-based index of this batch
  - `batch_count` - Total number of batches
  - `batch_items` - List of items in this batch
  - `batch_input` - Shared batch input (evaluated once at scatter start)
  """

  defstruct [
    :asset,
    :partition,
    :run_id,
    :resources,
    :metadata,
    :started_at,
    # Scatter fields
    :scatter_key,
    # Batch fields
    :batch_index,
    :batch_count,
    :batch_items,
    :batch_input
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
      metadata: Keyword.get(opts, :metadata, %{}),
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
