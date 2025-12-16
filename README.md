<p align="center">
  <img src="assets/flowstone.svg" alt="FlowStone Logo" width="220" height="248">
</p>

# FlowStone

[![CI](https://github.com/nshkrdotcom/flowstone/actions/workflows/ci.yml/badge.svg)](https://github.com/nshkrdotcom/flowstone/actions/workflows/ci.yml)
[![Hex.pm](https://img.shields.io/hexpm/v/flowstone.svg)](https://hex.pm/packages/flowstone)
[![Hex Docs](https://img.shields.io/badge/hex-docs-blue.svg)](https://hexdocs.pm/flowstone)
[![License](https://img.shields.io/hexpm/l/flowstone.svg)](https://github.com/nshkrdotcom/flowstone/blob/main/LICENSE)

**Asset-first orchestration for the BEAM.**

FlowStone is an orchestration library for Elixir that treats *assets* (data artifacts) as the primary abstraction. Execution order is derived from explicit dependencies, and materializations can be tracked and queried via PostgreSQL when enabled.

## Status

FlowStone is in **alpha**. Core execution, persistence primitives, and safety hardening are implemented, but some higher-level platform features (e.g., a bundled UI, fully resumable approvals, richer DSL surface) are still evolving.

## Installation

Add to your `mix.exs`:

```elixir
def deps do
  [
    {:flowstone, "~> 0.2.0"}
  ]
end
```

## Quick Start

Define a pipeline:

```elixir
defmodule MyApp.Pipeline do
  use FlowStone.Pipeline

  asset :raw do
    execute fn _context, _deps -> {:ok, :raw} end
  end

  asset :report do
    depends_on [:raw]
    execute fn _context, %{raw: raw} -> {:ok, {:report, raw}} end
  end
end
```

Register and materialize (using the in-memory IO manager):

```elixir
{:ok, _} = FlowStone.Registry.start_link(name: MyRegistry)
{:ok, _} = FlowStone.IO.Memory.start_link(name: MyMemory)

FlowStone.register(MyApp.Pipeline, registry: MyRegistry)

io = [config: %{agent: MyMemory}] # uses default :memory IO manager

FlowStone.materialize(:report,
  partition: ~D[2025-01-15],
  registry: MyRegistry,
  io: io,
  resource_server: nil
)

{:ok, {:report, :raw}} = FlowStone.IO.load(:report, ~D[2025-01-15], io)
```

Materialize an asset and its dependencies:

```elixir
FlowStone.materialize_all(:report,
  partition: ~D[2025-01-15],
  registry: MyRegistry,
  io: io,
  resource_server: nil
)
```

Backfill across partitions:

```elixir
FlowStone.backfill(:report,
  partitions: Date.range(~D[2025-01-01], ~D[2025-01-07]),
  registry: MyRegistry,
  io: io,
  resource_server: nil,
  max_parallel: 4
)
```

## Execution Model

- If **Oban is running**, `FlowStone.materialize/2` enqueues a job and returns `{:ok, %Oban.Job{}}`.
- If **Oban is not running**, `FlowStone.materialize/2` executes synchronously and returns `:ok` or `{:error, reason}`.

Oban job args are JSON-safe. Non-JSON runtime wiring (servers, IO keyword options, etc.) is stored in `FlowStone.RunConfig` keyed by `run_id` and is resolved by the worker with application-config fallback.

## Documentation

- Design overview: `docs/design/OVERVIEW.md`
- ADR index: `docs/adr/README.md`
- 2025-12-14 review notes: `docs/20251214/review/README.md`

## Contributing

Contributions are welcome. Please read the ADRs first to understand the current decisions and constraints.

## License

MIT
