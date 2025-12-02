defmodule FlowStone.MixProject do
  use Mix.Project

  @version "0.1.0"
  @source_url "https://github.com/nshkrdotcom/flowstone"

  def project do
    [
      app: :flowstone,
      version: @version,
      elixir: "~> 1.15",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      aliases: aliases(),
      elixirc_paths: elixirc_paths(Mix.env()),

      # Hex.pm
      name: "FlowStone",
      description: description(),
      package: package(),
      docs: docs(),

      # Testing
      test_coverage: [tool: ExCoveralls],
      preferred_cli_env: [
        coveralls: :test,
        "coveralls.detail": :test,
        "coveralls.post": :test,
        "coveralls.html": :test
      ],

      # Dialyzer
      dialyzer: [
        plt_file: {:no_warn, "priv/plts/dialyzer.plt"},
        plt_add_apps: [:mix, :ex_unit]
      ]
    ]
  end

  def application do
    [
      extra_applications: [:logger],
      mod: {FlowStone.Application, []}
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      # Core dependencies
      {:ecto_sql, "~> 3.11"},
      {:postgrex, "~> 0.17"},
      {:oban, "~> 2.18"},
      {:jason, "~> 1.4"},

      # Phoenix / LiveView (optional for UI)
      {:phoenix, "~> 1.7", optional: true},
      {:phoenix_live_view, "~> 1.0", optional: true},
      {:phoenix_pubsub, "~> 2.1"},

      # HTTP client for integrations
      {:req, "~> 0.5"},

      # Rate limiting
      {:hammer, "~> 6.2"},

      # Telemetry
      {:telemetry, "~> 1.2"},
      {:telemetry_metrics, "~> 1.0"},
      {:telemetry_poller, "~> 1.1"},

      # Data formats
      {:explorer, "~> 0.9", optional: true},

      # AWS/S3 support
      {:ex_aws, "~> 2.5", optional: true},
      {:ex_aws_s3, "~> 2.5", optional: true},

      # Testing
      {:supertester, "~> 0.3", only: :test},
      {:mox, "~> 1.1", only: :test},
      {:stream_data, "~> 1.1", only: [:dev, :test]},
      {:excoveralls, "~> 0.18", only: :test},

      # Development
      {:ex_doc, "~> 0.31", only: :dev, runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false}
    ]
  end

  defp aliases do
    [
      setup: ["deps.get"],
      test: ["ecto.create --quiet", "ecto.migrate --quiet", "test"],
      quality: ["format --check-formatted", "credo --strict", "dialyzer"]
    ]
  end

  defp description do
    """
    Asset-first data orchestration framework for Elixir/BEAM.

    FlowStone treats data artifacts (assets) as first-class citizens, automatically
    constructing execution DAGs from dependencies. Inspired by Dagster, but built
    to leverage BEAM's fault tolerance, OTP supervision, and Phoenix LiveView for
    real-time observability.

    Features:
    - Declarative asset definitions with compile-time validation
    - Automatic DAG construction and dependency resolution
    - PostgreSQL-backed materialization tracking with full lineage
    - Partition-aware execution (time-based, tenant, custom)
    - Human-in-the-loop checkpoint gates
    - Oban-powered distributed job execution
    - Cron scheduling and event-driven sensors
    - Pluggable I/O managers (Postgres, S3, Parquet)
    - Phoenix LiveView real-time dashboard
    - Comprehensive telemetry and audit logging
    """
  end

  defp package do
    [
      name: "flowstone",
      files: ~w(lib priv .formatter.exs mix.exs README.md LICENSE CHANGELOG.md),
      licenses: ["MIT"],
      links: %{
        "GitHub" => @source_url,
        "Changelog" => "#{@source_url}/blob/main/CHANGELOG.md",
        "Documentation" => "https://hexdocs.pm/flowstone"
      },
      maintainers: ["nshkrdotcom"]
    ]
  end

  defp docs do
    [
      main: "readme",
      name: "FlowStone",
      source_ref: "v#{@version}",
      source_url: @source_url,
      extras: [
        "README.md",
        "CHANGELOG.md",
        "LICENSE",
        "docs/design/OVERVIEW.md",
        "docs/adr/README.md",
        "docs/adr/0001-asset-first-orchestration.md",
        "docs/adr/0002-dag-engine-persistence.md",
        "docs/adr/0003-partitioning-isolation.md",
        "docs/adr/0004-io-manager-abstraction.md",
        "docs/adr/0005-checkpoint-approval-gates.md",
        "docs/adr/0006-oban-job-execution.md",
        "docs/adr/0007-scheduling-sensors.md",
        "docs/adr/0008-resource-injection.md",
        "docs/adr/0009-error-handling.md",
        "docs/adr/0010-elixir-dsl-not-yaml.md",
        "docs/adr/0011-observability-telemetry.md",
        "docs/adr/0012-liveview-ui.md",
        "docs/adr/0013-testing-strategies.md",
        "docs/adr/0014-lineage-reporting.md",
        "docs/adr/0015-external-integrations.md"
      ],
      groups_for_extras: [
        "Architecture Decision Records": Path.wildcard("docs/adr/*.md"),
        Design: ["docs/design/OVERVIEW.md"]
      ],
      groups_for_modules: [
        Core: [
          FlowStone,
          FlowStone.Asset,
          FlowStone.Pipeline,
          FlowStone.Context,
          FlowStone.Materialization
        ],
        DAG: [
          FlowStone.DAG,
          FlowStone.DAG.Builder
        ],
        Execution: [
          FlowStone.Materializer,
          FlowStone.Workers.AssetWorker,
          FlowStone.Workers.ScheduledAsset,
          FlowStone.Workers.CheckpointTimeout
        ],
        "I/O Managers": [
          FlowStone.IO,
          FlowStone.IO.Manager,
          FlowStone.IO.Memory,
          FlowStone.IO.Postgres,
          FlowStone.IO.S3,
          FlowStone.IO.Parquet
        ],
        Scheduling: [
          FlowStone.Schedule,
          FlowStone.Sensor,
          FlowStone.Sensors.S3FileArrival,
          FlowStone.Sensors.DatabaseChange
        ],
        Checkpoints: [
          FlowStone.Checkpoint,
          FlowStone.Checkpoint.Notifier
        ],
        Resources: [
          FlowStone.Resource,
          FlowStone.Resources
        ],
        Lineage: [
          FlowStone.Lineage,
          FlowStone.Lineage.Recorder,
          FlowStone.Lineage.Invalidation
        ],
        Observability: [
          FlowStone.Telemetry,
          FlowStone.Logger,
          FlowStone.AuditLog
        ],
        Errors: [
          FlowStone.Error,
          FlowStone.Error.Formatter
        ],
        Testing: [
          FlowStone.AssetCase,
          FlowStone.Test.Fixtures
        ]
      ]
    ]
  end
end
