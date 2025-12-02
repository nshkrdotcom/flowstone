# Implementation Prompt: ADR-0003 Partitioning and Tenant Isolation

## Objective

Implement partition-aware execution and multi-tenant isolation using TDD with Supertester.

## Required Reading

1. **ADR-0003**: `docs/adr/0003-partitioning-isolation.md`
2. **ADR-0001**: `docs/adr/0001-asset-first-orchestration.md`
3. **ADR-0002**: `docs/adr/0002-dag-engine-persistence.md`
4. **PostgreSQL RLS**: https://www.postgresql.org/docs/current/ddl-rowsecurity.html
5. **Supertester Manual**: https://hexdocs.pm/supertester

## Context

Partitioning divides asset data space:
- **Time-based**: Daily, hourly partitions
- **Custom**: Tenant, region, composite keys
- **Tenant Isolation**: RLS, separated storage

## Implementation Tasks

### 1. Partition Types

```elixir
# lib/flowstone/partition.ex
defmodule FlowStone.Partition do
  @type t :: Date.t() | DateTime.t() | tuple() | String.t()

  def serialize(partition)
  def deserialize(string, type)
  def generate_range(start, stop, step)
end
```

### 2. Tenant Context

```elixir
# lib/flowstone/tenant_context.ex
defmodule FlowStone.TenantContext do
  @doc "Execute function with tenant context set"
  def with_tenant(tenant_id, fun)

  @doc "Get current tenant from process"
  def current_tenant()

  @doc "Set tenant for RLS queries"
  def set_tenant_for_query(tenant_id)
end
```

### 3. Guard Behaviour

```elixir
# lib/flowstone/guard.ex
defmodule FlowStone.Guard do
  @callback can_access?(asset :: atom(), context :: map()) :: boolean()
  @callback can_materialize?(asset :: atom(), context :: map()) :: boolean()
end
```

### 4. Backfill API

```elixir
# lib/flowstone/backfill.ex
defmodule FlowStone.Backfill do
  def run(asset, opts)
  def status(backfill_id)
  def cancel(backfill_id)
end
```

## Test Design with Supertester

### Partition Tests

```elixir
defmodule FlowStone.PartitionTest do
  use Supertester.ExUnitFoundation, isolation: :full_isolation

  describe "serialize/1" do
    test "serializes Date" do
      assert FlowStone.Partition.serialize(~D[2025-01-15]) == "2025-01-15"
    end

    test "serializes DateTime" do
      dt = ~U[2025-01-15 14:30:00Z]
      assert FlowStone.Partition.serialize(dt) == "2025-01-15T14:30:00Z"
    end

    test "serializes tuple" do
      assert FlowStone.Partition.serialize({"tenant_1", "region_a", ~D[2025-01-15]}) ==
        "tenant_1|region_a|2025-01-15"
    end
  end

  describe "deserialize/2" do
    test "deserializes to Date" do
      assert FlowStone.Partition.deserialize("2025-01-15", :date) == ~D[2025-01-15]
    end

    test "deserializes tuple" do
      result = FlowStone.Partition.deserialize("a|b|2025-01-15", {:tuple, [:string, :string, :date]})
      assert result == {"a", "b", ~D[2025-01-15]}
    end
  end

  describe "generate_range/3" do
    test "generates date range" do
      partitions = FlowStone.Partition.generate_range(
        ~D[2025-01-01],
        ~D[2025-01-05],
        :day
      )

      assert length(partitions) == 5
      assert hd(partitions) == ~D[2025-01-01]
      assert List.last(partitions) == ~D[2025-01-05]
    end
  end
end
```

### Tenant Context Tests

```elixir
defmodule FlowStone.TenantContextTest do
  use FlowStone.DataCase, async: true
  import Supertester.OTPHelpers

  describe "with_tenant/2" do
    test "sets tenant for duration of function" do
      result = FlowStone.TenantContext.with_tenant("tenant_123", fn ->
        FlowStone.TenantContext.current_tenant()
      end)

      assert result == "tenant_123"
    end

    test "clears tenant after function completes" do
      FlowStone.TenantContext.with_tenant("temp_tenant", fn ->
        :ok
      end)

      assert FlowStone.TenantContext.current_tenant() == nil
    end

    test "handles exceptions without leaking tenant" do
      assert_raise RuntimeError, fn ->
        FlowStone.TenantContext.with_tenant("error_tenant", fn ->
          raise "boom"
        end)
      end

      assert FlowStone.TenantContext.current_tenant() == nil
    end
  end

  describe "RLS integration" do
    test "queries only return tenant data" do
      # Insert data for multiple tenants
      FlowStone.TenantContext.with_tenant("tenant_a", fn ->
        insert_materialization("asset_1", "p1")
      end)

      FlowStone.TenantContext.with_tenant("tenant_b", fn ->
        insert_materialization("asset_1", "p1")
      end)

      # Query with tenant_a context
      results = FlowStone.TenantContext.with_tenant("tenant_a", fn ->
        FlowStone.Materialization.Store.list_all()
      end)

      assert length(results) == 1
      assert hd(results).metadata["tenant_id"] == "tenant_a"
    end
  end
end
```

### Guard Tests

```elixir
defmodule FlowStone.GuardTest do
  use FlowStone.DataCase, async: true

  defmodule TierGuard do
    @behaviour FlowStone.Guard

    def can_access?(asset, %{tenant: tenant}) do
      required_tier = FlowStone.Asset.metadata(asset)[:required_tier]
      tier_level(tenant.tier) >= tier_level(required_tier)
    end

    def can_materialize?(asset, context), do: can_access?(asset, context)

    defp tier_level(:basic), do: 1
    defp tier_level(:premium), do: 2
    defp tier_level(:enterprise), do: 3
  end

  describe "tier-based access" do
    test "allows access when tier sufficient" do
      context = %{tenant: %{tier: :premium}}
      # Mock asset with required_tier: :basic
      assert TierGuard.can_access?(:basic_asset, context)
    end

    test "denies access when tier insufficient" do
      context = %{tenant: %{tier: :basic}}
      # Mock asset with required_tier: :enterprise
      refute TierGuard.can_access?(:enterprise_asset, context)
    end
  end
end
```

### Backfill Tests with Concurrent Harness

```elixir
defmodule FlowStone.BackfillTest do
  use FlowStone.DataCase, async: true
  import Supertester.OTPHelpers
  import Supertester.ChaosHelpers
  import Supertester.PerformanceHelpers

  describe "run/2" do
    test "queues all partitions" do
      partitions = Date.range(~D[2025-01-01], ~D[2025-01-10]) |> Enum.to_list()

      {:ok, backfill_id} = FlowStone.Backfill.run(:daily_report, partitions: partitions)

      status = FlowStone.Backfill.status(backfill_id)
      assert status.total == 10
      assert status.queued == 10
    end

    test "respects max_parallel limit" do
      partitions = Date.range(~D[2025-01-01], ~D[2025-01-100]) |> Enum.to_list()

      {:ok, _} = FlowStone.Backfill.run(:asset, partitions: partitions, max_parallel: 5)

      # Check that at most 5 jobs are running at once
      running = Oban.Job |> where(state: "executing") |> Repo.aggregate(:count)
      assert running <= 5
    end
  end

  describe "concurrent backfill stress test" do
    test "handles many partitions concurrently" do
      assert_performance(
        fn ->
          partitions = Date.range(~D[2024-01-01], ~D[2024-12-31]) |> Enum.to_list()
          FlowStone.Backfill.run(:asset, partitions: partitions, max_parallel: 20)
        end,
        max_time_ms: 5000,
        max_memory_bytes: 50_000_000
      )
    end
  end
end
```

## Implementation Order

1. **Partition module** - Serialization/deserialization
2. **TenantContext** - Process-local tenant tracking
3. **RLS migration** - PostgreSQL row-level security
4. **Guard behaviour** - Access control interface
5. **Backfill module** - Batch partition processing

## Success Criteria

- [ ] Partitions serialize/deserialize correctly
- [ ] Tenant context properly isolated
- [ ] RLS prevents cross-tenant access
- [ ] Guards enforce access control
- [ ] Backfill handles large partition ranges

## Commands

```bash
mix test test/flowstone/partition_test.exs
mix test test/flowstone/tenant_context_test.exs
mix coveralls.html
```

## Spawn Subagents

1. **Partition serialization** - Type handling
2. **TenantContext** - Process dictionary management
3. **RLS migration** - Database policies
4. **Backfill** - Job queuing and tracking
