# ADR-0016: Runtime Serialization Boundaries and Identifier Safety

## Status
Accepted

## Context

FlowStone crosses persistence boundaries in multiple places:

- Oban job arguments are persisted as JSON.
- Materialization and lineage records persist to PostgreSQL.

BEAM-specific constraints apply at these boundaries:

- atoms are not garbage collected; converting untrusted strings to atoms can exhaust the VM
- arbitrary runtime terms (pids, functions, keyword lists with tuples) do not safely round-trip through JSON

## Decision

### 1. Treat “Persisted Boundaries” as String/JSON Domains

Across persisted boundaries (Oban args, DB columns), FlowStone represents identifiers as strings and uses explicit serialization for complex values (e.g., partitions).

### 2. Asset Identifiers

- In Elixir code and DSL, assets are named by atoms.
- In persisted representations (Oban args, DB rows), assets are represented as strings.
- Workers resolve asset strings safely against a known registry of assets and may convert to atoms only via `String.to_existing_atom/1` (or by returning an existing atom from registered asset structs).

FlowStone never uses `String.to_atom/1` on external/persisted inputs.

### 3. Partition Identifiers

Partitions are serialized to strings using `FlowStone.Partition.serialize/1` with a tagged encoding that avoids collisions and supports round-trip deserialization.

See ADR-0003 for the encoding details.

### 4. Non-JSON Runtime Configuration via `FlowStone.RunConfig`

Non-JSON runtime wiring (servers, full IO keyword lists, functions) is stored outside Oban args in `FlowStone.RunConfig` (ETS), keyed by `run_id`.

Workers resolve runtime configuration in priority order:

1. explicit `run_config` passed to synchronous execution
2. `FlowStone.RunConfig.get(run_id)`
3. application defaults

RunConfig is a best-effort cache with periodic cleanup; jobs that outlive the cache must still execute correctly using application defaults.

### 5. Test the Boundary

FlowStone includes tests that validate JSON round-trip properties and safe identifier resolution to prevent regressions.

## Consequences

### Positive

1. Oban jobs remain durable and restart-safe.
2. Eliminates a class of production failures caused by non-JSON args.
3. Prevents atom-table exhaustion vulnerabilities at persisted boundaries.

### Negative

1. Some values are less human-readable (encoded partitions, JSON-safe configs).
2. RunConfig is not a durable store; long-lived jobs may lose custom runtime wiring unless provided via application config.

## References

- `docs/adr/0003-partitioning-isolation.md`
- `docs/adr/0006-oban-job-execution.md`
- `lib/flowstone/partition.ex`
- `lib/flowstone/run_config.ex`
- `lib/flowstone/workers/asset_worker.ex`
