# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.4.0] - 2025-12-18

### Added

- Conditional routing DSL: `route` (block or fn), `choice`, `default`, `on_error`, `routed_from`, `optional_deps`
- Routing decision persistence: `flowstone_route_decisions`, `FlowStone.RouteDecision`, `FlowStone.RouteDecisions`
- Routing telemetry events: `[:flowstone, :route, :start | :stop | :error]`
- Example `conditional_routing_example.exs` and routing docs/README sections
- Migration `0009_create_route_decisions.exs`
- Parallel branches DSL: `parallel`, `branch`, `parallel_options`, `join`
- Parallel persistence tables: `flowstone_parallel_executions`, `flowstone_parallel_branches`
- Parallel join worker with durable coordination and IO-based joins
- Parallel telemetry events: `[:flowstone, :parallel, :start | :stop | :error | :branch_start | :branch_complete | :branch_fail]`
- Example `parallel_branches_example.exs` and updated docs/README sections
- Migration `0010_create_parallel_tables.exs`

### Changed

- Materialization status now includes `:skipped` for unselected routed assets
- Executor/materializer/worker honor persisted routing decisions and skip IO writes when not selected
- Optional dependencies resolve to `nil` and are ignored in dependency gating and lineage
- DAG validation enforces routed_from router assets, optional_deps subset, and implicit router edges
- Executor handles parallel pending results without storing IO; join worker records final materializations
- DAG adds virtual edges from parallel assets to branch finals; lineage includes branch finals on join

## [0.3.0] - 2025-12-18

### Added

#### Scatter (Dynamic Fan-Out)
- `FlowStone.Scatter` - Core module for runtime-discovered parallel execution
- `FlowStone.Scatter.Barrier` - Ecto schema tracking scatter completion
- `FlowStone.Scatter.Key` - Scatter key serialization and hashing
- `FlowStone.Scatter.Options` - Configurable scatter execution options
- `FlowStone.Scatter.Result` - Ecto schema for scatter instance results
- `FlowStone.Workers.ScatterWorker` - Oban worker for scatter instances
- DSL macros: `scatter`, `scatter_options`, `gather`, `max_concurrent`, `rate_limit`, `failure_threshold`, `failure_mode`
- Migration `0006_create_scatter_tables.exs` - Barrier and result tables

#### Signal Gate (Durable External Suspension)
- `FlowStone.SignalGate` - Core module for durable external suspension
- `FlowStone.SignalGate.Gate` - Ecto schema for signal gates
- `FlowStone.SignalGate.Token` - HMAC-signed token generation and validation
- `FlowStone.Workers.SignalGateTimeoutWorker` - Timeout handling worker
- `FlowStone.Workers.SignalGateSweeper` - Periodic sweep for missed timeouts
- DSL macros: `on_signal`, `on_timeout`
- Migration `0007_create_signal_gate_tables.exs` - Gate table with token indexing
- Secure callback URL generation with expiring signed tokens

#### Global Rate Limiting
- `FlowStone.RateLimiter` - Distributed rate limiting using Hammer and Postgres advisory locks
- Token bucket rate limiting with `check/2`, `with_limit/4`
- Semaphore-based concurrency control with `acquire_slot/2`, `release_slot/2`, `with_slot/4`
- Status inspection and bucket reset

#### Observability
- New telemetry events for Scatter: `[:flowstone, :scatter, :start | :complete | :failed | :cancel | :instance_complete | :instance_fail | :gather_ready]`
- New telemetry events for Signal Gate: `[:flowstone, :signal_gate, :create | :signal | :timeout | :timeout_retry | :cancel]`
- New telemetry events for Rate Limiting: `[:flowstone, :rate_limit, :check | :wait | :slot_acquired | :slot_released]`

#### Examples
- `scatter_example.exs` - Web scraping with parallel execution
- `signal_gate_example.exs` - External task integration with callbacks
- `rate_limiter_example.exs` - Rate limiting patterns

### Changed
- `FlowStone.Asset` struct now includes scatter and signal gate fields
- `FlowStone.Pipeline` DSL expanded with scatter and signal gate macros
- Updated documentation groups in mix.exs for new modules

## [0.2.0] - 2025-12-14

### Added
- `FlowStone.RunConfig` - ETS-based store for runtime configuration that survives Oban job persistence
- Migration for unique index on materializations (asset_name, partition, run_id)
- Safe atom handling throughout - no unbounded atom creation from external inputs
- SQL injection protection in Postgres IO manager with identifier validation
- Safe binary term decoding using `:erlang.binary_to_term/2` with `[:safe]` option

### Changed
- **BREAKING**: Oban job args are now JSON-safe - only strings, numbers, booleans, and maps
  - Asset names stored as strings (resolved via registry lookup)
  - Partitions serialized using tagged format
  - Runtime config (servers, IO settings) stored in RunConfig keyed by run_id
- **BREAKING**: Partition serialization uses tagged format for unambiguous round-trip
  - Dates: `d:2024-01-01`
  - DateTimes: `dt:2024-01-01T00:00:00Z`
  - Tuples: `t:base64_encoded_json`
  - Strings with special chars: `s:base64_encoded`
  - Legacy `|` separator format still supported for reading (backward compatibility)
- `FlowStone.Error` is now a proper `defexception` - can be raised directly
- Resource injection uses `get_with_default` - nil no longer overrides defaults
- Materializations use upsert logic with unique constraint for idempotent writes
- `MaterializationContext.latest/3` uses deterministic ordering (by started_at, then inserted_at)
- IO.Memory normalizes keys for consistent lookups regardless of partition format

### Fixed
- Oban args JSON round-trip - jobs survive database persistence correctly
- Resource server defaults not being overridden by nil values
- Partition serialization collision when strings contain `|` character
- Non-deterministic "latest" query in fallback MaterializationStore
- Potential SQL injection in Postgres IO manager table/column names
- Unsafe atom creation from persisted/external string inputs

### Security
- Identifier validation in Postgres IO manager prevents SQL injection
- Safe binary decoding prevents untrusted data attacks
- No unbounded atom creation from external inputs (use String.to_existing_atom/1)

## [0.1.0]

### Initial Release

[0.4.0]: https://github.com/nshkrdotcom/flowstone/compare/v0.3.0...v0.4.0
[0.3.0]: https://github.com/nshkrdotcom/flowstone/compare/v0.2.0...v0.3.0
[0.2.0]: https://github.com/nshkrdotcom/flowstone/compare/v0.1.0...v0.2.0
[0.1.0]: https://github.com/nshkrdotcom/flowstone/releases/tag/v0.1.0
