# Architectural Decision Record

**Status:** Design Proposal
**Date:** 2025-12-18

## ADR-001: Adopt Plugin Architecture

### Context

FlowStone has grown to 78 modules with tight coupling between:
- Core execution (Executor, Materializer)
- Data persistence (Ecto schemas, IO managers)
- Fan-out features (Scatter, Parallel)
- External integrations (S3, DynamoDB, Postgres)

This creates problems:
- Large dependency footprint for simple use cases
- Difficult to test core logic in isolation
- Hard to swap implementations (e.g., different databases)
- Challenging to maintain and extend

### Decision

Adopt a layered plugin architecture where:
- **Core** contains behaviors, protocols, and essential execution
- **Plugins** implement providers and optional features
- **Integrations** bridge FlowStone with external frameworks

### Rationale

1. **Proven Pattern**: The altar_ai/flowstone_ai separation demonstrates this works
2. **Incremental Migration**: Can be done without breaking changes
3. **Aligns with NSAI Vision**: Supports future IR compilation
4. **Community Extensibility**: Enables third-party plugins

### Consequences

**Positive:**
- Smaller core package
- Clearer boundaries
- Easier testing
- More extension points

**Negative:**
- More packages to manage
- Increased coordination overhead
- Learning curve for plugin authors

---

## ADR-002: Use Behaviors Over Protocols for Plugins

### Context

Two primary abstraction mechanisms in Elixir:
- **Behaviors**: Compile-time contracts with callbacks
- **Protocols**: Runtime dispatch with polymorphism

### Decision

Use **behaviors** for plugin contracts (IO.Manager, ItemReader, Coordinator).

Use **protocols** only for truly polymorphic operations (Error.Normalizer, Telemetry.Emitter).

### Rationale

1. **Behaviors enforce contracts**: Compile-time checking catches missing implementations
2. **Protocols add indirection**: Unnecessary for single-implementation dispatch
3. **Registry pattern works well**: Behaviors + registries = clean plugin system
4. **Consistency with OTP**: Behaviors are the standard OTP pattern

### Consequences

Plugin authors must implement all required callbacks. Optional callbacks are marked with `@optional_callbacks`.

---

## ADR-003: Registry-Based Resolution

### Context

Plugins need to be discovered and configured at runtime. Options:
1. Hard-coded module references
2. Application environment config
3. Registry-based resolution
4. Protocol-based dispatch

### Decision

Use **Agent-based registries** for plugin resolution:
- `FlowStone.IO.Registry` for IO managers
- `FlowStone.Scatter.ReaderRegistry` for ItemReaders

Registries are populated from application config on startup and can be modified at runtime.

### Rationale

1. **Config-driven**: Users configure via `config.exs`
2. **Runtime flexibility**: Can register implementations dynamically
3. **Testable**: Can swap implementations in tests
4. **Simple**: Agent-based state is easy to understand

### Consequences

- Registries must be started before plugin resolution
- Configuration errors surface at resolution time, not compile time
- Memory overhead of registry state (minimal)

---

## ADR-004: Ship Features Before Modularizing

### Context

Two approaches to new features:
1. **Design modular from start**: More upfront work, may not fit real needs
2. **Ship then modularize**: Faster delivery, informed refactoring

The brainstorm documents warn:
> "A2 - Designing IR before you have repeatable runs: IR design becomes fantasy when not exercised by real runs."

### Decision

Complete and ship routing, parallel, ItemReader, ItemBatcher as currently designed. Modularize in subsequent versions after production validation.

### Rationale

1. **Real usage informs design**: Actual pain points > theoretical concerns
2. **Faster delivery**: Users get features sooner
3. **Reduced risk**: Modularization is informed by experience
4. **Agile principle**: Working software over comprehensive documentation

### Consequences

- v0.4.0 ships with some coupling
- v0.5.0 introduces abstractions informed by v0.4.0 experience
- May need to adjust modularization based on what we learn

---

## ADR-005: Preserve Backward Compatibility

### Context

FlowStone has users. Breaking changes:
- Require migration effort
- Break existing pipelines
- Erode trust

### Decision

Maintain backward compatibility throughout v0.x modularization:
- Deprecate, don't remove
- Provide migration paths
- Keep default behaviors matching current

### Rationale

1. **User trust**: Don't break working code
2. **Gradual migration**: Users upgrade on their schedule
3. **Testing**: Compatibility is a testable property

### Consequences

- Deprecation warnings in v0.5.0, v0.6.0
- Deprecated code removed only in v1.0.0
- Some code duplication during transition
- More testing required

---

## ADR-006: Handoff as Separate Concern

### Context

Handoff is a distributed DAG executor in `/handoff`. Questions:
- Should Handoff be integrated into core FlowStone?
- Should FlowStone use Handoff for distribution?

### Decision

Keep Handoff as a **separate, independent project**. FlowStone may optionally integrate with Handoff in the future, but core FlowStone does not require Handoff.

### Rationale

1. **Different purposes**: FlowStone = asset orchestration, Handoff = distributed compute
2. **Simpler core**: FlowStone doesn't need distributed coordination in v0.x
3. **Optional integration**: Can add later as a plugin
4. **Brainstorm guidance**: "A5 - Distributed before you have one-host repeatability"

### Consequences

- Handoff remains in-tree but independent
- No FlowStone → Handoff dependency
- Future `flowstone_handoff` integration possible

---

## ADR-007: Telemetry as Protocol

### Context

Telemetry is called throughout FlowStone. Options:
1. Hard-coded `:telemetry` calls
2. Behavior-based telemetry
3. Protocol-based telemetry

### Decision

Use **protocol-based telemetry** (`FlowStone.Telemetry.Emitter`) to allow swapping telemetry backends.

### Rationale

1. **Polymorphism needed**: Different emitters (default, no-op, custom)
2. **Testing**: Can use no-op emitter in tests
3. **Flexibility**: Users can implement custom emitters
4. **Observability plugins**: Supports flowstone_observability extraction

### Consequences

- Slightly more indirection
- Protocol implementation overhead (minimal)
- Easier testing and customization

---

## ADR-008: Core Contains Default Implementation

### Context

If core only contains behaviors, users need plugins for basic functionality. Options:
1. Core has no implementations (pure abstraction)
2. Core has minimal defaults (in-memory, basic features)
3. Core has full implementations (current state)

### Decision

Core contains **minimal default implementations**:
- `FlowStone.IO.Memory` - In-memory storage
- `FlowStone.Scatter.ItemReaders.Custom` - Wraps user functions

These work without external dependencies.

### Rationale

1. **Usable out of box**: Don't require plugins for basic usage
2. **Testing friendly**: Defaults work in isolated tests
3. **Progressive complexity**: Start simple, add plugins as needed
4. **No external deps**: Memory and Custom need no databases/SDKs

### Consequences

- Core has some implementation code
- Clear boundary: default impls have no external deps
- Users can start without plugins

---

## ADR-009: DSL Extensions via Import

### Context

Plugins add DSL features (scatter, parallel, etc.). Options:
1. Auto-extend Pipeline DSL
2. Require explicit import
3. Macro injection

### Decision

Plugin DSL features require **explicit import** in pipeline modules:

```elixir
defmodule MyPipeline do
  use FlowStone.Pipeline
  import FlowStone.Scatter.DSL      # Explicit
  import FlowStone.Parallel.DSL     # Explicit
end
```

### Rationale

1. **Explicit is better**: Clear what DSL features are used
2. **No magic**: Imports are standard Elixir
3. **Composition**: Mix and match DSL modules
4. **Compile-time errors**: Missing import = clear error

### Consequences

- Slightly more boilerplate
- Clear dependencies
- Standard Elixir patterns

---

## ADR-010: Align with NSAI Vision for Future

### Context

The brainstorm documents describe NSAI.Work as a future unified scheduler. FlowStone will eventually compile to NSAI IRs.

### Decision

Design modular boundaries to **enable future IR compilation**:
- Asset struct captures all execution metadata
- Behaviors define contracts that could become IRs
- Registries can be replaced with IR-based resolution

Do NOT implement NSAI integration now.

### Rationale

1. **Future-proofing without over-engineering**
2. **Clean boundaries enable IR extraction**
3. **Brainstorm warns against premature IR design**
4. **Incremental evolution**: Modular first, IR later

### Consequences

- Behaviors designed with IR in mind
- No NSAI dependencies in v0.x/v1.x
- Clear path to future integration

---

## Summary Table

| ADR | Decision | Status |
|-----|----------|--------|
| 001 | Plugin architecture | Proposed |
| 002 | Behaviors over protocols for plugins | Proposed |
| 003 | Registry-based resolution | Proposed |
| 004 | Ship features before modularizing | In Progress |
| 005 | Preserve backward compatibility | Proposed |
| 006 | Handoff as separate concern | Proposed |
| 007 | Telemetry as protocol | Proposed |
| 008 | Core contains default implementations | Proposed |
| 009 | DSL extensions via explicit import | Proposed |
| 010 | Align with NSAI vision for future | Proposed |
