defmodule FlowStone.Scatter.ItemReaders.Custom do
  @moduledoc """
  Custom ItemReader using init/read callbacks from config.
  """

  @behaviour FlowStone.Scatter.ItemReader

  @callback_keys [:init, :read, :count, :checkpoint, :restore, :close]

  @impl true
  def init(config, deps) when is_map(config) do
    with {:ok, init_fn} <- fetch_fn(config, :init, 2),
         {:ok, read_fn} <- fetch_fn(config, :read, 2) do
      custom_config = Map.drop(config, @callback_keys)
      count_fn = Map.get(config, :count)
      checkpoint_fn = Map.get(config, :checkpoint)
      restore_fn = Map.get(config, :restore)
      close_fn = Map.get(config, :close)

      case init_fn.(custom_config, deps) do
        {:ok, state} ->
          {:ok,
           %{
             state: state,
             read_fn: read_fn,
             count_fn: count_fn,
             checkpoint_fn: checkpoint_fn,
             restore_fn: restore_fn,
             close_fn: close_fn,
             config: custom_config
           }}

        {:error, _} = error ->
          error

        other ->
          {:error, {:invalid_init_return, other}}
      end
    end
  end

  @impl true
  def read(%{read_fn: read_fn, state: state} = wrapper, batch_size)
      when is_function(read_fn, 2) do
    case read_fn.(state, batch_size) do
      {:ok, items, :halt} ->
        {:ok, items, :halt}

      {:ok, items, new_state} ->
        {:ok, items, %{wrapper | state: new_state}}

      {:error, _} = error ->
        error

      other ->
        {:error, {:invalid_read_return, other}}
    end
  end

  @impl true
  def count(%{count_fn: nil}), do: :unknown

  def count(%{count_fn: count_fn, state: state}) when is_function(count_fn, 1) do
    case count_fn.(state) do
      {:ok, count} when is_integer(count) and count >= 0 -> {:ok, count}
      :unknown -> :unknown
      _other -> :unknown
    end
  end

  def count(_state), do: :unknown

  @impl true
  def checkpoint(%{checkpoint_fn: nil}), do: %{}

  def checkpoint(%{checkpoint_fn: checkpoint_fn, state: state})
      when is_function(checkpoint_fn, 1) do
    checkpoint_fn.(state)
  end

  def checkpoint(_state), do: %{}

  @impl true
  def restore(%{restore_fn: nil} = wrapper, _checkpoint), do: wrapper

  def restore(%{restore_fn: restore_fn, state: state} = wrapper, checkpoint)
      when is_function(restore_fn, 2) do
    %{wrapper | state: restore_fn.(state, checkpoint)}
  end

  def restore(wrapper, _checkpoint), do: wrapper

  @impl true
  def close(%{close_fn: nil}), do: :ok

  def close(%{close_fn: close_fn, state: state}) when is_function(close_fn, 1) do
    close_fn.(state)
    :ok
  end

  def close(_state), do: :ok

  defp fetch_fn(config, key, arity) do
    case Map.get(config, key) do
      fun when is_function(fun, arity) -> {:ok, fun}
      _ -> {:error, {:missing_callback, key}}
    end
  end
end
