defmodule FlowStone.Scatter.ItemReader do
  @moduledoc """
  Behavior for reading scatter items from external sources.
  """

  @type state :: term()
  @type item :: map()
  @type config :: map()
  @type deps :: map()

  @callback init(config(), deps()) :: {:ok, state()} | {:error, term()}
  @callback read(state(), batch_size :: pos_integer()) ::
              {:ok, [item()], state() | :halt} | {:error, term()}
  @callback count(state()) :: {:ok, non_neg_integer()} | :unknown
  @callback checkpoint(state()) :: map()
  @callback restore(state(), checkpoint :: map()) :: state()
  @callback close(state()) :: :ok

  @spec resolve(atom()) :: module()
  def resolve(:s3), do: FlowStone.Scatter.ItemReaders.S3
  def resolve(:dynamodb), do: FlowStone.Scatter.ItemReaders.DynamoDB
  def resolve(:postgres), do: FlowStone.Scatter.ItemReaders.Postgres
  def resolve(:custom), do: FlowStone.Scatter.ItemReaders.Custom
  def resolve(module) when is_atom(module), do: module
end
