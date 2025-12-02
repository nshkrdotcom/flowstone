defmodule FlowStone.IO.Manager do
  @moduledoc """
  Behaviour for pluggable storage backends.
  """

  @callback load(asset :: atom(), partition :: term(), config :: map()) ::
              {:ok, term()} | {:error, :not_found} | {:error, term()}

  @callback store(asset :: atom(), data :: term(), partition :: term(), config :: map()) ::
              :ok | {:error, term()}

  @callback delete(asset :: atom(), partition :: term(), config :: map()) ::
              :ok | {:error, term()}

  @callback metadata(asset :: atom(), partition :: term(), config :: map()) ::
              {:ok, map()} | {:error, term()}

  @callback exists?(asset :: atom(), partition :: term(), config :: map()) :: boolean()

  @optional_callbacks metadata: 3, exists?: 3
end
