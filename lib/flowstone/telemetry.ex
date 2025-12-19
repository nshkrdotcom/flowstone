defmodule FlowStone.Telemetry do
  @moduledoc """
  Central event names for FlowStone telemetry.

  ## Materialization Events

  - `[:flowstone, :materialization, :start]` - Asset execution started
  - `[:flowstone, :materialization, :stop]` - Asset execution completed
  - `[:flowstone, :materialization, :exception]` - Asset execution failed

  ## Scatter Events

  - `[:flowstone, :scatter, :start]` - Scatter barrier created
  - `[:flowstone, :scatter, :complete]` - All scatter instances finished
  - `[:flowstone, :scatter, :failed]` - Scatter exceeded failure threshold
  - `[:flowstone, :scatter, :cancel]` - Scatter barrier cancelled
  - `[:flowstone, :scatter, :instance_complete]` - Single scatter instance completed
  - `[:flowstone, :scatter, :instance_fail]` - Single scatter instance failed
  - `[:flowstone, :scatter, :gather_ready]` - Scatter ready for downstream gather
  - `[:flowstone, :scatter, :batch_start]` - Reader batch started (distributed)
  - `[:flowstone, :scatter, :batch_complete]` - Reader batch completed (distributed)

  ## ItemReader Events

  - `[:flowstone, :item_reader, :init]` - ItemReader initialized
  - `[:flowstone, :item_reader, :read]` - ItemReader batch read
  - `[:flowstone, :item_reader, :complete]` - ItemReader finished
  - `[:flowstone, :item_reader, :error]` - ItemReader error

  ## ItemBatcher Events

  - `[:flowstone, :scatter, :batch_create]` - Batches created for scatter
  - `[:flowstone, :scatter, :batch_start]` - Batch execution started
  - `[:flowstone, :scatter, :batch_complete]` - Batch execution completed
  - `[:flowstone, :scatter, :batch_fail]` - Batch execution failed

  ## Signal Gate Events

  - `[:flowstone, :signal_gate, :create]` - Gate created, waiting for signal
  - `[:flowstone, :signal_gate, :signal]` - Signal received
  - `[:flowstone, :signal_gate, :timeout]` - Gate timed out
  - `[:flowstone, :signal_gate, :timeout_retry]` - Gate timeout, will retry
  - `[:flowstone, :signal_gate, :cancel]` - Gate cancelled

  ## Rate Limiting Events

  - `[:flowstone, :rate_limit, :check]` - Rate limit checked
  - `[:flowstone, :rate_limit, :wait]` - Operation rate limited
  - `[:flowstone, :rate_limit, :slot_acquired]` - Semaphore slot acquired
  - `[:flowstone, :rate_limit, :slot_released]` - Semaphore slot released

  ## Routing Events

  - `[:flowstone, :route, :start]` - Routing evaluation started
  - `[:flowstone, :route, :stop]` - Routing decision recorded
  - `[:flowstone, :route, :error]` - Routing evaluation failed

  ## Parallel Events

  - `[:flowstone, :parallel, :start]` - Parallel execution started
  - `[:flowstone, :parallel, :stop]` - Parallel execution completed
  - `[:flowstone, :parallel, :error]` - Parallel execution failed
  - `[:flowstone, :parallel, :branch_start]` - Branch execution enqueued
  - `[:flowstone, :parallel, :branch_complete]` - Branch execution completed
  - `[:flowstone, :parallel, :branch_fail]` - Branch execution failed
  """

  @events [
    # Materialization
    [:flowstone, :materialization, :start],
    [:flowstone, :materialization, :stop],
    [:flowstone, :materialization, :exception],
    # I/O
    [:flowstone, :io, :load, :start],
    [:flowstone, :io, :load, :stop],
    [:flowstone, :io, :store, :start],
    [:flowstone, :io, :store, :stop],
    # Checkpoints
    [:flowstone, :checkpoint, :requested],
    [:flowstone, :checkpoint, :approved],
    [:flowstone, :checkpoint, :rejected],
    [:flowstone, :checkpoint, :timeout],
    # Sensors
    [:flowstone, :sensor, :poll],
    [:flowstone, :sensor, :trigger],
    # Errors
    [:flowstone, :error],
    # Scatter
    [:flowstone, :scatter, :start],
    [:flowstone, :scatter, :complete],
    [:flowstone, :scatter, :failed],
    [:flowstone, :scatter, :cancel],
    [:flowstone, :scatter, :instance_complete],
    [:flowstone, :scatter, :instance_fail],
    [:flowstone, :scatter, :gather_ready],
    [:flowstone, :scatter, :batch_start],
    [:flowstone, :scatter, :batch_complete],
    [:flowstone, :scatter, :batch_create],
    [:flowstone, :scatter, :batch_fail],
    [:flowstone, :item_reader, :init],
    [:flowstone, :item_reader, :read],
    [:flowstone, :item_reader, :complete],
    [:flowstone, :item_reader, :error],
    # Signal Gate
    [:flowstone, :signal_gate, :create],
    [:flowstone, :signal_gate, :signal],
    [:flowstone, :signal_gate, :timeout],
    [:flowstone, :signal_gate, :timeout_retry],
    [:flowstone, :signal_gate, :cancel],
    # Rate Limiting
    [:flowstone, :rate_limit, :check],
    [:flowstone, :rate_limit, :wait],
    [:flowstone, :rate_limit, :slot_acquired],
    [:flowstone, :rate_limit, :slot_released],
    # Routing
    [:flowstone, :route, :start],
    [:flowstone, :route, :stop],
    [:flowstone, :route, :error],
    # Parallel
    [:flowstone, :parallel, :start],
    [:flowstone, :parallel, :stop],
    [:flowstone, :parallel, :error],
    [:flowstone, :parallel, :branch_start],
    [:flowstone, :parallel, :branch_complete],
    [:flowstone, :parallel, :branch_fail]
  ]

  def events, do: @events
end
