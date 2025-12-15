defmodule FlowStone.RunConfig do
  @moduledoc """
  Store for run configuration that cannot be safely serialized to JSON.

  When Oban jobs are persisted to the database, only JSON-safe values survive.
  This store holds runtime configuration (servers, functions, etc.) keyed by run_id
  so that workers can look up the execution context.

  For production use, this is a local ETS-based cache. The worker falls back to
  application config when no entry is found, making this safe for jobs that
  outlive the process that created them.
  """

  use GenServer

  @table_name :flowstone_run_config

  # Client API

  @doc """
  Start the RunConfig server.
  """
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc """
  Store configuration for a run_id.

  Config can include:
    - :registry - the asset registry server
    - :resource_server - the resource injection server
    - :lineage_server - the lineage recording server
    - :materialization_store - the materialization store server
    - :io_manager - the IO manager module
    - :io_config - IO configuration map
  """
  @spec put(String.t(), keyword()) :: :ok
  def put(run_id, config) when is_binary(run_id) do
    :ets.insert(@table_name, {run_id, config, System.monotonic_time(:millisecond)})
    :ok
  end

  @doc """
  Get configuration for a run_id.

  Returns nil if not found (worker should fall back to application config).
  """
  @spec get(String.t()) :: keyword() | nil
  def get(run_id) when is_binary(run_id) do
    case :ets.lookup(@table_name, run_id) do
      [{^run_id, config, _ts}] -> config
      [] -> nil
    end
  end

  @doc """
  Delete configuration for a run_id.
  """
  @spec delete(String.t()) :: :ok
  def delete(run_id) when is_binary(run_id) do
    :ets.delete(@table_name, run_id)
    :ok
  end

  @doc """
  Get a configuration value for a run_id, falling back to application config.
  """
  @spec get_value(String.t(), atom(), term()) :: term()
  def get_value(run_id, key, default \\ nil) do
    case get(run_id) do
      nil -> get_from_app_config(key, default)
      config -> Keyword.get(config, key) || get_from_app_config(key, default)
    end
  end

  defp get_from_app_config(key, default) do
    case key do
      :registry ->
        Application.get_env(:flowstone, :registry, FlowStone.Registry)

      :resource_server ->
        Application.get_env(:flowstone, :resources_server, FlowStone.Resources)

      :lineage_server ->
        Application.get_env(:flowstone, :lineage_server, FlowStone.Lineage)

      :materialization_store ->
        Application.get_env(:flowstone, :materialization_store, FlowStone.MaterializationStore)

      _ ->
        default
    end
  end

  # Server callbacks

  @impl true
  def init(_opts) do
    table = :ets.new(@table_name, [:named_table, :public, :set, read_concurrency: true])

    # Schedule periodic cleanup of old entries
    schedule_cleanup()

    {:ok, %{table: table}}
  end

  @impl true
  def handle_info(:cleanup, state) do
    cleanup_old_entries()
    schedule_cleanup()
    {:noreply, state}
  end

  defp schedule_cleanup do
    # Clean up entries older than 1 hour every 10 minutes
    Process.send_after(self(), :cleanup, :timer.minutes(10))
  end

  defp cleanup_old_entries do
    cutoff = System.monotonic_time(:millisecond) - :timer.hours(1)

    :ets.select_delete(@table_name, [
      {{:"$1", :"$2", :"$3"}, [{:<, :"$3", cutoff}], [true]}
    ])
  end
end
