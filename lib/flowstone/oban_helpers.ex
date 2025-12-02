defmodule FlowStone.ObanHelpers do
  @moduledoc """
  Convenience helpers for draining Oban queues in tests.
  """

  @default_opts [queue: :assets, with_recursion: true]

  @doc """
  Drain the configured Oban queue, waiting for currently enqueued jobs to finish.
  """
  def drain(opts \\ []) do
    opts = Keyword.merge(@default_opts, opts)
    Oban.drain_queue(opts)
  end
end
