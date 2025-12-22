defmodule FlowStone.ResourcesTest do
  use FlowStone.TestCase, isolation: :full_isolation

  defmodule DummyResource do
    use FlowStone.Resource

    @impl true
    def setup(config), do: {:ok, Map.fetch!(config, :value)}
  end

  defmodule FailingResource do
    use FlowStone.Resource

    @impl true
    def setup(_config), do: {:error, :connection_refused}
  end

  setup do
    {:ok, pid} =
      start_supervised(
        {FlowStone.Resources,
         name: :resources_test, resources: %{dummy: {DummyResource, %{value: 42}}}}
      )

    %{server: pid}
  end

  test "loads configured resources", %{server: server} do
    assert {:ok, 42} = FlowStone.Resources.get(:dummy, server)
    assert %{dummy: 42} = FlowStone.Resources.load(server)
  end

  test "override replaces resources", %{server: server} do
    FlowStone.Resources.override(%{dummy: :new}, server)
    assert {:ok, :new} = FlowStone.Resources.get(:dummy, server)
  end

  describe "resilient startup" do
    test "continues startup when a resource fails" do
      # Start a server with one working and one failing resource
      {:ok, pid} =
        start_supervised(
          {FlowStone.Resources,
           name: :resilient_test,
           resources: %{
             working: {DummyResource, %{value: 100}},
             failing: {FailingResource, %{}}
           }},
          id: :resilient_resources
        )

      # Working resource should be available
      assert {:ok, 100} = FlowStone.Resources.get(:working, pid)

      # Failing resource should return an error tuple
      assert {:error, {:setup_failed, :connection_refused}} =
               FlowStone.Resources.get(:failing, pid)

      # Should be able to query failed resources
      failed = FlowStone.Resources.list_failed(pid)
      assert :failing in Enum.map(failed, & &1.name)
    end

    test "emits telemetry on resource failure" do
      ref = make_ref()
      test_pid = self()

      :telemetry.attach(
        "test-resource-failure-#{inspect(ref)}",
        [:flowstone, :resources, :setup_failed],
        fn event, measurements, meta, _ ->
          send(test_pid, {:telemetry, event, measurements, meta})
        end,
        nil
      )

      {:ok, _pid} =
        start_supervised(
          {FlowStone.Resources,
           name: :telemetry_test,
           resources: %{
             failing: {FailingResource, %{}}
           }},
          id: :telemetry_resources
        )

      assert_receive {:telemetry, [:flowstone, :resources, :setup_failed], _, %{name: :failing}},
                     1000

      :telemetry.detach("test-resource-failure-#{inspect(ref)}")
    end
  end
end
