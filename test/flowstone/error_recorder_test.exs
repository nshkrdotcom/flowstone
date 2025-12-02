defmodule FlowStone.ErrorRecorderTest do
  use FlowStone.TestCase, isolation: :full_isolation
  import ExUnit.CaptureLog

  def handle_event(_event, _meas, metadata, pid) do
    send(pid, {:telemetry, metadata})
  end

  test "emits telemetry and logs" do
    error = %FlowStone.Error{
      type: :execution_error,
      message: "boom",
      context: %{},
      retryable: false
    }

    :telemetry.attach(
      "flowstone-error-test",
      [:flowstone, :error],
      &__MODULE__.handle_event/4,
      self()
    )

    log =
      capture_log(fn ->
        :ok = FlowStone.ErrorRecorder.record(error, %{asset: :a, partition: :p})
      end)

    assert_receive {:telemetry, %{type: :execution_error}}
    assert log =~ "FlowStone error"
  after
    :telemetry.detach("flowstone-error-test")
  end
end
