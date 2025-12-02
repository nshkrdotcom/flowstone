defmodule FlowStone.ScheduleStoreTest do
  use Supertester.ExUnitFoundation, isolation: :full_isolation

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
end
