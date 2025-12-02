defmodule FlowStone.IO do
  @moduledoc """
  Dispatches storage operations to configured I/O managers.
  """

  @spec load(asset :: atom(), partition :: term(), opts :: keyword()) ::
          {:ok, term()} | {:error, term()}
  def load(asset, partition, opts \\ []) do
    {manager, config} = resolve_manager(opts)
    metadata = %{asset: asset, partition: partition, io_manager: manager}
    start = System.monotonic_time()
    :telemetry.execute([:flowstone, :io, :load, :start], %{}, metadata)

    result = manager.load(asset, partition, config)

    duration = System.monotonic_time() - start

    size =
      case result do
        {:ok, data} -> :erlang.external_size(data)
        _ -> 0
      end

    :telemetry.execute(
      [:flowstone, :io, :load, :stop],
      %{duration: duration, size_bytes: size},
      metadata
    )

    result
  end

  @spec store(asset :: atom(), data :: term(), partition :: term(), opts :: keyword()) ::
          :ok | {:error, term()}
  def store(asset, data, partition, opts \\ []) do
    {manager, config} = resolve_manager(opts)
    metadata = %{asset: asset, partition: partition, io_manager: manager}
    start = System.monotonic_time()
    :telemetry.execute([:flowstone, :io, :store, :start], %{}, metadata)

    result = manager.store(asset, data, partition, config)

    duration = System.monotonic_time() - start
    :telemetry.execute([:flowstone, :io, :store, :stop], %{duration: duration}, metadata)
    result
  end

  @spec delete(asset :: atom(), partition :: term(), opts :: keyword()) ::
          :ok | {:error, term()}
  def delete(asset, partition, opts \\ []) do
    {manager, config} = resolve_manager(opts)
    manager.delete(asset, partition, config)
  end

  @spec exists?(asset :: atom(), partition :: term(), opts :: keyword()) :: boolean()
  def exists?(asset, partition, opts \\ []) do
    {manager, config} = resolve_manager(opts)

    if function_exported?(manager, :exists?, 3) do
      manager.exists?(asset, partition, config)
    else
      case manager.load(asset, partition, config) do
        {:ok, _} -> true
        _ -> false
      end
    end
  end

  defp resolve_manager(opts) do
    managers = Application.get_env(:flowstone, :io_managers, %{})
    default = Application.get_env(:flowstone, :default_io_manager, :memory)
    key = Keyword.get(opts, :io_manager, default)
    config = Keyword.get(opts, :config, %{})

    manager =
      Map.fetch!(managers, key)
      |> ensure_loaded()

    {manager, config}
  end

  defp ensure_loaded(module) when is_atom(module) do
    _ = Code.ensure_loaded(module)
    module
  end
end
