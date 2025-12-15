# FlowStone Review (2025-12-14)

This review focuses on **fundamental design and implementation flaws** that materially impact correctness, safety, operability, and maintainability. It is not a feature checklist.

## Executive Summary

FlowStone’s current implementation reads as an MVP prototype, but it has several **production-blocking correctness issues**, most notably around **Oban job argument serialization** and **runtime dependency injection**. Some implementation choices also diverge from the project’s own ADRs and design overview, which increases long-term risk.

## Highest-Risk Findings (Fix Before “Real” Usage)

1. **Oban job args are not JSON-safe and don’t round-trip**
   - `FlowStone.build_args/2` includes atoms, keyword lists (tuples), and module/process names in `args` (`lib/flowstone.ex`).
   - Oban persists `args` as JSON; these values won’t survive a DB round-trip (and some can’t be encoded at all).
   - `FlowStone.Workers.AssetWorker.perform/1` assumes the decoded values are still atoms/keywords (`lib/flowstone/workers/asset_worker.ex`).

2. **Default resource injection is effectively disabled**
   - `FlowStone.build_args/2` always includes `"resource_server" => nil` unless explicitly passed.
   - The worker forwards `resource_server: nil`, which overrides Executor defaults and results in empty `context.resources` (`lib/flowstone.ex`, `lib/flowstone/workers/asset_worker.ex`, `lib/flowstone/executor.ex`, `lib/flowstone/context.ex`).

3. **`FlowStone.Result.unwrap!/1` is broken**
   - `FlowStone.Error` is a plain struct, but `Result.unwrap!/1` uses `raise(err)` (`lib/flowstone/result.ex`).
   - This diverges from ADR-0009, which specifies `FlowStone.Error` should be a `defexception` (`docs/adr/0009-error-handling.md`).

4. **Materialization metadata isn’t transactionally consistent with output storage**
   - `Executor.materialize/2` performs side effects (IO store, DB writes, lineage recording) without a transactional boundary and uses `:ok = ...` assertions that can crash mid-flight (`lib/flowstone/executor.ex`).

## Document Index

- `docs/20251214/review/01-architecture-and-docs-gap.md`
- `docs/20251214/review/02-execution-and-oban.md`
- `docs/20251214/review/03-persistence-and-consistency.md`
- `docs/20251214/review/04-security-and-safety.md`

## Scope Notes

- Review covered `lib/`, `priv/repo/migrations/`, `docs/` (especially ADRs), and `test/`.
- The `dagster/` subtree appears to be a full vendored repo and is treated as **out-of-scope** for FlowStone’s internal correctness, but it is called out as a repo hygiene risk in `01-architecture-and-docs-gap.md`.

