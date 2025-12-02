defmodule FlowStone.IO.Postgres do
  @moduledoc """
  Postgres-backed I/O manager.

  Uses injected functions in config for easy testing. In production,
  configure `:repo`, `:table`, and optional `:partition_column`.
  """

  @behaviour FlowStone.IO.Manager

  @impl true
  def load(_asset, partition, config) do
    case config[:load_fun] do
      fun when is_function(fun, 2) -> fun.(partition, config)
      _ -> {:error, :not_configured}
    end
  end

  @impl true
  def store(_asset, data, partition, config) do
    case config[:store_fun] do
      fun when is_function(fun, 3) -> fun.(partition, data, config)
      _ -> {:error, :not_configured}
    end
  end

  @impl true
  def delete(_asset, _partition, _config), do: :ok

  @impl true
  def metadata(_asset, _partition, _config), do: {:error, :not_implemented}

  @impl true
  def exists?(asset, partition, config) do
    case load(asset, partition, config) do
      {:ok, _} -> true
      _ -> false
    end
  end
end
