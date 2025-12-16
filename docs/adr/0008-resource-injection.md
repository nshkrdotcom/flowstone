# ADR-0008: Resource Injection Pattern

## Status
Accepted

## Context

Assets often depend on external systems (DB pools, API clients, credentials). These dependencies should:

- be injected (not fetched from global config at execution time)
- be testable with overrides/mocks
- have an explicit lifecycle (setup/teardown) where appropriate

## Decision

### 1. Resource Behaviour

FlowStone defines a `FlowStone.Resource` behaviour that resources implement:

- `setup/1` (required)
- `teardown/1` (optional)
- `health_check/1` (optional)

Implementation: `lib/flowstone/resource.ex`.

### 2. Resource Manager

FlowStone provides `FlowStone.Resources`, a GenServer that:

- loads resource definitions from application config: `config :flowstone, :resources`
- normalizes config values such as `{:system, "ENV_VAR"}` into environment values
- calls `module.setup(config)` at startup and stores the resulting runtime values
- exposes `get/2`, `load/1`, and `override/2` for testability

Implementation: `lib/flowstone/resources.ex`.

### 3. Context Injection

`FlowStone.Context.build/4` injects only the resources an asset declares in `asset.requires`.

Implementation: `lib/flowstone/context.ex`.

> Note: `FlowStone.Asset` includes a `requires` field (`lib/flowstone/asset.ex`), but the current `FlowStone.Pipeline` DSL does not yet include a `requires/1` macro. Until then, host applications can:
> - populate `requires` by constructing assets programmatically, or
> - treat `resources` as optional and pass a custom `resource_server` that returns the desired subset.

### 4. Runtime Defaults and Overrides

The resource server can be set:

- globally via `config :flowstone, :resources_server`
- per-execution via `resource_server:` options passed to `FlowStone.materialize/2`

Workers must not propagate `nil` values that override defaults; options are only passed when explicitly non-nil.

## Consequences

### Positive

1. Assets remain testable via explicit dependency injection.
2. Resource initialization and configuration handling is centralized.
3. Environment variable wiring is supported without leaking secrets into compiled code.

### Negative

1. Without a DSL macro for `requires`, resource injection is currently “opt-in” via asset struct population.
2. Resource health checking is not scheduled by core; host applications must implement monitoring policies if required.

## References

- `lib/flowstone/resource.ex`
- `lib/flowstone/resources.ex`
- `lib/flowstone/context.ex`
