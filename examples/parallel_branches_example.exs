defmodule Examples.ParallelBranchesExample do
  @moduledoc false

  def run do
    ensure_started(FlowStone.Registry, name: :examples_parallel_registry)
    ensure_started(FlowStone.IO.Memory, name: :examples_parallel_io)

    FlowStone.register(__MODULE__.Pipeline, registry: :examples_parallel_registry)

    io_opts = [config: %{agent: :examples_parallel_io}]
    run_id = Ecto.UUID.generate()
    partition = :demo

    IO.puts("==> Parallel branches example")
    IO.puts("Run id: #{run_id}")
    IO.write(:stderr, "\nExpected error: optional branch :process_keywords fails (demo): ")

    FlowStone.materialize_all(:parallel_enrich,
      partition: partition,
      registry: :examples_parallel_registry,
      io: io_opts,
      resource_server: nil,
      run_id: run_id
    )

    FlowStone.ObanHelpers.drain()

    {:ok, output} = FlowStone.IO.load(:parallel_enrich, partition, io_opts)
    IO.puts("Join output:")
    IO.inspect(output)

    {:ok, output}
  end

  defp ensure_started(mod, opts) do
    case Process.whereis(opts[:name]) do
      nil -> mod.start_link(opts)
      pid when is_pid(pid) -> {:ok, pid}
    end
  end

  defmodule Pipeline do
    use FlowStone.Pipeline

    asset :input do
      execute fn _, _ -> {:ok, %{topic: "space"}} end
    end

    asset :generate_maps do
      depends_on([:input])
      execute fn _, %{input: input} -> {:ok, "maps for #{input.topic}"} end
    end

    asset :get_front_pages do
      depends_on([:input])
      execute fn _, %{input: input} -> {:ok, "news for #{input.topic}"} end
    end

    asset :process_keywords do
      depends_on([:input])
      execute fn _, _ -> {:error, "keyword source unavailable"} end
    end

    asset :parallel_enrich do
      depends_on([:input])

      parallel do
        branch(:maps, final: :generate_maps)
        branch(:news, final: :get_front_pages)
        branch(:web_sources, final: :process_keywords, required: false)
      end

      parallel_options do
        failure_mode(:partial)
      end

      join(fn branches, deps ->
        %{
          maps: branches.maps,
          news: branches.news,
          web_sources: branches.web_sources,
          topic: deps.input.topic
        }
      end)
    end
  end
end

if System.get_env("FLOWSTONE_RUN_ALL") != "1" do
  Examples.ParallelBranchesExample.run()
end
