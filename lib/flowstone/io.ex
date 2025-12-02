defmodule FlowStone.IO do
  @moduledoc """
  Dispatches storage operations to configured I/O managers.
  """

  @spec load(asset :: atom(), partition :: term(), opts :: keyword()) ::
          {:ok, term()} | {:error, term()}
  def load(asset, partition, opts \\ []) do
    {manager, config} = resolve_manager(opts)
    manager.load(asset, partition, config)
  end

  @spec store(asset :: atom(), data :: term(), partition :: term(), opts :: keyword()) ::
          :ok | {:error, term()}
  def store(asset, data, partition, opts \\ []) do
    {manager, config} = resolve_manager(opts)
    manager.store(asset, data, partition, config)
  end

  @spec delete(asset :: atom(), partition :: term(), opts :: keyword()) ::
          :ok | {:error, term()}
  def delete(asset, partition, opts \\ []) do
    {manager, config} = resolve_manager(opts)
    manager.delete(asset, partition, config)
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
