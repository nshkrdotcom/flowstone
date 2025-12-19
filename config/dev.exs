import Config

config :flowstone, FlowStone.Repo,
  username: "postgres",
  password: "postgres",
  hostname: "localhost",
  database: "flowstone_dev",
  pool_size: 10

config :flowstone,
  start_repo: true,
  start_pubsub: true,
  start_resources: true,
  start_materialization_store: true,
  start_oban: true

config :flowstone, Oban,
  repo: FlowStone.Repo,
  queues: [assets: 10, checkpoints: 5, parallel_join: 5, flowstone_scatter: 10],
  plugins: []

config :logger, level: :debug
