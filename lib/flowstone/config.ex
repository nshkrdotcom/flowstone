defmodule FlowStone.Config do
  @moduledoc """
  Configuration management for FlowStone.

  This module provides a unified interface for accessing FlowStone configuration
  with sensible defaults and automatic inference based on what's configured.

  ## Zero Config

  FlowStone works with zero configuration using in-memory storage:

      # No config needed - defaults to memory storage
      {:ok, result} = FlowStone.run(MyPipeline, :asset)

  ## Adding Persistence

  To enable persistence, configure your Ecto repo:

      # config/config.exs
      config :flowstone, repo: MyApp.Repo

  This automatically:
  - Switches storage to Postgres
  - Enables lineage tracking
  - Configures Oban for async execution

  ## Configuration Options

  | Option | Default | Description |
  |--------|---------|-------------|
  | `:repo` | `nil` | Ecto repo for persistence |
  | `:storage` | Auto | Storage backend (`:memory`, `:postgres`, `:s3`) |
  | `:lineage` | Auto | Enable lineage tracking (true if repo configured) |
  | `:async_default` | `false` | Default async execution mode |

  ## Legacy Config

  Old configuration options are still supported but deprecated:

  - `io_managers` → use `storage`
  - `default_io_manager` → use `storage`
  - `start_repo`, `start_oban`, etc. → auto-detected

  """

  @type t :: %{
          repo: module() | nil,
          storage: :memory | :postgres | :s3 | :parquet,
          lineage: boolean(),
          async_default: boolean(),
          oban: keyword() | nil
        }

  @doc """
  Get the full configuration struct.

  Returns a map with all configuration values, applying defaults
  and automatic inference where appropriate.
  """
  @spec get() :: t()
  def get do
    %{
      repo: repo(),
      storage: storage_backend(),
      lineage: lineage_enabled?(),
      async_default: async_default?(),
      oban: oban_config()
    }
  end

  @doc """
  Get the configured Ecto repo, if any.
  """
  @spec repo() :: module() | nil
  def repo do
    Application.get_env(:flowstone, :repo)
  end

  @doc """
  Get the storage backend to use.

  - If explicitly configured via `:storage`, use that
  - If a repo is configured, default to `:postgres`
  - Otherwise, default to `:memory`
  """
  @spec storage_backend() :: :memory | :postgres | :s3 | :parquet
  def storage_backend do
    case Application.get_env(:flowstone, :storage) do
      nil ->
        # Auto-detect based on repo
        if repo(), do: :postgres, else: :memory

      # Support legacy config
      storage when is_atom(storage) ->
        storage
    end
  end

  @doc """
  Check if lineage tracking is enabled.

  - If explicitly configured, use that value
  - If a repo is configured, default to `true`
  - Otherwise, default to `false`
  """
  @spec lineage_enabled?() :: boolean()
  def lineage_enabled? do
    case Application.get_env(:flowstone, :lineage) do
      nil -> repo() != nil
      value -> value
    end
  end

  @doc """
  Check if async execution is the default.
  """
  @spec async_default?() :: boolean()
  def async_default? do
    Application.get_env(:flowstone, :async_default, false)
  end

  @doc """
  Get Oban configuration.

  Returns `nil` if no repo is configured.
  """
  @spec oban_config() :: keyword() | nil
  def oban_config do
    case repo() do
      nil ->
        nil

      repo_module ->
        default_queues = [
          assets: 10,
          checkpoints: 5,
          parallel_join: 5,
          flowstone_scatter: 10
        ]

        # Merge with any explicit Oban config
        explicit_config = Application.get_env(:flowstone, Oban, [])

        Keyword.merge(
          [
            repo: repo_module,
            queues: default_queues,
            plugins: [Oban.Plugins.Pruner]
          ],
          explicit_config
        )
    end
  end

  @doc """
  Get the configured IO managers.

  Returns a map of manager name to module.
  """
  @spec io_managers() :: %{atom() => module()}
  def io_managers do
    Application.get_env(:flowstone, :io_managers, %{
      memory: FlowStone.IO.Memory,
      postgres: FlowStone.IO.Postgres,
      s3: FlowStone.IO.S3,
      parquet: FlowStone.IO.Parquet
    })
  end

  @doc """
  Get the default IO manager.

  Returns the storage backend as the default IO manager.
  """
  @spec default_io_manager() :: atom()
  def default_io_manager do
    # Check legacy config first
    case Application.get_env(:flowstone, :default_io_manager) do
      nil -> storage_backend()
      manager -> manager
    end
  end

  @doc """
  Validate the current configuration.

  Raises `FlowStone.ConfigError` if configuration is invalid.
  """
  @spec validate!() :: :ok
  def validate! do
    storage = storage_backend()

    # Validate storage backend
    unless storage in [:memory, :postgres, :s3, :parquet] do
      raise FlowStone.ConfigError,
        message:
          "Invalid storage backend: #{inspect(storage)}. Valid options: :memory, :postgres, :s3, :parquet"
    end

    # Validate S3 config if using S3
    if storage == :s3 do
      unless Application.get_env(:flowstone, :s3_bucket) do
        raise FlowStone.ConfigError,
          message: "S3 storage requires :s3_bucket configuration"
      end
    end

    # Validate postgres config if using postgres without repo
    if storage == :postgres and is_nil(repo()) do
      raise FlowStone.ConfigError,
        message: "Postgres storage requires :repo configuration"
    end

    :ok
  end

  @doc """
  Check if Oban should be started.

  Returns true if a repo is configured and start_oban is not explicitly false.
  """
  @spec start_oban?() :: boolean()
  def start_oban? do
    case Application.get_env(:flowstone, :start_oban) do
      nil -> repo() != nil
      value -> value
    end
  end

  @doc """
  Check if the repo should be managed by FlowStone.

  Generally false - users should manage their own repo in their supervision tree.
  """
  @spec start_repo?() :: boolean()
  def start_repo? do
    Application.get_env(:flowstone, :start_repo, false)
  end
end

defmodule FlowStone.ConfigError do
  @moduledoc """
  Exception raised for configuration errors.
  """
  defexception [:message]
end
