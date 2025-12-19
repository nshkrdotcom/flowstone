defmodule Examples.ConditionalRoutingExample do
  @moduledoc false

  def run do
    ensure_started(FlowStone.Registry, name: :examples_route_registry)
    ensure_started(FlowStone.IO.Memory, name: :examples_route_io)

    FlowStone.register(__MODULE__.Pipeline, registry: :examples_route_registry)

    io_opts = [config: %{agent: :examples_route_io}]
    run_id = Ecto.UUID.generate()
    partition = :demo

    IO.puts("==> Conditional routing example")
    IO.puts("Input mode: :a (expect branch_a)")
    IO.puts("Run id: #{run_id}")
    IO.puts("")

    FlowStone.materialize_all(:merge,
      partition: partition,
      registry: :examples_route_registry,
      io: io_opts,
      resource_server: nil,
      run_id: run_id
    )

    FlowStone.ObanHelpers.drain()

    {:ok, router_output} = FlowStone.IO.load(:router, partition, io_opts)
    branch_a = FlowStone.IO.load(:branch_a, partition, io_opts)
    branch_b = FlowStone.IO.load(:branch_b, partition, io_opts)
    {:ok, merge_output} = FlowStone.IO.load(:merge, partition, io_opts)

    IO.puts("Router decision:")
    IO.puts("  selected_branch: #{inspect(router_output.selected_branch)}")
    IO.puts("  available_branches: #{inspect(router_output.available_branches)}")
    IO.puts("  decision_id: #{inspect(router_output.decision_id)}")
    IO.puts("")

    IO.puts("Branch outputs:")
    IO.puts("  branch_a: #{format_result(branch_a)}")
    IO.puts("  branch_b: #{format_result(branch_b)} (skipped -> no IO record)")
    IO.puts("")

    IO.puts("Merge output (optional deps): #{inspect(merge_output)}")

    {:ok, merge_output}
  end

  defp ensure_started(mod, opts) do
    case Process.whereis(opts[:name]) do
      nil -> mod.start_link(opts)
      pid when is_pid(pid) -> {:ok, pid}
    end
  end

  defp format_result({:ok, value}), do: inspect(value)
  defp format_result({:error, reason}), do: "error: #{inspect(reason)}"

  defmodule Pipeline do
    use FlowStone.Pipeline

    asset :source do
      execute fn _, _ -> {:ok, %{mode: :a}} end
    end

    asset :router do
      depends_on([:source])

      route do
        choice(:branch_a, when: fn %{source: %{mode: :a}} -> true end)
        default(:branch_b)
      end
    end

    asset :branch_a do
      routed_from(:router)
      depends_on([:source])
      execute fn _, _ -> {:ok, :a} end
    end

    asset :branch_b do
      routed_from(:router)
      depends_on([:source])
      execute fn _, _ -> {:ok, :b} end
    end

    asset :merge do
      depends_on([:branch_a, :branch_b])
      optional_deps([:branch_a, :branch_b])
      execute fn _, deps -> {:ok, deps[:branch_a] || deps[:branch_b]} end
    end
  end
end

if System.get_env("FLOWSTONE_RUN_ALL") != "1" do
  Examples.ConditionalRoutingExample.run()
end
