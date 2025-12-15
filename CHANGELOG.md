# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

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

[0.2.0]: https://github.com/nshkrdotcom/flowstone/compare/v0.1.0...v0.2.0
[0.1.0]: https://github.com/nshkrdotcom/flowstone/releases/tag/v0.1.0
