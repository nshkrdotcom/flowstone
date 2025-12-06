defmodule Examples.FailureExample do
  @moduledoc false

  def run do
    ensure_started(FlowStone.Registry, name: :examples_failure_registry)
    ensure_started(FlowStone.IO.Memory, name: :examples_failure_io)
    ensure_started(FlowStone.MaterializationStore, name: :examples_failure_store)

    FlowStone.register(Pipeline, registry: :examples_failure_registry)

    run_id = Ecto.UUID.generate()

    FlowStone.materialize(:flaky,
      partition: :will_fail,
      registry: :examples_failure_registry,
      io: [config: %{agent: :examples_failure_io}],
      resource_server: nil,
      materialization_store: :examples_failure_store,
      use_repo: false,
      run_id: run_id
    )

    FlowStone.ObanHelpers.drain()

    mat = FlowStone.MaterializationStore.get(:flaky, :will_fail, run_id, :examples_failure_store)

    %{materialization: mat}
  end

  defp ensure_started(mod, opts) do
    case Process.whereis(opts[:name]) do
      nil -> mod.start_link(opts)
      pid when is_pid(pid) -> {:ok, pid}
    end
  end

  defmodule Pipeline do
    use FlowStone.Pipeline

    asset :flaky do
      execute fn _, _ -> {:error, "simulated failure"} end
    end
  end
end
