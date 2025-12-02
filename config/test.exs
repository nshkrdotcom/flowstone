import Config

config :flowstone, FlowStone.Repo,
  username: "postgres",
  password: "postgres",
  hostname: "localhost",
  database: "flowstone_test",
  pool: Ecto.Adapters.SQL.Sandbox,
  pool_size: 10,
  ownership_timeout: 60_000

config :flowstone,
  start_repo: true,
  start_pubsub: true,
  start_resources: true,
  start_materialization_store: true,
  start_oban: true

config :flowstone, Oban,
  repo: FlowStone.Repo,
  testing: :inline,
  queues: [assets: 10, checkpoints: 2],
  plugins: []

config :hammer,
  backend: {Hammer.Backend.ETS, [expiry_ms: 60_000, cleanup_interval_ms: 60_000]}

config :logger, level: :warning
