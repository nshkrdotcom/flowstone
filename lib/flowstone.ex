defmodule FlowStone do
  @moduledoc """
  Entry point for FlowStone APIs.
  """

  alias FlowStone.Registry
  alias FlowStone.DAG

  @doc """
  Return assets declared in a pipeline module.
  """
  def assets(pipeline_module) do
    pipeline_module.__flowstone_assets__()
  end

  @doc """
  Build a DAG from a pipeline module.
  """
  def dag(pipeline_module) do
    pipeline_module
    |> assets()
    |> DAG.from_assets()
  end

  @doc """
  Register all assets from a pipeline into the registry.
  """
  def register(pipeline_module, opts \\ []) do
    server = Keyword.get(opts, :registry, Registry)
    ensure_registry(server)
    Registry.register_assets(assets(pipeline_module), server: server)
  end

  defp ensure_registry(server) when is_atom(server) do
    case Process.whereis(server) do
      nil -> Registry.start_link(name: server)
      _pid -> :ok
    end
  end

  defp ensure_registry(_server), do: :ok
end
