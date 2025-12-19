# FlowStone Configuration Guide

FlowStone works with zero configuration using in-memory storage. This guide explains how to configure persistence, storage backends, and other options.

## Zero Configuration (Default)

By default, FlowStone uses in-memory storage:

```elixir
# No configuration needed
{:ok, result} = FlowStone.run(MyPipeline, :asset)
```

This is ideal for:
- Development and prototyping
- Tests
- Stateless computations

## Adding Persistence

To persist asset results across restarts, configure your Ecto repo:

```elixir
# config/config.exs
config :flowstone, repo: MyApp.Repo
```

This automatically:
- Switches storage to PostgreSQL
- Enables lineage tracking
- Configures Oban for async execution

### Database Setup

Run the FlowStone migrations:

```bash
mix ecto.gen.migration add_flowstone_tables
```

In the generated migration:

```elixir
defmodule MyApp.Repo.Migrations.AddFlowstoneTables do
  use Ecto.Migration

  def up do
    FlowStone.Migrations.up()
  end

  def down do
    FlowStone.Migrations.down()
  end
end
```

Run the migration:

```bash
mix ecto.migrate
```

## Configuration Options

### Full Configuration

```elixir
# config/config.exs
config :flowstone,
  # Ecto repo for persistence (required for non-memory storage)
  repo: MyApp.Repo,

  # Storage backend: :memory (default), :postgres, :s3, :parquet
  storage: :postgres,

  # Enable lineage tracking (auto-enabled when repo is set)
  lineage: true,

  # Default execution mode (sync vs async)
  async_default: false,

  # Start Oban (auto-enabled when repo is set)
  start_oban: true

# Oban configuration (optional, merged with defaults)
config :flowstone, Oban,
  queues: [
    assets: 20,           # Main asset execution
    checkpoints: 5,       # Approval checkpoints
    parallel_join: 5,     # Parallel branch coordination
    flowstone_scatter: 10 # Scatter fan-out
  ],
  plugins: [
    Oban.Plugins.Pruner,
    {Oban.Plugins.Lifeline, rescue_after: :timer.minutes(30)}
  ]
```

### Storage Backends

#### In-Memory (Default)

```elixir
config :flowstone, storage: :memory
```

- Fast, no persistence
- Data lost on restart
- Good for dev/test

#### PostgreSQL

```elixir
config :flowstone,
  repo: MyApp.Repo,
  storage: :postgres
```

- Durable storage
- Supports lineage queries
- Good for most production use cases

#### S3

```elixir
config :flowstone,
  repo: MyApp.Repo,  # Still needed for metadata
  storage: :s3,
  s3_bucket: "my-flowstone-bucket",
  s3_prefix: "assets/"

# AWS credentials (via ex_aws)
config :ex_aws,
  access_key_id: "...",
  secret_access_key: "...",
  region: "us-east-1"
```

- Large file storage
- Data lake integration
- Good for big data workloads

#### Parquet

```elixir
config :flowstone,
  repo: MyApp.Repo,
  storage: :parquet,
  parquet_path: "/data/flowstone/"
```

- Columnar storage
- Efficient for analytics
- Requires Explorer library

## Environment-Specific Configuration

### Development

```elixir
# config/dev.exs
config :flowstone,
  storage: :memory,
  async_default: false  # Synchronous for easier debugging
```

### Test

```elixir
# config/test.exs
config :flowstone,
  storage: :memory,
  start_oban: false  # Disable Oban in tests
```

### Production

```elixir
# config/prod.exs
config :flowstone,
  repo: MyApp.Repo,
  storage: :postgres,
  lineage: true,
  async_default: true  # Use Oban for background execution
```

## Runtime Configuration

For dynamic configuration, use `config/runtime.exs`:

```elixir
# config/runtime.exs
import Config

config :flowstone,
  repo: MyApp.Repo,
  storage: String.to_atom(System.get_env("FLOWSTONE_STORAGE", "postgres"))
```

## Configuration API

Access configuration programmatically:

```elixir
# Get full configuration
FlowStone.Config.get()
# => %{repo: MyApp.Repo, storage: :postgres, lineage: true, ...}

# Individual settings
FlowStone.Config.repo()           # => MyApp.Repo
FlowStone.Config.storage_backend()  # => :postgres
FlowStone.Config.lineage_enabled?() # => true
FlowStone.Config.async_default?()   # => false

# Validate configuration
FlowStone.Config.validate!()  # Raises on invalid config
```

## I/O Manager Configuration

For advanced use cases, configure specific I/O managers:

```elixir
config :flowstone, :io_managers, %{
  memory: FlowStone.IO.Memory,
  postgres: FlowStone.IO.Postgres,
  s3: FlowStone.IO.S3,
  parquet: FlowStone.IO.Parquet,
  custom: MyApp.CustomIO  # Add your own
}

config :flowstone, :default_io_manager, :postgres
```

## Application Supervision

If you need to customize the supervision tree:

```elixir
# config/config.exs
config :flowstone,
  start_oban: false,   # Manage Oban yourself
  start_repo: false    # Manage repo yourself (usually false)
```

Then in your application:

```elixir
defmodule MyApp.Application do
  use Application

  def start(_type, _args) do
    children = [
      MyApp.Repo,
      {Oban, FlowStone.Config.oban_config()},
      # ... other children
    ]

    Supervisor.start_link(children, strategy: :one_for_one)
  end
end
```

## Troubleshooting

### "Postgres storage requires :repo configuration"

You set `storage: :postgres` but didn't configure a repo:

```elixir
config :flowstone,
  repo: MyApp.Repo,
  storage: :postgres
```

### "S3 storage requires :s3_bucket configuration"

You set `storage: :s3` but didn't configure the bucket:

```elixir
config :flowstone,
  storage: :s3,
  s3_bucket: "my-bucket"
```

### Oban jobs not running

Check that Oban is started:

```elixir
# In config
config :flowstone, start_oban: true

# Or manually in your supervision tree
{Oban, FlowStone.Config.oban_config()}
```

## Next Steps

- [Getting Started Guide](getting-started.md) - Basic usage patterns
- [Testing Guide](testing.md) - Testing with different configurations
