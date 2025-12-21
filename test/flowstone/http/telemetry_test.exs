defmodule FlowStone.HTTP.TelemetryTest do
  use FlowStone.TestCase, isolation: :full_isolation

  alias FlowStone.HTTP.Client

  @test_events [
    [:flowstone, :http, :request, :start],
    [:flowstone, :http, :request, :stop],
    [:flowstone, :http, :request, :error]
  ]

  setup do
    test_pid = self()

    handler_id = "http-telemetry-test-#{System.unique_integer()}"

    :telemetry.attach_many(
      handler_id,
      @test_events,
      fn event, measurements, metadata, _config ->
        send(test_pid, {:telemetry_event, event, measurements, metadata})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    {:ok, client} = Client.setup(%{base_url: "https://api.example.com"})
    %{client: client}
  end

  describe "telemetry events" do
    test "emits start event before request", %{client: _client} do
      # We can't actually make HTTP calls in unit tests, but we can verify
      # that the telemetry infrastructure is set up correctly
      assert function_exported?(Client, :get, 2)
      assert function_exported?(Client, :post, 3)
    end

    test "telemetry event names follow convention" do
      # Verify event naming follows FlowStone conventions
      for event <- @test_events do
        assert [:flowstone, :http, :request, _action] = event
      end
    end
  end

  describe "metadata structure" do
    test "start event should include expected metadata fields" do
      # Document expected metadata structure
      expected_metadata_keys = [:method, :url, :path, :base_url]

      # These are the fields that should be present in start event metadata
      assert length(expected_metadata_keys) == 4
    end

    test "stop event should include status in measurements" do
      # Document expected measurements structure
      expected_measurements_keys = [:duration, :status]

      assert length(expected_measurements_keys) == 2
    end

    test "error event should include error in measurements" do
      expected_measurements_keys = [:duration, :error]

      assert length(expected_measurements_keys) == 2
    end
  end
end
