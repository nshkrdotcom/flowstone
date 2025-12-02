# Implementation Prompt: ADR-0002 DAG Engine with Persistent Metadata

## Objective

Implement the DAG engine using Runic and PostgreSQL-backed materialization persistence using TDD with Supertester.

## Required Reading

1. **ADR-0002**: `docs/adr/0002-dag-engine-persistence.md`
2. **ADR-0001**: `docs/adr/0001-asset-first-orchestration.md` (dependency)
3. **Runic docs**: https://hexdocs.pm/runic
4. **Ecto docs**: https://hexdocs.pm/ecto
5. **Supertester Manual**: https://hexdocs.pm/supertester

## Context

The DAG engine:
- Builds execution graphs from asset dependencies using Runic
- Persists materialization records to PostgreSQL
- Tracks lineage (upstream assets consumed)
- Supports incremental rebuilds via dependency hashing

## Implementation Tasks

### 1. Ecto Schema for Materializations

```elixir
# lib/flowstone/materialization.ex
defmodule FlowStone.Materialization do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  schema "flowstone_materializations" do
    field :asset_name, :string
    field :partition, :string
    field :run_id, Ecto.UUID
    field :status, Ecto.Enum, values: [:pending, :running, :success, :failed, :stale, :waiting_approval]
    field :started_at, :utc_datetime_usec
    field :completed_at, :utc_datetime_usec
    field :duration_ms, :integer
    field :upstream_assets, {:array, :string}
    field :upstream_partitions, {:array, :string}
    field :dependency_hash, :string
    field :metadata, :map
    field :error_message, :string
    field :executor_node, :string

    timestamps(type: :utc_datetime_usec)
  end
end
```

### 2. Database Migration

```elixir
# priv/repo/migrations/YYYYMMDDHHMMSS_create_flowstone_materializations.exs
defmodule FlowStone.Repo.Migrations.CreateFlowStoneMaterializations do
  use Ecto.Migration

  def change do
    create table(:flowstone_materializations, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :asset_name, :string, null: false
      add :partition, :string
      add :run_id, :uuid, null: false
      add :status, :string, null: false, default: "pending"
      add :started_at, :utc_datetime_usec
      add :completed_at, :utc_datetime_usec
      add :duration_ms, :integer
      add :upstream_assets, {:array, :string}
      add :upstream_partitions, {:array, :string}
      add :dependency_hash, :string
      add :metadata, :map, default: %{}
      add :error_message, :text
      add :executor_node, :string

      timestamps(type: :utc_datetime_usec)
    end

    create index(:flowstone_materializations, [:asset_name, :partition])
    create index(:flowstone_materializations, [:run_id])
    create index(:flowstone_materializations, [:status])
    create index(:flowstone_materializations, [:inserted_at])
    create index(:flowstone_materializations, [:upstream_assets], using: :gin)
  end
end
```

### 3. DAG Builder

```elixir
# lib/flowstone/dag.ex
defmodule FlowStone.DAG do
  @doc "Build execution order from asset dependencies"
  def execution_order(target_asset)

  @doc "Check for dependency cycles"
  def check_cycles(assets)

  @doc "Get all assets that depend on this asset"
  def dependents(asset)

  @doc "Get all dependencies of this asset"
  def dependencies(asset)
end

# lib/flowstone/dag/builder.ex
defmodule FlowStone.DAG.Builder do
  @doc "Convert assets to Runic workflow"
  def build_workflow(assets)
end
```

### 4. Materialization CRUD

```elixir
# lib/flowstone/materialization/store.ex
defmodule FlowStone.Materialization.Store do
  def create(attrs)
  def get(asset_name, partition)
  def get_by_run_id(run_id)
  def update_status(id, status, attrs \\ %{})
  def exists?(asset_name, partition)
  def list_by_status(status, opts \\ [])
end
```

## Test Design with Supertester

### Database Setup

```elixir
# test/support/data_case.ex
defmodule FlowStone.DataCase do
  use ExUnit.CaseTemplate

  using do
    quote do
      use Supertester.ExUnitFoundation, isolation: :full_isolation
      import FlowStone.DataCase
      alias FlowStone.Repo
    end
  end

  setup tags do
    pid = Ecto.Adapters.SQL.Sandbox.start_owner!(FlowStone.Repo, shared: not tags[:async])
    on_exit(fn -> Ecto.Adapters.SQL.Sandbox.stop_owner(pid) end)
    :ok
  end
end
```

### DAG Tests

```elixir
defmodule FlowStone.DAGTest do
  use FlowStone.DataCase, async: true
  import Supertester.Assertions

  describe "execution_order/1" do
    test "returns topologically sorted assets" do
      assets = [
        %FlowStone.Asset{name: :a, depends_on: []},
        %FlowStone.Asset{name: :b, depends_on: [:a]},
        %FlowStone.Asset{name: :c, depends_on: [:a, :b]},
        %FlowStone.Asset{name: :d, depends_on: [:c]}
      ]

      order = FlowStone.DAG.execution_order(:d, assets)

      # Assert ordering constraints
      assert index_of(order, :a) < index_of(order, :b)
      assert index_of(order, :b) < index_of(order, :c)
      assert index_of(order, :c) < index_of(order, :d)
    end

    test "handles diamond dependencies" do
      assets = [
        %FlowStone.Asset{name: :source, depends_on: []},
        %FlowStone.Asset{name: :left, depends_on: [:source]},
        %FlowStone.Asset{name: :right, depends_on: [:source]},
        %FlowStone.Asset{name: :sink, depends_on: [:left, :right]}
      ]

      order = FlowStone.DAG.execution_order(:sink, assets)

      assert :source in order
      assert index_of(order, :source) < index_of(order, :left)
      assert index_of(order, :source) < index_of(order, :right)
      assert index_of(order, :left) < index_of(order, :sink)
      assert index_of(order, :right) < index_of(order, :sink)
    end
  end

  describe "check_cycles/1" do
    test "detects simple cycle" do
      assets = [
        %FlowStone.Asset{name: :a, depends_on: [:b]},
        %FlowStone.Asset{name: :b, depends_on: [:a]}
      ]

      assert {:error, cycle} = FlowStone.DAG.check_cycles(assets)
      assert :a in cycle
      assert :b in cycle
    end

    test "detects transitive cycle" do
      assets = [
        %FlowStone.Asset{name: :a, depends_on: [:c]},
        %FlowStone.Asset{name: :b, depends_on: [:a]},
        %FlowStone.Asset{name: :c, depends_on: [:b]}
      ]

      assert {:error, _cycle} = FlowStone.DAG.check_cycles(assets)
    end

    test "accepts valid DAG" do
      assets = [
        %FlowStone.Asset{name: :a, depends_on: []},
        %FlowStone.Asset{name: :b, depends_on: [:a]},
        %FlowStone.Asset{name: :c, depends_on: [:a, :b]}
      ]

      assert :ok = FlowStone.DAG.check_cycles(assets)
    end
  end

  defp index_of(list, item) do
    Enum.find_index(list, &(&1 == item))
  end
end
```

### Materialization Store Tests

```elixir
defmodule FlowStone.Materialization.StoreTest do
  use FlowStone.DataCase, async: true

  alias FlowStone.Materialization.Store

  describe "create/1" do
    test "creates materialization record" do
      attrs = %{
        asset_name: "daily_report",
        partition: "2025-01-15",
        run_id: Ecto.UUID.generate(),
        status: :pending
      }

      assert {:ok, mat} = Store.create(attrs)
      assert mat.asset_name == "daily_report"
      assert mat.status == :pending
    end
  end

  describe "get/2" do
    test "retrieves existing materialization" do
      {:ok, created} = Store.create(%{
        asset_name: "test",
        partition: "p1",
        run_id: Ecto.UUID.generate(),
        status: :success
      })

      assert {:ok, found} = Store.get("test", "p1")
      assert found.id == created.id
    end

    test "returns not_found for missing" do
      assert {:error, :not_found} = Store.get("nonexistent", "p1")
    end
  end

  describe "update_status/3" do
    test "transitions status correctly" do
      {:ok, mat} = Store.create(%{
        asset_name: "status_test",
        partition: "p1",
        run_id: Ecto.UUID.generate(),
        status: :pending
      })

      assert {:ok, updated} = Store.update_status(mat.id, :running, %{
        started_at: DateTime.utc_now()
      })
      assert updated.status == :running
      assert updated.started_at != nil
    end
  end

  describe "exists?/2" do
    test "returns true for existing" do
      Store.create(%{
        asset_name: "exists_test",
        partition: "p1",
        run_id: Ecto.UUID.generate(),
        status: :success
      })

      assert Store.exists?("exists_test", "p1")
    end

    test "returns false for missing" do
      refute Store.exists?("missing", "p1")
    end
  end
end
```

### Property-Based DAG Tests

```elixir
defmodule FlowStone.DAG.PropertyTest do
  use FlowStone.DataCase, async: true
  use ExUnitProperties

  property "topological sort maintains dependency ordering" do
    check all assets <- valid_dag_generator() do
      sorted = FlowStone.DAG.execution_order(:target, assets)

      for asset <- sorted do
        asset_idx = Enum.find_index(sorted, &(&1.name == asset.name))

        for dep <- asset.depends_on do
          dep_idx = Enum.find_index(sorted, &(&1.name == dep))
          assert dep_idx < asset_idx
        end
      end
    end
  end

  defp valid_dag_generator do
    # Generate DAGs without cycles
    gen all count <- integer(2..10),
            names = Enum.map(1..count, &:"asset_#{&1}") do
      Enum.with_index(names)
      |> Enum.map(fn {name, idx} ->
        # Only depend on earlier assets (no cycles)
        possible_deps = Enum.take(names, idx)
        deps = Enum.take_random(possible_deps, min(idx, 3))
        %FlowStone.Asset{name: name, depends_on: deps}
      end)
    end
  end
end
```

## Supertester Integration for Database Tests

### Use DataCase with Sandbox

```elixir
use FlowStone.DataCase, async: true
```

### Test Transaction Rollback

Each test runs in a transaction that's rolled back automatically.

### Concurrent Database Access

```elixir
test "handles concurrent materialization writes" do
  scenario = Supertester.ConcurrentHarness.define(
    threads: 10,
    operations: fn i ->
      Store.create(%{
        asset_name: "concurrent_#{i}",
        partition: "p1",
        run_id: Ecto.UUID.generate(),
        status: :success
      })
    end
  )

  {:ok, report} = Supertester.ConcurrentHarness.run(scenario)
  assert report.metrics.success_count == 10
end
```

## Implementation Order

1. **Ecto Schema + Migration** - Data model
2. **Materialization.Store** - CRUD operations
3. **DAG.Builder** - Runic integration
4. **DAG module** - Public API
5. **Integration tests** - End-to-end

## Success Criteria

- [ ] All tests pass with `async: true`
- [ ] Migration runs successfully
- [ ] DAG correctly handles diamond and complex dependencies
- [ ] Cycle detection works for all cycle types
- [ ] Materialization CRUD is complete
- [ ] Property tests validate invariants

## Commands

```bash
mix ecto.create
mix ecto.migrate
mix test test/flowstone/dag_test.exs test/flowstone/materialization/
mix coveralls.html
```

## Spawn Subagents

1. **Schema + Migration** - Database layer
2. **DAG Builder** - Runic integration
3. **Store CRUD** - Materialization operations
4. **Property Tests** - Invariant validation
