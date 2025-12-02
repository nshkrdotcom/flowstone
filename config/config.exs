import Config

config :flowstone,
  ecto_repos: [FlowStone.Repo],
  io_managers: %{
    memory: FlowStone.IO.Memory,
    postgres: FlowStone.IO.Postgres,
    s3: FlowStone.IO.S3,
    parquet: FlowStone.IO.Parquet
  },
  default_io_manager: :memory

config :flowstone, FlowStone.Repo,
  username: "postgres",
  password: "postgres",
  hostname: "localhost",
  database: "flowstone_dev",
  pool_size: 10

config :flowstone, Oban,
  repo: FlowStone.Repo,
  queues: [assets: 10],
  plugins: []

config :hammer,
  backend: {Hammer.Backend.ETS, [expiry_ms: 60_000, cleanup_interval_ms: 60_000]}

config :logger, level: :info
