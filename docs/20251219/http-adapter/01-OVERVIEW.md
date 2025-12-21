# FlowStone v0.5.1 Enhancement Proposal

## Overview

This document proposes the **HTTP Resource Adapter** enhancement for FlowStone - a built-in HTTP client for REST API integrations.

This enables FlowStone to orchestrate external services via HTTP, making it suitable for microservice architectures and API-driven workflows.

## Motivation

### Current Limitation

FlowStone v0.5.0 provides excellent durability and I/O management, but lacks a built-in way to call REST APIs from assets. Users must implement their own HTTP client integration.

### Target Use Cases

- Call external microservices from pipeline assets
- Integrate with third-party APIs (payment providers, data services)
- Orchestrate services in distributed architectures
- Build pipelines that coordinate multiple HTTP services

## Proposed Changes

### HTTP Resource Adapter

New module: `FlowStone.HTTP.Client`

```elixir
# Register HTTP client as a resource
FlowStone.Resources.register(:api, FlowStone.HTTP.Client,
  base_url: "https://api.example.com",
  timeout: 30_000,
  headers: %{"Authorization" => "Bearer #{token}"},
  retry: %{max_attempts: 3, base_delay_ms: 1000}
)

# Use in asset
asset :fetch_data do
  requires [:api]

  execute fn ctx, _deps ->
    client = ctx.resources[:api]
    FlowStone.HTTP.Client.get(client, "/data/#{ctx.partition.id}")
  end
end
```

### Features

1. **Standard HTTP Methods**: GET, POST, PUT, PATCH, DELETE
2. **Automatic Retry**: Exponential backoff with jitter
3. **Rate Limit Handling**: Respects `Retry-After` headers
4. **Idempotency Keys**: Support for safe retries
5. **Telemetry Integration**: Full observability
6. **Resource Lifecycle**: Health checks, setup/teardown

## Document Structure

1. **01-OVERVIEW.md** (this document) - Executive summary
2. **02-HTTP-ADAPTER.md** - HTTP client resource design
3. **04-CONFIGURATION.md** - Configuration options and defaults
4. **05-TELEMETRY.md** - Observability and metrics

## Compatibility

- **Backwards Compatible**: All changes are additive
- **Elixir Version**: 1.14+
- **Dependencies**: Adds `req ~> 0.5`

## Version Target

This enhancement is proposed for FlowStone v0.5.1.

## Design Philosophy

The HTTP adapter follows FlowStone's core principles:

1. **Pluggable** - Can be swapped via configuration
2. **Observable** - Full telemetry for monitoring
3. **Resilient** - Built-in retry with backoff
4. **Simple** - Minimal API surface, sensible defaults

The adapter is designed for **orchestration**, not replacement of service logic. Complex operations (data processing, ML inference, etc.) should remain in dedicated services - FlowStone coordinates between them via HTTP.
