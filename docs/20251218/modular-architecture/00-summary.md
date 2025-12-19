# FlowStone Modular Architecture: Executive Summary

**Status:** Design Proposal
**Author:** Architecture Analysis
**Date:** 2025-12-18
**FlowStone Version:** 0.5.0 (proposed)

## Purpose

This document set provides a comprehensive analysis of FlowStone's ideal modular boundaries, informed by:

1. **Brainstorm vision documents** (Dec 10-16, 2025) - IR strategy, NSAI architecture, integration patterns
2. **FlowStone codebase analysis** - 78 modules, 5 major subsystems
3. **Integration layer patterns** - flowstone_ai, synapse_ai, altar_ai architecture

## Core Insight

**"Bet on the Interface, not the Implementation."**

FlowStone should evolve from a monolithic asset orchestration library into a **layered architecture** where:

- **Core** defines behaviors, protocols, and execution semantics
- **Plugins** implement providers, adapters, and optional features
- **Integration layers** bridge FlowStone to external frameworks (AI, messaging, etc.)

## Key Findings

### 1. Current Coupling Issues

| Issue | Severity | Impact |
|-------|----------|--------|
| Scatter module (1159 lines) mixes orchestration + DB logic | HIGH | Hard to test/extend |
| Materializer handles 4 execution paths | HIGH | High cyclomatic complexity |
| ItemReader couples S3/DynamoDB/Postgres into core | HIGH | Blocks backend swapping |
| Telemetry calls hardcoded throughout | MEDIUM | Can't swap observability |
| RunConfig forces JSON serialization for Oban | MEDIUM | Limits worker flexibility |

### 2. Ideal Package Structure

```
flowstone (core)
├── Asset DSL, DAG, Execution
├── IO Manager behavior
├── Scatter behavior
├── Telemetry behavior
└── Behaviors & Protocols only

flowstone_scatter (plugin)
├── Scatter implementation
├── Barrier/Result persistence
└── ItemReader registry

flowstone_parallel (plugin)
├── Parallel branch execution
├── Join coordination
└── Execution/Branch persistence

flowstone_io_postgres (plugin)
flowstone_io_s3 (plugin)
flowstone_io_parquet (plugin)

flowstone_readers_aws (plugin)
├── S3 ItemReader
└── DynamoDB ItemReader

flowstone_observability (plugin)
├── Telemetry handlers
├── Prometheus metrics
└── Audit logging

flowstone_ai (integration)
├── Bridges FlowStone + altar_ai
└── AI-powered asset helpers
```

### 3. Breaking Changes Avoided

This proposal preserves the public API:

- `FlowStone.materialize/2` unchanged
- `FlowStone.Pipeline` macros unchanged
- Existing assets compile without modification
- Migration is opt-in via new packages

### 4. Alignment with NSAI Vision

The brainstorm documents emphasize:

> "Frameworks own developer experience; IRs own runtime semantics."

This architecture enables:

- **FlowStone as campaign runner** (deterministic orchestration)
- **Plugin-based capability expansion** (scatter, parallel, AI)
- **Future IR compilation** (FlowStone.Asset → NSAI.Work.Job)

## Document Set

| Document | Purpose |
|----------|---------|
| `01-ideal-boundaries.md` | Defines the clean modular boundaries |
| `02-core-vs-plugins.md` | What belongs in core vs. plugins |
| `03-integration-contracts.md` | Behavior/protocol specifications |
| `04-implementation-roadmap.md` | Phased migration plan |
| `05-decision-record.md` | Key architectural decisions |

## Recommendation

**Phase 0 (v0.4.0)**: Ship current features (routing, parallel, ItemReader, ItemBatcher) without restructuring. Validate the designs in production.

**Phase 1 (v0.5.0)**: Extract behaviors/protocols, introduce registries, maintain backward compatibility.

**Phase 2 (v0.6.0)**: Split packages, deprecate inline providers, ship plugin packages.

This approach follows the anti-pattern guidance from the brainstorm docs:

> "A2 - Designing IR before you have repeatable runs: IR design becomes fantasy when not exercised by real runs."

Ship features first, modularize after validation.
