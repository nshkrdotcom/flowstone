defmodule Examples.ScheduleExample do
  @moduledoc false

  def run do
    ensure_started(FlowStone.Registry, name: :examples_schedule_registry)
    ensure_started(FlowStone.IO.Memory, name: :examples_schedule_io)
    ensure_started(FlowStone.ScheduleStore, name: :examples_schedule_store)

    FlowStone.register(Pipeline, registry: :examples_schedule_registry)

    :ok =
      FlowStone.schedule(:scheduled_asset,
        cron: "* * * * *",
        partition: fn -> Date.utc_today() end,
        store: :examples_schedule_store,
        registry: :examples_schedule_registry,
        io: [config: %{agent: :examples_schedule_io}],
        resource_server: nil,
        use_repo: false
      )

    {:ok, _} =
      FlowStone.Schedules.Scheduler.start_link(
        name: :examples_scheduler,
        store: :examples_schedule_store
      )

    schedule = hd(FlowStone.list_schedules(store: :examples_schedule_store))
    FlowStone.Schedules.Scheduler.run_now(schedule, :examples_scheduler)

    FlowStone.ObanHelpers.drain()

    FlowStone.IO.load(:scheduled_asset, Date.utc_today(), config: %{agent: :examples_schedule_io})
  end

  defp ensure_started(mod, opts) do
    case Process.whereis(opts[:name]) do
      nil -> mod.start_link(opts)
      pid when is_pid(pid) -> {:ok, pid}
    end
  end

  defmodule Pipeline do
    use FlowStone.Pipeline

    asset :scheduled_asset do
      execute fn _ctx, _deps -> {:ok, :scheduled_value} end
    end
  end
end
