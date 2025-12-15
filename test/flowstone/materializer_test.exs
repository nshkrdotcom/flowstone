defmodule FlowStone.MaterializerTest do
  use FlowStone.TestCase, isolation: :full_isolation
  import ExUnit.CaptureLog

  alias FlowStone.{Asset, Context, Error, Materializer}

  setup do
    context = %Context{
      asset: :demo,
      partition: :default,
      run_id: Ecto.UUID.generate(),
      resources: %{}
    }

    %{context: context}
  end

  test "executes asset and returns ok tuple", %{context: context} do
    asset = %Asset{
      name: :demo,
      module: __MODULE__,
      line: 1,
      execute_fn: fn _ctx, _deps -> {:ok, :value} end
    }

    assert {:ok, :value} = Materializer.execute(asset, context, %{})
  end

  test "wraps unexpected return values", %{context: context} do
    asset = %Asset{
      name: :demo,
      module: __MODULE__,
      line: 1,
      execute_fn: fn _ctx, _deps -> :value end
    }

    {result, log} =
      with_log(fn ->
        Materializer.execute(asset, context, %{})
      end)

    assert {:error, %Error{type: :execution_error, retryable: false}} = result
    assert log =~ "Unexpected return"
  end

  test "handles wait_for_approval tuple" do
    asset = %Asset{
      name: :demo,
      module: __MODULE__,
      line: 1,
      execute_fn: fn _ctx, _deps -> {:wait_for_approval, %{message: "please"}} end
    }

    ctx = %Context{
      asset: :demo,
      partition: :default,
      run_id: Ecto.UUID.generate(),
      resources: %{}
    }

    {:ok, _} = start_supervised({FlowStone.Checkpoint, name: :mat_notifier})

    {:error, %Error{}} =
      Materializer.execute(asset, ctx, %{})

    assert [] == FlowStone.Approvals.list_pending(use_repo: false, server: :mat_notifier)
  end

  test "wraps raised exceptions", %{context: context} do
    asset = %Asset{
      name: :demo,
      module: __MODULE__,
      line: 1,
      execute_fn: fn _, _ -> raise "boom" end
    }

    {result, log} =
      with_log(fn ->
        Materializer.execute(asset, context, %{})
      end)

    assert {:error, %Error{type: :execution_error, message: msg}} = result
    assert msg =~ "boom"
    assert log =~ "Asset execution failed"
  end
end
