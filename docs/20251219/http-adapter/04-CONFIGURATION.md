# Configuration Reference

## Overview

This document describes configuration options for the HTTP adapter.

## HTTP Adapter Configuration

### Resource Registration

```elixir
FlowStone.Resources.register(name, FlowStone.HTTP.Client, options)
```

### Options

| Option | Type | Default | Description |
|--------|------|---------|-------------|
| `base_url` | `String.t()` | **required** | Base URL for all requests |
| `timeout` | `pos_integer()` | `30_000` | Request timeout in milliseconds |
| `headers` | `map()` | `%{}` | Default headers for all requests |
| `retry` | `map()` | See below | Retry configuration |
| `req_options` | `keyword()` | `[]` | Pass-through options to Req |

### Retry Options

| Option | Type | Default | Description |
|--------|------|---------|-------------|
| `max_attempts` | `pos_integer()` | `3` | Maximum retry attempts |
| `base_delay_ms` | `pos_integer()` | `1000` | Base delay for exponential backoff |
| `max_delay_ms` | `pos_integer()` | `30_000` | Maximum delay between retries |
| `jitter` | `boolean()` | `true` | Add random jitter to delays |

### Example Configuration

```elixir
# config/config.exs

config :my_app, :api_client,
  base_url: "https://api.example.com",
  timeout: 60_000,
  headers: %{
    "X-API-Version" => "2024-01"
  },
  retry: %{
    max_attempts: 5,
    base_delay_ms: 500,
    max_delay_ms: 60_000,
    jitter: true
  }
```

```elixir
# In application startup
def start(_type, _args) do
  api_config = Application.get_env(:my_app, :api_client)

  children = [
    # ...
    {FlowStone.Resources, [
      {:api, FlowStone.HTTP.Client, api_config}
    ]}
  ]

  Supervisor.start_link(children, strategy: :one_for_one)
end
```

### Environment-Specific Configuration

```elixir
# config/dev.exs
config :my_app, :api_client,
  base_url: "http://localhost:3000",
  timeout: 5_000

# config/prod.exs
config :my_app, :api_client,
  base_url: System.get_env("API_BASE_URL"),
  timeout: 60_000,
  headers: %{
    "Authorization" => "Bearer #{System.get_env("API_TOKEN")}"
  }
```

### Runtime Configuration

```elixir
# config/runtime.exs
import Config

if config_env() == :prod do
  config :my_app, :api_client,
    base_url: System.fetch_env!("API_BASE_URL"),
    headers: %{
      "Authorization" => "Bearer #{System.fetch_env!("API_TOKEN")}"
    }
end
```

## Pipeline Configuration

### Resource Requirements

```elixir
asset :call_api do
  # Declare required resources
  requires [:api_client, :cache]

  execute fn ctx, _deps ->
    client = ctx.resources[:api_client]
    cache = ctx.resources[:cache]
    # ...
  end
end
```

### Configuring Execution

```elixir
FlowStone.materialize(MyPipeline,
  partition: %{id: 123},

  # Resource configuration
  resources: %{
    api_client: Application.get_env(:my_app, :api_client),
    cache: Application.get_env(:my_app, :cache)
  },

  # I/O manager
  io_manager: FlowStone.IO.Postgres
)
```

## Complete Example

```elixir
# config/config.exs
import Config

# HTTP Client for external API
config :my_app, :external_api,
  base_url: "https://api.example.com",
  timeout: 30_000,
  headers: %{
    "Accept" => "application/json",
    "X-Client-ID" => "flowstone-client"
  },
  retry: %{
    max_attempts: 3,
    base_delay_ms: 1000,
    max_delay_ms: 30_000,
    jitter: true
  }

# HTTP Client for internal services
config :my_app, :internal_api,
  base_url: "http://internal-service:8080",
  timeout: 10_000,
  retry: %{
    max_attempts: 2,
    base_delay_ms: 500,
    max_delay_ms: 5_000,
    jitter: false
  }

# Import environment-specific config
import_config "#{config_env()}.exs"
```

```elixir
# config/prod.exs
import Config

config :my_app, :external_api,
  headers: %{
    "Accept" => "application/json",
    "X-Client-ID" => "flowstone-client",
    "Authorization" => "Bearer #{System.get_env("EXTERNAL_API_TOKEN")}"
  }
```

```elixir
# lib/my_app/application.ex
defmodule MyApp.Application do
  use Application

  def start(_type, _args) do
    children = [
      # Database
      MyApp.Repo,

      # Register FlowStone resources
      {FlowStone.Resources, resources_config()},

      # Oban for durable execution
      {Oban, oban_config()},

      # Telemetry handlers
      {Task, fn -> attach_telemetry() end}
    ]

    opts = [strategy: :one_for_one, name: MyApp.Supervisor]
    Supervisor.start_link(children, opts)
  end

  defp resources_config do
    [
      {:external_api, FlowStone.HTTP.Client,
        Application.get_env(:my_app, :external_api)},
      {:internal_api, FlowStone.HTTP.Client,
        Application.get_env(:my_app, :internal_api)}
    ]
  end

  defp oban_config do
    Application.get_env(:my_app, Oban)
  end

  defp attach_telemetry do
    MyApp.Telemetry.attach_handlers()
  end
end
```

## Validation

FlowStone validates configuration at startup:

```elixir
# Missing required option
FlowStone.Resources.register(:api, FlowStone.HTTP.Client, %{})
# ** (ArgumentError) FlowStone.HTTP.Client requires :base_url in config

# Invalid type
FlowStone.Resources.register(:api, FlowStone.HTTP.Client,
  base_url: "https://api.example.com",
  timeout: "30000"  # Should be integer
)
# ** (ArgumentError) :timeout must be a positive integer

# Invalid retry config
FlowStone.Resources.register(:api, FlowStone.HTTP.Client,
  base_url: "https://api.example.com",
  retry: %{max_attempts: 0}
)
# ** (ArgumentError) :max_attempts must be at least 1
```

## Debugging Configuration

### Inspect Registered Resources

```elixir
# List all registered resources
FlowStone.Resources.list()
# => [:external_api, :internal_api]

# Get resource config
FlowStone.Resources.get_config(:external_api)
# => %{base_url: "https://api.example.com", ...}

# Check resource health
FlowStone.Resources.health_check(:external_api)
# => :healthy | {:unhealthy, reason}
```

### Debug Logging

```elixir
# config/dev.exs
config :logger, level: :debug

# Enable HTTP request logging
config :my_app, :external_api,
  req_options: [
    plug: {Req.Steps, [:put_default_steps, log: true]}
  ]
```
