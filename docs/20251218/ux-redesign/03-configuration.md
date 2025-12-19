# Simplified Configuration

**Status:** Design Proposal
**Date:** 2025-12-18

## Design Principles

1. **Zero config works** - FlowStone runs with no configuration
2. **One key unlocks persistence** - Adding `repo:` enables database features
3. **Sensible defaults** - Production-ready without tuning
4. **Progressive disclosure** - Advanced options available but hidden
5. **Environment-aware** - Different defaults for dev/test/prod

---

## Configuration Levels

### Level 0: No Configuration

```elixir
# mix.exs
defp deps do
  [{:flowstone, "~> 1.0"}]
end

# No config needed!
```

**What you get:**
- In-memory storage
- Synchronous execution
- No persistence
- No job queue
- Perfect for scripts, experiments, tests

**What you don't get:**
- Async execution
- Persistent storage
- Lineage tracking
- Approval workflows
- Scheduled runs

---

### Level 1: Persistence Enabled

```elixir
# config/config.exs
config :flowstone, repo: MyApp.Repo
```

**What this single line enables:**
- Postgres storage (default)
- Oban job queue (async available)
- Lineage tracking
- Materialization history
- Approval workflows
- Checkpoint persistence

**Additional deps required:**
```elixir
{:flowstone, "~> 1.0"},
{:ecto_sql, "~> 3.10"},
{:postgrex, ">= 0.0.0"}
```

**Automatic Oban setup:**
FlowStone auto-configures Oban with sensible defaults:
```elixir
# You get this for free:
config :flowstone, Oban,
  queues: [flowstone: 10],
  plugins: [Oban.Plugins.Pruner]
```

---

### Level 2: Storage Customization

```elixir
# config/config.exs
config :flowstone,
  repo: MyApp.Repo,
  storage: :s3  # Default storage backend
```

**Storage options:**
| Value | Backend | Use Case |
|-------|---------|----------|
| `:memory` | In-memory Agent | Testing, ephemeral |
| `:postgres` | PostgreSQL JSONB | Structured data < 50MB |
| `:s3` | S3/MinIO | Large files, data lake |
| `:parquet` | Apache Parquet | Analytics, columnar |

**Per-asset storage overrides:**
```elixir
config :flowstone,
  repo: MyApp.Repo,
  storage: :postgres,
  storage_overrides: %{
    large_reports: :s3,
    analytics_cube: :parquet
  }
```

**S3 configuration (when using :s3):**
```elixir
config :flowstone,
  repo: MyApp.Repo,
  storage: :s3,
  s3: [
    bucket: "my-flowstone-bucket",
    prefix: "assets/",
    region: "us-east-1"
  ]
```

---

### Level 3: Advanced Configuration

```elixir
# config/config.exs
config :flowstone,
  # Required for persistence
  repo: MyApp.Repo,

  # Storage
  storage: :postgres,
  storage_overrides: %{large_files: :s3},

  # S3 settings (if using S3)
  s3: [
    bucket: "my-bucket",
    prefix: "flowstone/"
  ],

  # Async execution
  async_default: false,  # Default for async: option

  # Timeouts
  default_timeout: 300_000,  # 5 minutes

  # Scatter defaults
  scatter: [
    max_concurrent: 50,
    failure_threshold: 0.1,
    batch_size: 100
  ],

  # Lineage
  lineage: true,  # Enable lineage tracking

  # PubSub for real-time updates
  pubsub: MyApp.PubSub  # Optional
```

**Oban customization:**
```elixir
config :flowstone, Oban,
  queues: [
    flowstone: 10,
    flowstone_scatter: 50,
    flowstone_priority: 5
  ],
  plugins: [
    Oban.Plugins.Pruner,
    {Oban.Plugins.Cron, crontab: []}
  ]
```

---

## Environment-Specific Defaults

### Development

```elixir
# config/dev.exs
config :flowstone,
  repo: MyApp.Repo,
  storage: :postgres,
  log_level: :debug
```

### Test

```elixir
# config/test.exs
config :flowstone,
  storage: :memory,  # No repo needed
  async: :disabled   # Always sync in tests
```

The `async: :disabled` option prevents accidental async execution in tests:
```elixir
# In test, this runs synchronously even with async: true
FlowStone.run(MyPipeline, :asset, async: true)
# => {:ok, result}  # Not {:ok, %Oban.Job{}}
```

### Production

```elixir
# config/prod.exs
config :flowstone,
  repo: MyApp.Repo,
  storage: :s3,
  s3: [
    bucket: System.get_env("FLOWSTONE_S3_BUCKET"),
    region: System.get_env("AWS_REGION")
  ],
  scatter: [
    max_concurrent: 100,
    failure_threshold: 0.05
  ]
```

---

## Configuration Reference

### Core Options

| Option | Type | Default | Description |
|--------|------|---------|-------------|
| `repo` | `module()` | `nil` | Ecto repo for persistence |
| `storage` | `atom()` | `:memory` / `:postgres`* | Default storage backend |
| `storage_overrides` | `map()` | `%{}` | Per-asset storage overrides |
| `async_default` | `boolean()` | `false` | Default for `async:` option |
| `default_timeout` | `pos_integer()` | `300_000` | Default execution timeout (ms) |
| `lineage` | `boolean()` | `true`* | Enable lineage tracking |
| `pubsub` | `module()` | `nil` | PubSub for real-time updates |
| `log_level` | `atom()` | `:info` | FlowStone log level |

*When `repo` is configured, `storage` defaults to `:postgres` and `lineage` defaults to `true`.

### Storage Options

**Postgres (`storage: :postgres`):**
| Option | Type | Default | Description |
|--------|------|---------|-------------|
| `table_prefix` | `string()` | `"flowstone_"` | Table name prefix |
| `compression` | `boolean()` | `true` | Compress large values |

**S3 (`storage: :s3`):**
| Option | Type | Default | Description |
|--------|------|---------|-------------|
| `bucket` | `string()` | required | S3 bucket name |
| `prefix` | `string()` | `""` | Key prefix |
| `region` | `string()` | from AWS config | AWS region |

**Parquet (`storage: :parquet`):**
| Option | Type | Default | Description |
|--------|------|---------|-------------|
| `path` | `string()` | `"./data"` | Local directory |
| `compression` | `atom()` | `:snappy` | Compression codec |

### Scatter Options

| Option | Type | Default | Description |
|--------|------|---------|-------------|
| `max_concurrent` | `pos_integer()` | `50` | Max parallel scatter instances |
| `failure_threshold` | `float()` | `0.1` | Fail if > 10% fail |
| `batch_size` | `pos_integer()` | `100` | Items per batch |
| `rate_limit` | `tuple()` | `nil` | Rate limit `{count, :second}` |

### Oban Options

| Option | Type | Default | Description |
|--------|------|---------|-------------|
| `queues` | `keyword()` | `[flowstone: 10]` | Queue configuration |
| `plugins` | `list()` | `[Pruner]` | Oban plugins |

---

## Automatic Feature Detection

FlowStone detects available features based on configuration:

```elixir
# No repo configured
FlowStone.capabilities()
# => %{
#   storage: [:memory],
#   async: false,
#   lineage: false,
#   approvals: false,
#   scheduling: false
# }

# With repo configured
FlowStone.capabilities()
# => %{
#   storage: [:memory, :postgres],
#   async: true,
#   lineage: true,
#   approvals: true,
#   scheduling: true
# }

# With S3 configured
FlowStone.capabilities()
# => %{
#   storage: [:memory, :postgres, :s3],
#   ...
# }
```

---

## Runtime Configuration

Some options can be set at runtime:

```elixir
# In application.ex
def start(_type, _args) do
  # Override config at runtime
  Application.put_env(:flowstone, :storage, :s3)

  children = [
    MyApp.Repo,
    FlowStone
  ]

  Supervisor.start_link(children, strategy: :one_for_one)
end
```

---

## Supervision Tree Integration

### Minimal (Auto-start)

FlowStone auto-starts when first used if not explicitly supervised:

```elixir
# Just use it - FlowStone starts automatically
FlowStone.run(MyPipeline, :asset)
```

### Explicit (Recommended for Production)

```elixir
# application.ex
def start(_type, _args) do
  children = [
    MyApp.Repo,
    FlowStone  # Starts all FlowStone services
  ]

  Supervisor.start_link(children, strategy: :one_for_one)
end
```

### Custom Supervision

```elixir
# For advanced control
def start(_type, _args) do
  children = [
    MyApp.Repo,
    {FlowStone, [
      skip_oban: true,  # Manage Oban separately
      name: :flowstone_main
    ]}
  ]

  Supervisor.start_link(children, strategy: :one_for_one)
end
```

---

## Migration from Current Config

### Before (Current)

```elixir
config :flowstone,
  ecto_repos: [FlowStone.Repo],
  io_managers: %{
    memory: FlowStone.IO.Memory,
    postgres: FlowStone.IO.Postgres,
    s3: FlowStone.IO.S3,
    parquet: FlowStone.IO.Parquet
  },
  default_io_manager: :memory,
  start_repo: true,
  start_pubsub: true,
  start_resources: true,
  start_materialization_store: true,
  start_oban: true

config :flowstone, Oban,
  repo: FlowStone.Repo,
  queues: [assets: 10, checkpoints: 5, parallel_join: 5, flowstone_scatter: 10],
  plugins: [Oban.Plugins.Pruner]

config :flowstone, FlowStone.Repo,
  username: "postgres",
  password: "postgres",
  hostname: "localhost",
  database: "flowstone_dev"
```

### After (Proposed)

```elixir
config :flowstone, repo: MyApp.Repo
```

That's it. Everything else is inferred or uses sensible defaults.

---

## Configuration Validation

FlowStone validates configuration at startup:

```elixir
# Invalid storage type
config :flowstone, storage: :invalid
# => ** (FlowStone.ConfigError)
#    Invalid storage: :invalid
#    Valid options: :memory, :postgres, :s3, :parquet

# Missing S3 bucket
config :flowstone, storage: :s3
# => ** (FlowStone.ConfigError)
#    S3 storage requires bucket configuration:
#
#      config :flowstone,
#        storage: :s3,
#        s3: [bucket: "my-bucket"]

# Repo not started
config :flowstone, repo: MyApp.Repo
# (repo not in supervision tree)
# => ** (FlowStone.ConfigError)
#    Repository MyApp.Repo is not started.
#    Add it to your supervision tree before FlowStone:
#
#      children = [
#        MyApp.Repo,
#        FlowStone
#      ]
```

---

## Configuration Introspection

```elixir
# View effective configuration
FlowStone.config()
# => %{
#   repo: MyApp.Repo,
#   storage: :postgres,
#   storage_overrides: %{},
#   async_default: false,
#   default_timeout: 300_000,
#   lineage: true,
#   ...
# }

# View storage configuration
FlowStone.storage_config()
# => %{
#   default: :postgres,
#   overrides: %{large_files: :s3},
#   backends: %{
#     memory: %{type: :memory},
#     postgres: %{type: :postgres, repo: MyApp.Repo},
#     s3: %{type: :s3, bucket: "my-bucket", region: "us-east-1"}
#   }
# }
```
