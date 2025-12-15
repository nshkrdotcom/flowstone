## Prompt for New Agent: FlowStone Review Remediation + Release Prep (2025-12-14)

You are a coding agent working in the flowstone Elixir repo. Your job is to implement the remediation work described
in the review docs, using TDD where applicable, and finish with a clean release-ready state: docs updated, version
bumped, changelog entry added, and all quality gates passing (tests + no warnings + Dialyzer clean).

### Non-Negotiable Success Metrics (Definition of Done)

You are done only when ALL of the following are true:

1. mix format --check-formatted passes
2. mix compile --warnings-as-errors passes (no warnings)
3. mix test passes (all tests, no failures)
4. mix credo --strict passes (no issues)
5. mix dialyzer passes with zero warnings
6. Docs updated to reflect reality (README + relevant design/ADR docs)
7. Version bumped to x.(y+1).0 everywhere required
8. CHANGELOG.md includes a 2025-12-14 entry for the new version

———

# 1) Required Reading (Do This Before Coding)

Read these files fully to understand expectations, existing architecture, and mismatches:

## Review Requirements (Primary Source of Work)

- docs/20251214/review/README.md
- docs/20251214/review/01-architecture-and-docs-gap.md
- docs/20251214/review/02-execution-and-oban.md
- docs/20251214/review/03-persistence-and-consistency.md
- docs/20251214/review/04-security-and-safety.md

## Product + Architecture Docs

- README.md
- docs/design/OVERVIEW.md
- All ADRs: docs/adr/*.md
- If present, read everything under docs/src/ (if the directory doesn’t exist, note that in your final summary and
  instead treat docs/ as the doc source).

## Code You Must Understand (At Minimum)

- mix.exs (aliases + deps + current version)
- lib/flowstone.ex (API surface, Oban args construction)
- lib/flowstone/workers/asset_worker.ex (Oban execution assumptions)
- lib/flowstone/executor.ex, lib/flowstone/materializer.ex
- lib/flowstone/error.ex, lib/flowstone/result.ex
- lib/flowstone/partition.ex
- lib/flowstone/materializations.ex, lib/flowstone/materialization_context.ex, lib/flowstone/materialization_store.ex
- lib/flowstone/approvals.ex, lib/flowstone/checkpoint.ex, lib/flowstone/workers/checkpoint_timeout.ex
- lib/flowstone/lineage_persistence.ex, lib/flowstone/lineage.ex
- lib/flowstone/io/postgres.ex
- Migrations in priv/repo/migrations/*.exs

## Tests

Skim the entire test/flowstone/ tree so you can extend existing patterns instead of inventing new ones.

———

# 2) Safety / Engineering Constraints

## Security/Safety Requirements (Must Fix, Not Optional)

- Eliminate unbounded atom creation at runtime boundaries (String.to_atom/1 on external/persisted inputs).
- Prevent SQL injection risks in Postgres IO manager (unsafe identifier interpolation).
- Use safe decoding for Erlang terms if binary term formats remain supported (binary_to_term(..., [:safe])).
- Fix partition serialization collisions (string containing | must round-trip correctly).

## Operational Correctness Requirements (Must Fix)

- Oban job args must be JSON round-trippable. No tuples, no keywords, no atoms/pids/modules inside args that are
  expected to survive persistence.
- Fix resource injection defaults: do not override defaults with nil propagated via Oban args/options.
- Fix FlowStone.Result.unwrap!/1 correctness (align with ADR-0009; FlowStone.Error must be raisable or unwrap must
  raise a valid exception).
- Add missing persistence invariants (uniqueness where identity demands it; deterministic “latest” in fallback store;
  eliminate inconsistent Repo-vs-fallback decisions).

## Scope Control

- Fix issues covered by the review docs. Don’t add unrelated features.
- Avoid large refactors unless required to satisfy the metrics safely and cleanly.

———

# 3) Iterative Process (How You Should Work)

Work in small increments. Each iteration must follow:

1. Write/extend a failing test first (TDD) when feasible.
2. Implement the smallest correct fix.
3. Run mix test (fast feedback).
4. Keep types/specs updated as you go to avoid Dialyzer debt.
5. Only then move to the next item.

At the end of each major milestone, run the full quality gate:

- mix format --check-formatted
- mix compile --warnings-as-errors
- mix credo --strict
- mix dialyzer
- mix test

———

# 4) Implementation Requirements (What “Implement All of This” Means)

Treat the review docs as your task list. Below is a prioritized, explicit checklist you must complete.

## P0: Oban Args Are Not JSON-Safe (Production-Blocking)

### Goals

- Oban job args must be valid JSON and must round-trip through DB persistence without type loss that breaks runtime
  behavior.

### Required Work

- Redesign the Oban args payload used by FlowStone.materialize/2, materialize_async/2, materialize_all/2, and
  backfill/2.
- Remove/replace anything that can’t safely persist in JSON:
    - atoms, tuples/keyword lists, module references, pids, servers, etc.
- Make AssetWorker.perform/1 resilient to persisted types:
    - parse/validate asset identifiers safely
    - parse/deserialize partition in a deterministic, reversible way
    - load execution config from a safe source (see below)

### Strongly Recommended Design (Preferred)

Use a “run config” indirection:

- Store execution options in a durable record keyed by run_id (or similar).
- Oban args contain only stable identifiers (e.g. asset_name, partition_key, run_id).
- Worker loads config by run_id from DB (or fallback store) rather than embedding complex runtime terms in args.

### TDD Requirements

- Add a test that proves args are JSON round-trippable (e.g., encode/decode via Jason, or insert + fetch the job from
  Oban DB tables if feasible).
- Add tests covering the “realistic persisted path” (not only testing: :inline semantics).

## P0: Resource Injection Default Is Broken

### Goals

- Default resource server behavior must work in both synchronous and Oban execution paths.

### Required Work

- Ensure nil does not override defaults (either omit keys entirely or treat nil as “unset”).
- Add tests that validate resources load correctly when not explicitly overridden.

## P0: Fix FlowStone.Result.unwrap!/1 / Align Error Model with ADR-0009

### Goals

- unwrap!/1 must reliably raise a valid exception.
- Align implementation with ADR intent (ADR-0009 expects FlowStone.Error to be a defexception).

### Required Work

- Implement FlowStone.Error as an exception (or adjust unwrap!/1 to raise a valid exception wrapper).
- Update/extend tests to cover unwrap behavior and error message correctness.

## P0: Remove Unsafe Atom Creation

### Goals

- No String.to_atom/1 on persisted/untrusted inputs.

### Required Work

- Replace String.to_atom/1 in:
    - lib/flowstone/workers/asset_worker.ex
    - lib/flowstone/lineage.ex
    - lib/flowstone/lineage_persistence.ex
- Use one of:
    - String.to_existing_atom/1 with safe error handling, OR
    - return strings externally (API change) and convert only internally via a controlled registry lookup

### TDD Requirements

- Add tests demonstrating unknown asset strings do not create atoms and are handled safely.

———

## P1: Persistence Invariants + Deterministic “Latest”

### Required Work

- Add missing uniqueness constraints for materializations (identity should not allow duplicates). Implement matching
  upsert logic.
    - Likely: unique index on {asset_name, partition, run_id}.
- Fix MaterializationContext.latest/3 fallback store correctness:
    - ensure deterministic ordering and correct “latest” selection.

### TDD Requirements

- Add tests that would fail under the old nondeterministic store.
- Add tests (or constraint assertions) for uniqueness behavior.

———

## P1: Consistency Model for “Store Output” vs “Record Metadata”

### Goals

- Eliminate partial side-effects and “crash mid-flight” behavior.
- Avoid :ok = ... assertions that can crash after side effects occur.

### Required Work

- Define and implement a clear consistency approach:
    - if best-effort is accepted: ensure failures are recorded and surfaced consistently; never crash from :ok =
      assertions
    - if metadata-authoritative: ensure metadata and lineage/audit writes are coherent and retriable
- Ensure error recording doesn’t cause redundant/competing persistence writes (Executor vs ErrorRecorder).

### TDD Requirements

- Add targeted tests that simulate IO/store failures and assert metadata status is correct and stable.

———

## P1: Approvals/Checkpoints Must Be Executable (Not Dead-End)

### Goals

- “Waiting approval” must not end as a discarded Oban job with no resume story.

### Required Work

- Redesign the approval flow so an asset that requests approval can:
    - persist approval request once (idempotent)
    - enter a stable “waiting approval” state
    - resume or complete deterministically when approval is decided (approve/reject/timeout)
- Wire flowstone_approvals.materialization_id (or provide another strong link) so approvals relate to a specific
  materialization identity.
- Ensure the scheduler/timeout worker behavior matches the chosen state machine.

### TDD Requirements

- Tests for:
    - approval requested once
    - job snoozes (or otherwise waits) without discarding
    - after approval/rejection, job reaches correct terminal behavior and status updates

———

## P1: Postgres IO Manager Safety

### Required Work

- Prevent SQL injection from table / partition_column config.
    - Validate allowed identifier shapes or implement safe quoting/escaping for identifiers (including schema-
      qualified names).
- Ensure binary decoding uses safe mode if binary format supported:
    - :erlang.binary_to_term(binary, [:safe])

### TDD Requirements

- Tests that invalid identifiers are rejected.
- Tests that binary decoding uses safe mode (and behaves correctly).

———

## P2: Partition Serialization Must Round-Trip Without Collisions

### Required Work

- Redesign FlowStone.Partition.serialize/1 and deserialize/1 so a string containing | does not become a tuple on
  deserialize.
- Prefer an unambiguous encoding scheme (tagged encoding / JSON / base64-safe binary with safe decode).
- Document any compatibility impact (if stored DB values change, note migration strategy).

### TDD Requirements

- Add round-trip tests for:
    - strings containing |
    - tuples with string elements containing |
    - Date/DateTime/NaiveDateTime
    - nested tuples if you continue to support them

———

## P2: API Semantics Clarity (Sync vs Async)

### Required Work

- Resolve confusion where materialize/2 claims synchronous but queues via Oban if running.
- Make return types consistent and predictable.
- Update README and docs accordingly.

### TDD Requirements

- Add/adjust tests for return shape and behavior under Oban-running vs not-running modes.

———

# 5) Documentation + Release Engineering Requirements

## Update README and Docs

You must update documentation so that it reflects actual behavior after your changes:

- README.md
- docs/design/OVERVIEW.md
- relevant ADRs in docs/adr/*.md
- add an “Implemented vs Planned” matrix somewhere appropriate if there are still stubs

Be explicit about:

- the execution model (sync vs async)
- storage/metadata consistency guarantees
- partition encoding format
- approval semantics
- any API changes (especially if you return strings instead of atoms)

## Version Bump (x.y++.0)

Current version is 0.1.0 in mix.exs (@version). You must bump to:

- 0.2.0 (x=0, y=1 → y++ => 2, patch reset to 0)

Update all locations that reference the version, at minimum:

- mix.exs (@version)
- README.md (installation snippet {:flowstone, "~> ..."} and any other mentions)

## Changelog Entry (2025-12-14)

Update CHANGELOG.md (Keep a Changelog format) to include:

- ## [0.2.0] - 2025-12-14
- Bullet points covering the remediation work (Oban args fix, resource defaults, error/unwrap fix, atom safety, SQL
  safety, partition encoding, approvals state machine, persistence invariants, docs alignment).
- Add/update the version link references at the bottom.

———

# 6) Suggested Command Loop (Use Frequently)

Baseline / fast loop:

- mix test

Quality gate loop (must pass at end):

- mix format --check-formatted
- mix compile --warnings-as-errors
- mix credo --strict
- mix dialyzer
- mix test

If DB is required for tests:

- Ensure Postgres is running and config matches config/test.exs (or provide a documented local setup).

———

# 7) Final Deliverables

When finished, provide:

1. A short summary of what changed and why (by area).
2. A list of the key files modified.
3. Confirmation of success metrics with the exact commands run and outcomes.
4. Notes on any backward-incompatible changes (expected for minor bump, but must be documented).

Use the review docs as your checklist; nothing in docs/20251214/review/*.md should remain unaddressed unless you
explicitly document why and propose a follow-up plan.
