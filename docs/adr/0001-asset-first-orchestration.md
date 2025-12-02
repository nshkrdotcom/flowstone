# ADR-0001: Asset-First Orchestration Model

## Status
Accepted

## Context

Traditional workflow orchestration systems are task-centric: they define sequences of operations (steps, jobs, tasks) that execute in order. This creates several problems:

1. **Implicit Data Contracts**: The data flowing between steps is implicit, making lineage tracking and debugging difficult.
2. **Non-Idempotent Execution**: Re-running a workflow may produce different results depending on external state.
3. **Opaque Dependencies**: Understanding what data a step needs requires reading its implementation.
4. **Difficult Incremental Updates**: When source data changes, it's unclear which downstream results are invalidated.

Asset-first systems (pioneered by Dagster) invert this model: data artifacts are first-class citizens, and execution is derived from asset dependencies.

## Decision

FlowStone adopts an asset-first orchestration model where:

### 1. Assets are the Primary Abstraction

An **asset** is a persistent, versioned data artifact with:
- A unique name
- Explicit dependencies on other assets
- A materialization function that produces the asset's value
- Storage configuration (I/O manager)
- Optional partitioning scheme

```elixir
asset :daily_analytics do
  description "Aggregated analytics for dashboard consumption"
  depends_on [:raw_events, :user_profiles]
  io_manager :postgres
  partitioned_by :date

  execute fn context, %{raw_events: events, user_profiles: profiles} ->
    analytics = compute_analytics(events, profiles, context.partition)
    {:ok, analytics}
  end
end
```

### 2. DAG is Derived from Dependencies

The execution graph is automatically constructed from asset dependencies:
- No explicit step ordering required
- Cycle detection at definition time
- Automatic parallelization of independent branches

### 3. Materialization is the Unit of Execution

**Materialization** = computing and storing an asset's value for a specific partition:
- Recorded with timing, lineage, and metadata
- Enables reproducibility and audit trails
- Supports incremental re-computation

### 4. Lineage is First-Class

Every materialization records:
- Upstream assets consumed (with their partition versions)
- Downstream assets produced
- Execution metadata (duration, executor, node)

This enables:
- Impact analysis ("what breaks if this changes?")
- Root cause analysis ("where did this bad data come from?")
- Smart invalidation ("only recompute what's stale")

## Consequences

### Positive

1. **Debuggability**: Trace any data artifact back to its sources.
2. **Idempotency**: Re-materialization produces identical results (given same inputs).
3. **Incremental Updates**: Only recompute invalidated downstream assets.
4. **Self-Documenting**: Asset definitions describe data contracts explicitly.
5. **Testability**: Assets can be tested in isolation with mocked dependencies.

### Negative

1. **Learning Curve**: Developers familiar with task-centric systems need to shift mental models.
2. **Metadata Overhead**: Tracking lineage requires persistent storage and queries.
3. **Not for Streaming**: This model suits batch/micro-batch, not continuous streams (use Broadway for that).

### Anti-Patterns Avoided (from pipeline_ex analysis)

- **No YAML DSL**: Asset definitions are Elixir code with compile-time validation.
- **No String Keys**: All asset references are atoms, validated at compile time.
- **No Global Process State**: Context is passed explicitly, not stored in process dictionary.
- **No Runtime Type Discovery**: Asset registry knows all assets at compile time.

## References

- Dagster's Software-Defined Assets: https://docs.dagster.io/concepts/assets/software-defined-assets
- pipeline_ex anti-pattern analysis: YAML string keys, runtime type checking, implicit data contracts
