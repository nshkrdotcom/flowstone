# Telemetry Reference

## Overview

This document describes telemetry events emitted by the HTTP adapter. FlowStone uses the standard Erlang `:telemetry` library for observability.

## HTTP Adapter Events

### Request Lifecycle Events

#### `[:flowstone, :http, :request, :start]`

Emitted when an HTTP request begins.

| Measurement | Type | Description |
|-------------|------|-------------|
| `system_time` | `integer()` | System time when request started |

| Metadata | Type | Description |
|----------|------|-------------|
| `method` | `atom()` | HTTP method (`:get`, `:post`, etc.) |
| `url` | `String.t()` | Full request URL |
| `path` | `String.t()` | Request path |
| `base_url` | `String.t()` | Base URL of the client |

#### `[:flowstone, :http, :request, :stop]`

Emitted when an HTTP request completes successfully.

| Measurement | Type | Description |
|-------------|------|-------------|
| `duration` | `integer()` | Duration in native time units |
| `status` | `integer()` | HTTP status code |

| Metadata | Type | Description |
|----------|------|-------------|
| `method` | `atom()` | HTTP method |
| `url` | `String.t()` | Full request URL |
| `path` | `String.t()` | Request path |
| `base_url` | `String.t()` | Base URL |

#### `[:flowstone, :http, :request, :error]`

Emitted when an HTTP request fails.

| Measurement | Type | Description |
|-------------|------|-------------|
| `duration` | `integer()` | Duration in native time units |
| `error` | `term()` | Error reason |

| Metadata | Type | Description |
|----------|------|-------------|
| `method` | `atom()` | HTTP method |
| `url` | `String.t()` | Full request URL |
| `path` | `String.t()` | Request path |
| `base_url` | `String.t()` | Base URL |

### Retry Events

#### `[:flowstone, :http, :retry]`

Emitted when a request is retried.

| Measurement | Type | Description |
|-------------|------|-------------|
| `attempt` | `integer()` | Current attempt number |
| `delay_ms` | `integer()` | Delay before retry |

| Metadata | Type | Description |
|----------|------|-------------|
| `method` | `atom()` | HTTP method |
| `url` | `String.t()` | Request URL |
| `reason` | `term()` | Retry reason |

## Attaching Handlers

### Basic Handler

```elixir
defmodule MyApp.Telemetry do
  require Logger

  def attach_handlers do
    :telemetry.attach_many(
      "myapp-flowstone-handlers",
      [
        [:flowstone, :http, :request, :stop],
        [:flowstone, :http, :request, :error]
      ],
      &handle_event/4,
      nil
    )
  end

  def handle_event([:flowstone, :http, :request, :stop], measurements, metadata, _config) do
    duration_ms = System.convert_time_unit(measurements.duration, :native, :millisecond)

    Logger.info("HTTP #{metadata.method} #{metadata.path}",
      status: measurements.status,
      duration_ms: duration_ms
    )
  end

  def handle_event([:flowstone, :http, :request, :error], measurements, metadata, _config) do
    duration_ms = System.convert_time_unit(measurements.duration, :native, :millisecond)

    Logger.error("HTTP #{metadata.method} #{metadata.path} failed",
      error: inspect(measurements.error),
      duration_ms: duration_ms
    )
  end
end
```

### StatsD/Datadog Integration

```elixir
defmodule MyApp.Telemetry.StatsD do
  def attach_handlers do
    :telemetry.attach_many(
      "myapp-statsd-handlers",
      [
        [:flowstone, :http, :request, :stop],
        [:flowstone, :http, :request, :error]
      ],
      &handle_event/4,
      nil
    )
  end

  def handle_event([:flowstone, :http, :request, :stop], measurements, metadata, _config) do
    duration_ms = System.convert_time_unit(measurements.duration, :native, :millisecond)
    tags = ["method:#{metadata.method}", "status:#{measurements.status}"]

    Statix.histogram("flowstone.http.duration", duration_ms, tags: tags)
    Statix.increment("flowstone.http.requests", 1, tags: tags)
  end

  def handle_event([:flowstone, :http, :request, :error], _measurements, metadata, _config) do
    tags = ["method:#{metadata.method}"]
    Statix.increment("flowstone.http.errors", 1, tags: tags)
  end
end
```

### Prometheus Integration

```elixir
defmodule MyApp.Telemetry.Prometheus do
  use Prometheus.Metric

  def setup do
    Histogram.declare(
      name: :flowstone_http_duration_milliseconds,
      help: "HTTP request duration in milliseconds",
      labels: [:method, :status_class],
      buckets: [10, 50, 100, 250, 500, 1000, 2500, 5000, 10000]
    )

    Counter.declare(
      name: :flowstone_http_requests_total,
      help: "Total HTTP requests",
      labels: [:method, :status]
    )
  end

  def attach_handlers do
    :telemetry.attach_many(
      "myapp-prometheus-handlers",
      [
        [:flowstone, :http, :request, :stop]
      ],
      &handle_event/4,
      nil
    )
  end

  def handle_event([:flowstone, :http, :request, :stop], measurements, metadata, _config) do
    duration_ms = System.convert_time_unit(measurements.duration, :native, :millisecond)
    status_class = div(measurements.status, 100) * 100

    Histogram.observe(
      [name: :flowstone_http_duration_milliseconds,
       labels: [metadata.method, status_class]],
      duration_ms
    )

    Counter.inc(
      name: :flowstone_http_requests_total,
      labels: [metadata.method, measurements.status]
    )
  end
end
```

### OpenTelemetry Integration

```elixir
defmodule MyApp.Telemetry.OpenTelemetry do
  require OpenTelemetry.Tracer, as: Tracer

  def attach_handlers do
    :telemetry.attach_many(
      "myapp-otel-handlers",
      [
        [:flowstone, :http, :request, :start],
        [:flowstone, :http, :request, :stop],
        [:flowstone, :http, :request, :error]
      ],
      &handle_event/4,
      nil
    )
  end

  def handle_event([:flowstone, :http, :request, :start], _measurements, metadata, _config) do
    span_name = "HTTP #{metadata.method} #{metadata.path}"

    Tracer.start_span(span_name, %{
      attributes: [
        {"http.method", Atom.to_string(metadata.method)},
        {"http.url", metadata.url}
      ]
    })
  end

  def handle_event([:flowstone, :http, :request, :stop], measurements, _metadata, _config) do
    Tracer.set_attributes([
      {"http.status_code", measurements.status}
    ])

    Tracer.end_span()
  end

  def handle_event([:flowstone, :http, :request, :error], measurements, _metadata, _config) do
    Tracer.set_status(:error, inspect(measurements.error))
    Tracer.end_span()
  end
end
```

## Custom Event Emission

### Emitting from Asset Execute Functions

```elixir
asset :my_asset do
  execute fn ctx, deps ->
    # Emit custom telemetry
    :telemetry.execute(
      [:my_app, :my_asset, :start],
      %{system_time: System.system_time()},
      %{partition: ctx.partition}
    )

    result = do_work(deps)

    :telemetry.execute(
      [:my_app, :my_asset, :stop],
      %{items_processed: length(result)},
      %{partition: ctx.partition}
    )

    {:ok, result}
  end
end
```

## Event Reference Table

| Event | Description |
|-------|-------------|
| `[:flowstone, :http, :request, :start]` | HTTP request started |
| `[:flowstone, :http, :request, :stop]` | HTTP request completed |
| `[:flowstone, :http, :request, :error]` | HTTP request failed |
| `[:flowstone, :http, :retry]` | Request being retried |
