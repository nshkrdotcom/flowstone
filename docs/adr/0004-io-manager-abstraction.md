# ADR-0004: I/O Manager Abstraction

## Status
Accepted

## Context

Assets need to store and retrieve their materialized values from various backends:
- PostgreSQL tables
- S3/MinIO object storage
- Parquet files (for data science workloads)
- Redis/Memcached (for caching layers)
- Custom enterprise systems

We need a pluggable storage abstraction that:
1. Decouples asset logic from storage implementation
2. Supports testing with in-memory backends
3. Enables migration between storage systems
4. Handles serialization/deserialization transparently

## Decision

### 1. I/O Manager Behaviour

```elixir
defmodule FlowStone.IO.Manager do
  @doc "Load an asset's data for a partition"
  @callback load(asset :: atom(), partition :: term(), config :: map()) ::
    {:ok, data :: term()} | {:error, :not_found} | {:error, term()}

  @doc "Store an asset's data for a partition"
  @callback store(asset :: atom(), data :: term(), partition :: term(), config :: map()) ::
    :ok | {:error, term()}

  @doc "Delete an asset's data for a partition"
  @callback delete(asset :: atom(), partition :: term(), config :: map()) ::
    :ok | {:error, term()}

  @doc "Get metadata about stored data"
  @callback metadata(asset :: atom(), partition :: term(), config :: map()) ::
    {:ok, %{size_bytes: integer(), updated_at: DateTime.t(), checksum: String.t()}} |
    {:error, term()}

  @doc "Check if data exists for partition"
  @callback exists?(asset :: atom(), partition :: term(), config :: map()) ::
    boolean()

  @optional_callbacks [metadata: 3, exists?: 3]
end
```

### 2. Built-In I/O Managers

#### Memory (Testing/Development)

```elixir
defmodule FlowStone.IO.Memory do
  @behaviour FlowStone.IO.Manager
  use Agent

  def start_link(_opts) do
    Agent.start_link(fn -> %{} end, name: __MODULE__)
  end

  def load(asset, partition, _config) do
    case Agent.get(__MODULE__, &Map.get(&1, {asset, partition})) do
      nil -> {:error, :not_found}
      data -> {:ok, data}
    end
  end

  def store(asset, data, partition, _config) do
    Agent.update(__MODULE__, &Map.put(&1, {asset, partition}, data))
    :ok
  end

  def delete(asset, partition, _config) do
    Agent.update(__MODULE__, &Map.delete(&1, {asset, partition}))
    :ok
  end

  def clear do
    Agent.update(__MODULE__, fn _ -> %{} end)
  end
end
```

#### PostgreSQL

```elixir
defmodule FlowStone.IO.Postgres do
  @behaviour FlowStone.IO.Manager

  def load(asset, partition, config) do
    table = config[:table] || default_table(asset)
    partition_column = config[:partition_column] || "partition"

    query = "SELECT data FROM #{table} WHERE #{partition_column} = $1"

    case Repo.query(query, [serialize_partition(partition)]) do
      {:ok, %{rows: [[data]]}} -> {:ok, deserialize(data, config)}
      {:ok, %{rows: []}} -> {:error, :not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  def store(asset, data, partition, config) do
    table = config[:table] || default_table(asset)
    partition_column = config[:partition_column] || "partition"

    serialized = serialize(data, config)

    query = """
    INSERT INTO #{table} (#{partition_column}, data, updated_at)
    VALUES ($1, $2, NOW())
    ON CONFLICT (#{partition_column})
    DO UPDATE SET data = $2, updated_at = NOW()
    """

    case Repo.query(query, [serialize_partition(partition), serialized]) do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp serialize(data, config) do
    case config[:format] do
      :json -> Jason.encode!(data)
      :binary -> :erlang.term_to_binary(data)
      _ -> Jason.encode!(data)
    end
  end

  defp deserialize(data, config) do
    case config[:format] do
      :json -> Jason.decode!(data)
      :binary -> :erlang.binary_to_term(data)
      _ -> Jason.decode!(data)
    end
  end
end
```

#### S3/MinIO

```elixir
defmodule FlowStone.IO.S3 do
  @behaviour FlowStone.IO.Manager

  def load(asset, partition, config) do
    bucket = resolve_bucket(config, partition)
    key = resolve_key(asset, partition, config)

    case ExAws.S3.get_object(bucket, key) |> ExAws.request() do
      {:ok, %{body: body}} -> {:ok, deserialize(body, config)}
      {:error, {:http_error, 404, _}} -> {:error, :not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  def store(asset, data, partition, config) do
    bucket = resolve_bucket(config, partition)
    key = resolve_key(asset, partition, config)
    body = serialize(data, config)

    case ExAws.S3.put_object(bucket, key, body) |> ExAws.request() do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  def metadata(asset, partition, config) do
    bucket = resolve_bucket(config, partition)
    key = resolve_key(asset, partition, config)

    case ExAws.S3.head_object(bucket, key) |> ExAws.request() do
      {:ok, %{headers: headers}} ->
        {:ok, %{
          size_bytes: get_header(headers, "content-length") |> String.to_integer(),
          updated_at: get_header(headers, "last-modified") |> parse_http_date(),
          checksum: get_header(headers, "etag")
        }}
      {:error, reason} -> {:error, reason}
    end
  end

  defp resolve_bucket(config, partition) do
    case config[:bucket] do
      fun when is_function(fun, 1) -> fun.(partition)
      bucket when is_binary(bucket) -> bucket
    end
  end

  defp resolve_key(asset, partition, config) do
    case config[:path] do
      fun when is_function(fun, 1) -> fun.(partition)
      nil -> "#{asset}/#{serialize_partition(partition)}.#{config[:format] || :json}"
    end
  end

  defp serialize(data, config) do
    case config[:format] do
      :json -> Jason.encode!(data)
      :parquet -> encode_parquet(data)
      :etf -> :erlang.term_to_binary(data, [:compressed])
      _ -> Jason.encode!(data)
    end
  end
end
```

#### Parquet (Data Science)

```elixir
defmodule FlowStone.IO.Parquet do
  @behaviour FlowStone.IO.Manager

  @doc "Load parquet from S3 into Explorer DataFrame"
  def load(asset, partition, config) do
    bucket = config[:bucket]
    key = resolve_key(asset, partition, config)

    # Stream from S3 to Explorer
    case ExAws.S3.download_file(bucket, key, :memory) |> ExAws.request() do
      {:ok, %{body: body}} ->
        {:ok, Explorer.DataFrame.from_parquet!(body)}
      {:error, reason} ->
        {:error, reason}
    end
  end

  def store(asset, dataframe, partition, config) do
    bucket = config[:bucket]
    key = resolve_key(asset, partition, config)

    body = Explorer.DataFrame.to_parquet!(dataframe)

    case ExAws.S3.put_object(bucket, key, body) |> ExAws.request() do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end
end
```

### 3. Asset Configuration

```elixir
asset :user_analytics do
  # Inline configuration
  io_manager :postgres
  table "analytics.user_metrics"
  partition_column "date"
  format :json

  execute fn context, deps -> ... end
end

asset :data_export do
  # Function-based configuration
  io_manager :s3
  bucket "exports"
  path fn partition -> "reports/#{partition}/export.parquet" end
  format :parquet

  execute fn context, deps -> ... end
end

asset :custom_storage do
  # Custom I/O manager
  io_manager MyApp.EnterpriseIO
  config %{endpoint: "https://internal.api", auth: {:bearer, get_token()}}

  execute fn context, deps -> ... end
end
```

### 4. Registration

```elixir
# config/config.exs
config :flowstone,
  io_managers: %{
    memory: FlowStone.IO.Memory,
    postgres: FlowStone.IO.Postgres,
    s3: FlowStone.IO.S3,
    parquet: FlowStone.IO.Parquet,
    # Custom managers
    enterprise: MyApp.EnterpriseIO
  },
  default_io_manager: :postgres
```

### 5. Testing Support

```elixir
defmodule MyAssetTest do
  use ExUnit.Case
  use FlowStone.AssetCase

  setup do
    FlowStone.IO.Memory.clear()
    :ok
  end

  test "computes correctly" do
    # All assets use :memory in test environment
    {:ok, result} = FlowStone.materialize(:my_asset, partition: ~D[2025-01-01])
    assert result.value == expected
  end
end
```

```elixir
# config/test.exs
config :flowstone,
  default_io_manager: :memory
```

## Consequences

### Positive

1. **Storage Agnostic**: Assets don't know or care where data lives.
2. **Easy Testing**: Swap to in-memory for fast, isolated tests.
3. **Migration Path**: Change storage backends without modifying assets.
4. **Format Flexibility**: JSON, Parquet, ETF, custom serialization.
5. **Tenant Isolation**: Bucket/path functions enable per-tenant storage.

### Negative

1. **Abstraction Cost**: Extra layer between asset and storage.
2. **Configuration Complexity**: Need to configure managers per environment.
3. **Feature Disparity**: Not all managers support all features (e.g., metadata).

### Anti-Patterns Avoided

| pipeline_ex Problem | FlowStone Solution |
|---------------------|-------------------|
| Hardcoded file paths | Configurable path functions |
| Manual JSON serialization | Format abstraction |
| No testing abstraction | Memory manager for tests |
| Mixed storage concerns | Clean behaviour separation |

## References

- Dagster I/O Managers: https://docs.dagster.io/concepts/io-management/io-managers
- Explorer DataFrame: https://hexdocs.pm/explorer
- ExAws S3: https://hexdocs.pm/ex_aws_s3
