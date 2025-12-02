# ADR-0003: Partition-Aware Execution and Tenant Isolation

## Status
Accepted

## Context

Real-world orchestration requires:

1. **Time-Based Processing**: Daily, hourly, or custom time windows.
2. **Multi-Tenant SaaS**: Isolated execution per customer/organization.
3. **Regional Segmentation**: Process data per geographic region.
4. **Backfill Support**: Recompute historical partitions without affecting current data.

We need a flexible partitioning model that supports these use cases while maintaining strict isolation.

## Decision

### 1. Partition as First-Class Concept

A **partition** is a subdivision of an asset's data space, typically representing:
- A time period (date, hour, week)
- A tenant/organization
- A region or category
- A composite key combining multiple dimensions

```elixir
# Time-based partitioning
asset :daily_metrics do
  partitioned_by :date

  execute fn context, deps ->
    date = context.partition  # ~D[2025-01-15]
    {:ok, compute_metrics_for_date(date)}
  end
end

# Custom partitioning (tenant x region x date)
asset :regional_report do
  partitioned_by :custom

  partition_fn fn config ->
    for tenant <- config.tenants,
        region <- tenant.regions,
        date <- Date.range(config.start_date, config.end_date) do
      {tenant.id, region.id, date}
    end
  end

  execute fn context, deps ->
    {tenant_id, region_id, date} = context.partition
    with_tenant_context(tenant_id, fn ->
      {:ok, generate_report(region_id, date)}
    end)
  end
end
```

### 2. Partition Key Structure

Partitions are serialized to strings for storage but typed in code:

| Partition Type | Elixir Value | Serialized |
|---------------|--------------|------------|
| Date | `~D[2025-01-15]` | `"2025-01-15"` |
| DateTime | `~U[2025-01-15 02:00:00Z]` | `"2025-01-15T02:00:00Z"` |
| Tuple | `{"acme", "oslo", ~D[2025-01-15]}` | `"acme|oslo|2025-01-15"` |
| Custom | `%MyPartition{...}` | JSON-encoded |

### 3. Backfill Support

```elixir
# Backfill a date range
FlowStone.backfill(:daily_metrics,
  start_partition: ~D[2024-01-01],
  end_partition: ~D[2024-12-31],
  max_parallel: 10
)

# Backfill specific partitions
FlowStone.backfill(:regional_report,
  partitions: [
    {"acme", "oslo", ~D[2025-01-01]},
    {"acme", "oslo", ~D[2025-01-02]}
  ]
)
```

Backfill execution:
1. Generate all partition keys from range/list
2. Check existing materializations (skip if `force: false`)
3. Queue as Oban jobs with configurable parallelism
4. Track progress in real-time via PubSub

### 4. Tenant Isolation

For multi-tenant SaaS deployments, isolation is enforced at multiple levels:

#### Level 1: Partition Key Includes Tenant

```elixir
# Partition key always includes tenant
context.partition = {"tenant_123", "2025-01-15"}
```

#### Level 2: Row-Level Security (RLS)

```sql
-- PostgreSQL RLS policy
ALTER TABLE flowstone_materializations ENABLE ROW LEVEL SECURITY;

CREATE POLICY tenant_isolation ON flowstone_materializations
  USING (
    (metadata->>'tenant_id')::uuid = current_setting('flowstone.tenant_id', true)::uuid
  );
```

```elixir
defmodule FlowStone.TenantContext do
  def with_tenant(tenant_id, fun) do
    Repo.query!("SET LOCAL flowstone.tenant_id = $1", [tenant_id])
    fun.()
  end
end
```

#### Level 3: I/O Manager Isolation

```elixir
asset :tenant_data do
  io_manager :s3

  # Bucket per tenant
  bucket fn context ->
    {tenant_id, _date} = context.partition
    "data-#{tenant_id}"
  end

  # Or path isolation within shared bucket
  path fn context ->
    {tenant_id, date} = context.partition
    "tenants/#{tenant_id}/data/#{date}.parquet"
  end
end
```

### 5. Access Control (Guard Framework)

For tiered access to assets:

```elixir
defmodule FlowStone.Guard do
  @callback can_access?(asset :: atom(), context :: map()) :: boolean()
  @callback can_materialize?(asset :: atom(), context :: map()) :: boolean()
end

defmodule MyApp.TierGuard do
  @behaviour FlowStone.Guard

  def can_access?(asset, %{tenant: tenant}) do
    required_tier = FlowStone.Asset.metadata(asset)[:required_tier]
    tier_level(tenant.tier) >= tier_level(required_tier)
  end

  defp tier_level(:basic), do: 1
  defp tier_level(:standard), do: 2
  defp tier_level(:premium), do: 3
  defp tier_level(:enterprise), do: 4
end
```

```elixir
asset :advanced_analytics do
  metadata %{required_tier: :premium}
  tags ["tier:premium", "tier:enterprise"]

  execute fn context, deps -> ... end
end
```

## Consequences

### Positive

1. **Flexible Partitioning**: Support for time, tenant, region, or any composite key.
2. **Parallel Backfill**: Process historical data efficiently.
3. **Multi-Tenant Ready**: Isolation enforced at storage and query levels.
4. **Tiered Features**: Control asset access by subscription tier.

### Negative

1. **Partition Key Discipline**: Developers must consistently include tenant in partition keys.
2. **RLS Overhead**: Row-level security adds query planning cost.
3. **Configuration Complexity**: Multi-tenant requires careful I/O manager setup.

### Anti-Patterns Avoided

- **No Process Dictionary for Tenant Context**: Use explicit `with_tenant/2` function.
- **No Global Tenant State**: Tenant ID always passed in context or partition.
- **No Shared Checkpoints**: Each tenant's materializations are isolated.

## References

- PostgreSQL Row-Level Security: https://www.postgresql.org/docs/current/ddl-rowsecurity.html
- pipeline_ex issue: shared checkpoint files across tenants
