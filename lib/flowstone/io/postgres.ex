defmodule FlowStone.IO.Postgres do
  @moduledoc """
  Postgres-backed I/O manager using Ecto for load/store.
  """

  @behaviour FlowStone.IO.Manager
  alias FlowStone.Repo

  @impl true
  def load(asset, partition, config) do
    if fun = config[:load_fun] do
      fun.(partition, config)
    else
      table = config[:table] || default_table(asset)
      partition_col = config[:partition_column] || "partition"
      query = "SELECT data FROM #{table} WHERE #{partition_col} = $1"

      case Repo.query(query, [FlowStone.Partition.serialize(partition)]) do
        {:ok, %{rows: [[data]]}} -> {:ok, decode(data, config)}
        {:ok, %{rows: []}} -> {:error, :not_found}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  @impl true
  def store(asset, data, partition, config) do
    if fun = config[:store_fun] do
      fun.(partition, data, config)
    else
      table = config[:table] || default_table(asset)
      partition_col = config[:partition_column] || "partition"
      encoded = encode(data, config)

      query = """
      INSERT INTO #{table} (#{partition_col}, data, updated_at)
      VALUES ($1, $2, NOW())
      ON CONFLICT (#{partition_col}) DO UPDATE SET data = $2, updated_at = NOW()
      """

      case Repo.query(query, [FlowStone.Partition.serialize(partition), encoded]) do
        {:ok, _} -> :ok
        {:error, reason} -> {:error, reason}
      end
    end
  end

  @impl true
  def delete(asset, partition, config) do
    table = config[:table] || default_table(asset)
    partition_col = config[:partition_column] || "partition"

    Repo.query("DELETE FROM #{table} WHERE #{partition_col} = $1", [
      FlowStone.Partition.serialize(partition)
    ])

    :ok
  end

  @impl true
  def metadata(_asset, _partition, _config), do: {:error, :not_implemented}

  @impl true
  def exists?(asset, partition, config) do
    case load(asset, partition, config) do
      {:ok, _} -> true
      _ -> false
    end
  end

  defp default_table(asset), do: "flowstone_#{asset}"

  defp encode(data, config) do
    case config[:format] do
      :binary -> :erlang.term_to_binary(data)
      _ -> Jason.encode!(data)
    end
  end

  defp decode(data, config) do
    case config[:format] do
      :binary -> :erlang.binary_to_term(data)
      _ -> Jason.decode!(data)
    end
  end
end
