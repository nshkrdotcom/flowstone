import Config

config :flowstone,
  ecto_repos: [FlowStone.Repo],
  io_managers: %{
    memory: FlowStone.IO.Memory,
    postgres: FlowStone.IO.Postgres,
    s3: FlowStone.IO.S3,
    parquet: FlowStone.IO.Parquet
  },
  default_io_manager: :memory,
  start_repo: false,
  start_pubsub: false,
  start_resources: false,
  start_materialization_store: false,
  start_oban: false

config :flowstone, Oban,
  repo: FlowStone.Repo,
  queues: [assets: 10],
  plugins: []

config :hammer,
  backend: {Hammer.Backend.ETS, [expiry_ms: 60_000, cleanup_interval_ms: 60_000]}

config :logger, level: :info

import_config "#{config_env()}.exs"
