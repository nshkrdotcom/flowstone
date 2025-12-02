# Architecture Decision Records

This directory contains Architecture Decision Records (ADRs) for FlowStone, documenting the key design decisions and their rationale.

## Index

| ADR | Title | Status | Summary |
|-----|-------|--------|---------|
| [0001](0001-asset-first-orchestration.md) | Asset-First Orchestration Model | Accepted | Data artifacts as first-class citizens, not steps |
| [0002](0002-dag-engine-persistence.md) | DAG Engine with Persistent Metadata | Accepted | Runic for DAG, Ecto/PostgreSQL for persistence |
| [0003](0003-partitioning-isolation.md) | Partition-Aware Execution and Tenant Isolation | Accepted | Time-based and custom partitioning with RLS |
| [0004](0004-io-manager-abstraction.md) | I/O Manager Abstraction | Accepted | Pluggable storage backends (Postgres, S3, Parquet) |
| [0005](0005-checkpoint-approval-gates.md) | Checkpoint and Approval Gate Pattern | Accepted | Human-in-the-loop approval workflows |
| [0006](0006-oban-job-execution.md) | Oban-Based Job Execution | Accepted | Reliable distributed job execution |
| [0007](0007-scheduling-sensors.md) | Scheduling and Sensor Framework | Accepted | Cron scheduling and event-driven triggers |
| [0008](0008-resource-injection.md) | Resource Injection Pattern | Accepted | Dependency injection for external resources |
| [0009](0009-error-handling.md) | Structured Error Handling | Accepted | Typed errors with retry intelligence |
| [0010](0010-elixir-dsl-not-yaml.md) | Elixir DSL, Not YAML | Accepted | Compile-time validated Elixir macros |
| [0011](0011-observability-telemetry.md) | Observability and Telemetry | Accepted | :telemetry, structured logging, audit trails |
| [0012](0012-liveview-ui.md) | Phoenix LiveView UI Integration | Accepted | Real-time dashboard with WebSocket updates |
| [0013](0013-testing-strategies.md) | Testing Strategies | Accepted | Mox, dependency injection, Oban testing |
| [0014](0014-lineage-reporting.md) | Lineage and Audit Reporting | Accepted | Complete data provenance and impact analysis |
| [0015](0015-external-integrations.md) | External System Integration Patterns | Accepted | LLM, Python/ML, dbt, notifications |

## How to Read

Each ADR follows this structure:

1. **Status**: Proposed, Accepted, Deprecated, or Superseded
2. **Context**: The problem or situation that led to this decision
3. **Decision**: What we decided to do and why
4. **Consequences**: The positive and negative outcomes of this decision

## Adding New ADRs

1. Create a new file: `NNNN-short-title.md`
2. Use the template below
3. Update this README's index table
4. Submit for review

### Template

```markdown
# ADR-NNNN: Title

## Status
Proposed

## Context
[Describe the problem, constraints, and forces at play]

## Decision
[Describe the decision and rationale]

## Consequences

### Positive
[List benefits]

### Negative
[List drawbacks]

## References
[Links to relevant resources]
```

## Design Principles

These ADRs collectively embody several key principles:

1. **Asset-First**: Data artifacts are the contract, not execution steps
2. **BEAM-Native**: Leverage OTP supervision, fault tolerance, and hot code reload
3. **Explicit over Implicit**: Dependencies, resources, and context are explicit
4. **Testability**: Every component can be tested in isolation
5. **Observability**: Telemetry, structured logging, and audit trails built-in
6. **Compile-Time Safety**: Catch errors before runtime via Elixir DSL

## Anti-Patterns Avoided

Based on analysis of pipeline_ex and similar systems, FlowStone specifically avoids:

- YAML configuration with string keys (ADR-0010)
- Global test mode via environment variables (ADR-0013)
- Process dictionary for context passing (ADR-0008)
- Generic exception handling with 70+ rescue blocks (ADR-0009)
- Code duplication across step implementations (ADR-0001)
- Monolithic validation functions (ADR-0010)
- Silent failures and masked errors (ADR-0009)
