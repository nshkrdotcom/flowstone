# ADR-0015: External Integration Patterns

## Status
Proposed

## Context

Orchestration systems often integrate with:

- external APIs and services (including LLMs)
- data transformation systems (dbt, Spark)
- object stores and warehouses
- notification systems

Integrations must remain testable and should not compromise reliability or security.

## Decision

### 1. Prefer Integration via Existing Extension Points

FlowStone’s primary extension points for integrations are:

- **I/O managers** (`FlowStone.IO.Manager`) for reading/writing materialized data
- **resources** (`FlowStone.Resource`) for injectable clients (HTTP, DB pools, SDKs)
- **sensors** (`FlowStone.Sensor`) for polling triggers

Core FlowStone does not currently ship dedicated integration modules for specific vendors (LLMs, dbt, Python), but the above patterns are sufficient to build them in host applications or companion packages.

### 2. Reliability and Backpressure

When integrating with external systems:

- use bounded retries and explicit timeout values
- make retryability explicit via `FlowStone.Error.retryable`
- apply rate limiting/backpressure where needed (e.g., via `Hammer`)
- keep credentials/config in resource setup or application configuration, not in persisted job args

### 3. Security

External inputs must not:

- create atoms dynamically
- be interpolated into SQL identifiers without validation
- be decoded as Erlang terms without safe mode

## Consequences

### Positive

1. Integrations remain composable without bloating the core.
2. Host applications can choose their own vendor SDKs and security posture.

### Negative

1. Common integrations require additional packages or application code.

## References

- `docs/adr/0004-io-manager-abstraction.md`
- `docs/adr/0008-resource-injection.md`
- `docs/adr/0007-scheduling-sensors.md`
