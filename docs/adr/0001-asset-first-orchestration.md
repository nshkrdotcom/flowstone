# ADR-0001: Asset-First Orchestration Model

## Status
Accepted

## Context

Task-centric orchestration (“steps in order”) tends to produce:

1. implicit data contracts between steps
2. weak lineage/auditability (“where did this come from?”)
3. hard-to-reason re-execution semantics

Asset-first systems invert the model: define the data artifacts (“assets”) and derive execution from their declared dependencies.

## Decision

### 1. Assets are the Primary Abstraction

An asset is a named data artifact with:

- a unique name (atom in code)
- explicit dependencies (`depends_on`)
- an execution function that computes the value (`execute`)

Assets are defined via the `FlowStone.Pipeline` DSL.

```elixir
defmodule MyApp.Pipeline do
  use FlowStone.Pipeline

  asset :raw do
    description "Raw input"
    execute fn _context, _deps -> {:ok, :raw} end
  end

  asset :clean do
    depends_on [:raw]
    execute fn _context, %{raw: raw} -> {:ok, {:clean, raw}} end
  end
end
```

### 2. The DAG is Derived From Dependencies

FlowStone builds an execution graph from `depends_on` and derives ordering from the DAG.

Implementation: `lib/flowstone/dag.ex`.

### 3. Materialization is the Unit of Execution and Audit

Materialization = computing (and storing) an asset’s value for a partition.

FlowStone records materialization metadata and lineage so that runs can be audited and impact can be analyzed.

Implementation:
- execution: `lib/flowstone/executor.ex`, `lib/flowstone/materializer.ex`
- persistence: `lib/flowstone/materializations.ex`, `lib/flowstone/lineage_persistence.ex`

### 4. Identifier Policy

Within Elixir code, assets are referenced by atoms. Across persistence and job boundaries (database rows, Oban args), assets are represented as strings and resolved safely against a known registry of assets (no unbounded atom creation).

## Consequences

### Positive

1. Dependencies and data contracts are explicit.
2. Lineage and auditability are natural outputs of the model.
3. Assets are testable in isolation.

### Negative

1. Users must adopt an asset-first mental model.
2. Correctness depends on persistence and consistent partition encoding.

## References

- `lib/flowstone/pipeline.ex`
- `lib/flowstone/dag.ex`
- `docs/adr/0002-dag-engine-persistence.md`
- `docs/adr/0003-partitioning-isolation.md`
