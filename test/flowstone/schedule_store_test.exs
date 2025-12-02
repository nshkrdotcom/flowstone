defmodule FlowStone.ScheduleStoreTest do
  use FlowStone.TestCase, isolation: :full_isolation

  setup do
    {:ok, _} = start_supervised({FlowStone.ScheduleStore, name: :schedule_store})
    :ok
  end

  test "adds, lists, removes schedules" do
    :ok = FlowStone.schedule(:daily, cron: "0 2 * * *", store: :schedule_store)
    assert [%FlowStone.Schedule{asset: :daily}] = FlowStone.list_schedules(store: :schedule_store)
    :ok = FlowStone.unschedule(:daily, store: :schedule_store)
    assert [] = FlowStone.list_schedules(store: :schedule_store)
  end

  defmodule ScheduleTestPipeline do
    use FlowStone.Pipeline

    asset :foo do
      execute fn _, _ -> {:ok, :foo} end
    end
  end

  test "scheduler enqueues materialization via partition_fn" do
    {:ok, _} = start_supervised({FlowStone.Registry, name: :sched_registry})
    {:ok, _} = start_supervised({FlowStone.IO.Memory, name: :sched_memory})

    FlowStone.register(ScheduleTestPipeline, registry: :sched_registry)

    :ok =
      FlowStone.schedule(:foo,
        cron: "* * * * *",
        partition: fn -> :scheduled end,
        store: :schedule_store,
        registry: :sched_registry,
        io: [config: %{agent: :sched_memory}],
        resource_server: nil,
        use_repo: false
      )

    {:ok, pid} =
      start_supervised(
        {FlowStone.Schedules.Scheduler, name: :test_scheduler, store: :schedule_store}
      )

    # Trigger immediately
    schedule = hd(FlowStone.list_schedules(store: :schedule_store))
    :ok = FlowStone.Schedules.Scheduler.run_now(schedule, pid)

    assert {:ok, :foo} = FlowStone.IO.load(:foo, :scheduled, config: %{agent: :sched_memory})
  end
end
