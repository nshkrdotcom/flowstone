defmodule FlowStone.Schedule do
  @moduledoc """
  Represents a scheduled asset materialization configuration.
  """

  defstruct [
    :asset,
    :cron,
    :registry,
    :io,
    :resource_server,
    :lineage_server,
    :use_repo,
    timezone: "UTC",
    partition_fn: nil,
    enabled: true
  ]

  @type t :: %__MODULE__{
          asset: atom(),
          cron: String.t(),
          registry: atom() | pid() | nil,
          io: keyword(),
          resource_server: atom() | pid() | nil,
          lineage_server: atom() | pid() | nil,
          use_repo: boolean() | nil,
          timezone: String.t(),
          partition_fn: (-> term()) | nil,
          enabled: boolean()
        }
end
