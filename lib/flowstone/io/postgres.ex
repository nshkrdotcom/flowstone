defmodule FlowStone.IO.Postgres do
  @moduledoc """
  Postgres-backed I/O manager using Ecto for load/store.

  ## Security

  - Table and column names are validated to prevent SQL injection
  - Binary term decoding uses safe mode to prevent untrusted data attacks
  """

  @behaviour FlowStone.IO.Manager
  alias FlowStone.Repo

  # Valid SQL identifier pattern: alphanumeric, underscore, optionally schema-qualified
  @identifier_pattern ~r/^[a-zA-Z_][a-zA-Z0-9_]*(\.[a-zA-Z_][a-zA-Z0-9_]*)?$/

  @impl true
  def load(asset, partition, config) do
    if fun = config[:load_fun] do
      fun.(partition, config)
    else
      with {:ok, table} <- validate_identifier(config[:table] || default_table(asset)),
           {:ok, partition_col} <- validate_identifier(config[:partition_column] || "partition") do
        query = "SELECT data FROM #{table} WHERE #{partition_col} = $1"

        case Repo.query(query, [FlowStone.Partition.serialize(partition)]) do
          {:ok, %{rows: [[data]]}} -> {:ok, decode(data, config)}
          {:ok, %{rows: []}} -> {:error, :not_found}
          {:error, reason} -> {:error, reason}
        end
      end
    end
  end

  @impl true
  def store(asset, data, partition, config) do
    if fun = config[:store_fun] do
      fun.(partition, data, config)
    else
      with {:ok, table} <- validate_identifier(config[:table] || default_table(asset)),
           {:ok, partition_col} <- validate_identifier(config[:partition_column] || "partition") do
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
  end

  @impl true
  def delete(asset, partition, config) do
    with {:ok, table} <- validate_identifier(config[:table] || default_table(asset)),
         {:ok, partition_col} <- validate_identifier(config[:partition_column] || "partition") do
      Repo.query("DELETE FROM #{table} WHERE #{partition_col} = $1", [
        FlowStone.Partition.serialize(partition)
      ])

      :ok
    end
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

  # Validate that an identifier is safe for use in SQL
  # Prevents SQL injection by only allowing valid identifier characters
  defp validate_identifier(nil), do: {:error, {:invalid_identifier, nil}}

  defp validate_identifier(identifier) when is_atom(identifier) do
    validate_identifier(Atom.to_string(identifier))
  end

  defp validate_identifier(identifier) when is_binary(identifier) do
    if Regex.match?(@identifier_pattern, identifier) do
      {:ok, identifier}
    else
      {:error, {:invalid_identifier, identifier}}
    end
  end

  defp validate_identifier(other), do: {:error, {:invalid_identifier, other}}

  defp default_table(asset) when is_atom(asset), do: "flowstone_#{asset}"
  defp default_table(asset) when is_binary(asset), do: "flowstone_#{asset}"

  defp encode(data, config) do
    case config[:format] do
      :binary -> :erlang.term_to_binary(data)
      _ -> Jason.encode!(data)
    end
  end

  defp decode(data, config) do
    case config[:format] do
      :binary ->
        # Use safe mode to prevent untrusted data from creating atoms
        # or executing arbitrary code via special terms
        :erlang.binary_to_term(data, [:safe])

      _ ->
        Jason.decode!(data)
    end
  end
end
