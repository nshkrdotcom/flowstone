import Config

config :flowstone, FlowStone.Repo,
  username: "postgres",
  password: "postgres",
  hostname: "localhost",
  database: "flowstone_test",
  pool: Ecto.Adapters.SQL.Sandbox,
  pool_size: 5,
  ownership_timeout: 60_000

config :flowstone,
  io_managers: %{
    memory: FlowStone.IO.Memory,
    postgres: FlowStone.IO.Postgres,
    s3: FlowStone.IO.S3,
    parquet: FlowStone.IO.Parquet
  },
  default_io_manager: :memory

config :flowstone, Oban,
  repo: FlowStone.Repo,
  testing: :inline,
  queues: false,
  plugins: false

config :hammer,
  backend: {Hammer.Backend.ETS, [expiry_ms: 60_000, cleanup_interval_ms: 60_000]}

config :logger, level: :warn
