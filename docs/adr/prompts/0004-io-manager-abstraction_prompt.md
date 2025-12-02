# Implementation Prompt: ADR-0004 I/O Manager Abstraction

## Objective

Implement pluggable I/O managers for asset storage using TDD with Supertester.

## Required Reading

1. **ADR-0004**: `docs/adr/0004-io-manager-abstraction.md`
2. **ExAws.S3**: https://hexdocs.pm/ex_aws_s3
3. **Explorer**: https://hexdocs.pm/explorer
4. **Supertester Manual**: https://hexdocs.pm/supertester

## Context

I/O Managers abstract storage backends:
- Memory (testing)
- PostgreSQL (structured data)
- S3 (object storage)
- Parquet (analytics)
- Custom implementations

## Implementation Tasks

### 1. Manager Behaviour

```elixir
# lib/flowstone/io/manager.ex
defmodule FlowStone.IO.Manager do
  @callback load(asset :: atom(), partition :: term(), config :: map()) ::
    {:ok, data :: term()} | {:error, :not_found} | {:error, term()}

  @callback store(asset :: atom(), data :: term(), partition :: term(), config :: map()) ::
    :ok | {:error, term()}

  @callback delete(asset :: atom(), partition :: term(), config :: map()) ::
    :ok | {:error, term()}

  @callback metadata(asset :: atom(), partition :: term(), config :: map()) ::
    {:ok, map()} | {:error, term()}

  @callback exists?(asset :: atom(), partition :: term(), config :: map()) ::
    boolean()

  @optional_callbacks [metadata: 3, exists?: 3]
end
```

### 2. Memory Manager

```elixir
# lib/flowstone/io/memory.ex
defmodule FlowStone.IO.Memory do
  @behaviour FlowStone.IO.Manager
  use Agent
end
```

### 3. Postgres Manager

```elixir
# lib/flowstone/io/postgres.ex
defmodule FlowStone.IO.Postgres do
  @behaviour FlowStone.IO.Manager
end
```

### 4. S3 Manager

```elixir
# lib/flowstone/io/s3.ex
defmodule FlowStone.IO.S3 do
  @behaviour FlowStone.IO.Manager
end
```

## Test Design with Supertester

### Memory Manager Tests

```elixir
defmodule FlowStone.IO.MemoryTest do
  use Supertester.ExUnitFoundation, isolation: :full_isolation
  import Supertester.OTPHelpers
  import Supertester.GenServerHelpers

  setup do
    {:ok, _} = setup_isolated_genserver(FlowStone.IO.Memory)
    :ok
  end

  describe "store/4 and load/3" do
    test "stores and retrieves data" do
      :ok = FlowStone.IO.Memory.store(:test_asset, %{value: 42}, ~D[2025-01-15], %{})

      assert {:ok, %{value: 42}} = FlowStone.IO.Memory.load(:test_asset, ~D[2025-01-15], %{})
    end

    test "returns not_found for missing" do
      assert {:error, :not_found} = FlowStone.IO.Memory.load(:missing, ~D[2025-01-15], %{})
    end
  end

  describe "delete/3" do
    test "removes stored data" do
      FlowStone.IO.Memory.store(:deleteme, :data, "p1", %{})
      :ok = FlowStone.IO.Memory.delete(:deleteme, "p1", %{})

      assert {:error, :not_found} = FlowStone.IO.Memory.load(:deleteme, "p1", %{})
    end
  end

  describe "exists?/3" do
    test "returns true for existing" do
      FlowStone.IO.Memory.store(:exists, :data, "p1", %{})
      assert FlowStone.IO.Memory.exists?(:exists, "p1", %{})
    end

    test "returns false for missing" do
      refute FlowStone.IO.Memory.exists?(:nope, "p1", %{})
    end
  end

  describe "concurrent access" do
    test "handles concurrent writes safely" do
      scenario = Supertester.ConcurrentHarness.define(
        threads: 10,
        operations: fn i ->
          FlowStone.IO.Memory.store(:"asset_#{i}", %{id: i}, "p1", %{})
        end
      )

      {:ok, report} = Supertester.ConcurrentHarness.run(scenario)
      assert report.metrics.success_count == 10
    end
  end
end
```

### Postgres Manager Tests

```elixir
defmodule FlowStone.IO.PostgresTest do
  use FlowStone.DataCase, async: true

  @config %{table: "test_io_data", partition_column: "partition_key"}

  setup do
    # Create test table
    Repo.query!("""
      CREATE TABLE IF NOT EXISTS test_io_data (
        partition_key VARCHAR PRIMARY KEY,
        data JSONB,
        updated_at TIMESTAMPTZ DEFAULT NOW()
      )
    """)

    on_exit(fn ->
      Repo.query!("DROP TABLE IF EXISTS test_io_data")
    end)

    :ok
  end

  describe "store/4 and load/3" do
    test "stores and retrieves JSON data" do
      data = %{"users" => [%{"id" => 1}, %{"id" => 2}]}

      :ok = FlowStone.IO.Postgres.store(:asset, data, "2025-01-15", @config)
      {:ok, loaded} = FlowStone.IO.Postgres.load(:asset, "2025-01-15", @config)

      assert loaded == data
    end

    test "upserts on duplicate partition" do
      FlowStone.IO.Postgres.store(:asset, %{v: 1}, "p1", @config)
      FlowStone.IO.Postgres.store(:asset, %{v: 2}, "p1", @config)

      {:ok, loaded} = FlowStone.IO.Postgres.load(:asset, "p1", @config)
      assert loaded == %{"v" => 2}
    end
  end

  describe "metadata/3" do
    test "returns size and timestamp" do
      data = String.duplicate("x", 1000)
      FlowStone.IO.Postgres.store(:asset, data, "p1", @config)

      {:ok, meta} = FlowStone.IO.Postgres.metadata(:asset, "p1", @config)
      assert meta.size_bytes > 0
      assert meta.updated_at != nil
    end
  end
end
```

### S3 Manager Tests (with Mox)

```elixir
defmodule FlowStone.IO.S3Test do
  use Supertester.ExUnitFoundation, isolation: :full_isolation
  import Mox

  setup :verify_on_exit!

  @config %{bucket: "test-bucket", format: :json}

  describe "store/4" do
    test "uploads to S3" do
      expect(ExAws.Mock, :request, fn %ExAws.Operation.S3{} = op ->
        assert op.bucket == "test-bucket"
        assert op.path =~ "test_asset/2025-01-15.json"
        {:ok, %{}}
      end)

      :ok = FlowStone.IO.S3.store(:test_asset, %{data: 1}, ~D[2025-01-15], @config)
    end
  end

  describe "load/3" do
    test "downloads from S3" do
      expect(ExAws.Mock, :request, fn %ExAws.Operation.S3{} ->
        {:ok, %{body: ~s({"data": 1})}}
      end)

      {:ok, data} = FlowStone.IO.S3.load(:test_asset, ~D[2025-01-15], @config)
      assert data == %{"data" => 1}
    end

    test "returns not_found for 404" do
      expect(ExAws.Mock, :request, fn _ ->
        {:error, {:http_error, 404, ""}}
      end)

      assert {:error, :not_found} = FlowStone.IO.S3.load(:missing, ~D[2025-01-15], @config)
    end
  end
end
```

## Implementation Order

1. **Manager behaviour** - Define interface
2. **Memory manager** - Testing backend
3. **Postgres manager** - SQL storage
4. **S3 manager** - Object storage
5. **Manager registry** - Configuration lookup

## Success Criteria

- [ ] All managers implement behaviour
- [ ] Memory manager works with Supertester isolation
- [ ] Postgres manager handles CRUD + upsert
- [ ] S3 manager mocked with Mox
- [ ] Concurrent access is safe

## Commands

```bash
mix test test/flowstone/io/
mix coveralls.html
```

## Spawn Subagents

1. **Memory manager** - Agent-based implementation
2. **Postgres manager** - Ecto queries
3. **S3 manager** - ExAws integration
4. **Manager registry** - Config resolution
