defmodule FlowStone.IO.Parquet do
  @moduledoc """
  Parquet I/O manager. Delegates to injected conversion functions for testability.
  """

  @behaviour FlowStone.IO.Manager

  @impl true
  def load(_asset, _partition, config) do
    case config[:load_fun] do
      fun when is_function(fun, 0) -> fun.()
      _ -> {:error, :not_configured}
    end
  end

  @impl true
  def store(_asset, _data, _partition, config) do
    case config[:store_fun] do
      fun when is_function(fun, 1) -> fun.(:ok)
      _ -> {:error, :not_configured}
    end
  end

  @impl true
  def delete(_asset, _partition, _config), do: :ok

  @impl true
  def metadata(_asset, _partition, _config), do: {:error, :not_implemented}
end
