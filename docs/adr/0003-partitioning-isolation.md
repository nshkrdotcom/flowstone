# ADR-0003: Partition-Aware Execution and (Optional) Tenant Isolation

## Status
Accepted

## Context

Real-world orchestration frequently needs to run per:

- Time window (daily/hourly/etc.)
- Tenant/organization (multi-tenant SaaS)
- Region/category
- Composite key combining multiple dimensions

Partitions must also round-trip through:
- persistent metadata storage (PostgreSQL)
- cross-process/job boundaries (Oban args)

## Decision

### 1. Partitions are First-Class Values in Code, Stored as Strings

In Elixir code, partitions are regular values (e.g., `Date`, `DateTime`, tuples). For persistence and job arguments, partitions are serialized to strings.

### 2. Tagged Partition Encoding (Unambiguous Round-Trip)

FlowStone uses a tagged string encoding for partitions to avoid collisions and ambiguity (e.g. strings containing `|`):

| Partition Type | Elixir Value | Serialized |
|---|---|---|
| Date | `~D[2025-01-15]` | `d:2025-01-15` |
| DateTime | `~U[2025-01-15 02:00:00Z]` | `dt:2025-01-15T02:00:00Z` |
| NaiveDateTime | `~N[2025-01-15 02:00:00]` | `ndt:2025-01-15T02:00:00` |
| Tuple | `{"acme", "oslo", ~D[2025-01-15]}` | `t:<base64url(json)>` |
| String w/ reserved chars | `"a|b"` | `s:<base64url>` |
| Plain string | `"p1"` | `p1` |

Legacy `|`-separated tuple strings are still accepted for **reading** (deserialize) for backward compatibility, but are not emitted by `serialize/1`.

Implementation: `lib/flowstone/partition.ex`.

### 3. Backfill is Partition-Driven

Backfill executes the same asset across many partitions:

- Generate partitions from an explicit list or a supported range (e.g. `Date.range/2`)
- Optionally skip partitions that already have a successful materialization (`force: false`)
- Execute with bounded parallelism when running synchronously
- Enqueue jobs when running under Oban (Oban queue concurrency controls execution)

Implementation: `lib/flowstone.ex` and `lib/flowstone/backfill.ex`.

### 4. Tenant Isolation is Modeled, Not Enforced by Core

FlowStone core does not impose a specific multi-tenancy model. Tenant isolation can be achieved by:

- encoding tenant identity into the partition key (e.g. `{tenant_id, date}`)
- using separate storage namespaces (per-tenant tables/buckets/prefixes) in I/O manager configuration
- applying host-application access control and database RLS policies where required

## Consequences

### Positive

1. Partitions round-trip safely across storage and job boundaries.
2. Tagged encoding avoids ambiguous parsing and string collision hazards.
3. Tenant isolation can be implemented without constraining the core to one model.

### Negative

1. Encoded partitions (especially tuples) trade readability for correctness.
2. Host applications must implement their own tenant access control model.

## References

- `lib/flowstone/partition.ex`
- `lib/flowstone/backfill.ex`
- `lib/flowstone.ex`
