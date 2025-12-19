defmodule Examples.CoreExample do
  @moduledoc false

  def run do
    ensure_started(FlowStone.Registry, name: :examples_core_registry)
    ensure_started(FlowStone.IO.Memory, name: :examples_core_io)

    FlowStone.register(__MODULE__.Pipeline, registry: :examples_core_registry)

    FlowStone.materialize_all(:echo,
      partition: :demo,
      registry: :examples_core_registry,
      io: [config: %{agent: :examples_core_io}],
      resource_server: nil
    )

    FlowStone.ObanHelpers.drain()

    FlowStone.IO.load(:echo, :demo, config: %{agent: :examples_core_io})
  end

  defp ensure_started(mod, opts) do
    case Process.whereis(opts[:name]) do
      nil -> mod.start_link(opts)
      pid when is_pid(pid) -> {:ok, pid}
    end
  end

  defmodule Pipeline do
    use FlowStone.Pipeline

    asset :source do
      execute fn _, _ -> {:ok, "hello"} end
    end

    asset :echo do
      depends_on([:source])
      execute fn _, %{source: msg} -> {:ok, String.upcase(msg)} end
    end
  end
end
