defmodule FlowStone.SignalGateTest do
  use FlowStone.TestCase, isolation: :full_isolation

  alias FlowStone.SignalGate
  alias FlowStone.SignalGate.{Gate, Token}
  alias FlowStone.{Materialization, Repo}

  setup do
    # Create a materialization for testing
    {:ok, mat} =
      %Materialization{}
      |> Materialization.changeset(%{
        asset_name: "test_asset",
        run_id: Ecto.UUID.generate(),
        status: :running
      })
      |> Repo.insert()

    {:ok, materialization: mat}
  end

  describe "Token" do
    test "generate/2 creates signed token" do
      expires_at = DateTime.add(DateTime.utc_now(), 3600, :second)
      token = Token.generate("task-123", expires_at)

      assert is_binary(token)
      assert String.contains?(token, ".")
    end

    test "validate/1 accepts valid token" do
      expires_at = DateTime.add(DateTime.utc_now(), 3600, :second)
      token = Token.generate("task-123", expires_at)

      {:ok, result} = Token.validate(token)

      assert result.token == "task-123"
      assert DateTime.compare(result.expires_at, DateTime.utc_now()) == :gt
    end

    test "validate/1 rejects expired token" do
      expires_at = DateTime.add(DateTime.utc_now(), -3600, :second)
      token = Token.generate("task-123", expires_at)

      assert {:error, :expired} = Token.validate(token)
    end

    test "validate/1 rejects tampered token" do
      expires_at = DateTime.add(DateTime.utc_now(), 3600, :second)
      token = Token.generate("task-123", expires_at)
      tampered = String.replace(token, "task-123", "task-456")

      assert {:error, :invalid_signature} = Token.validate(tampered)
    end

    test "validate/1 rejects malformed token" do
      assert {:error, :malformed_token} = Token.validate("invalid")
      assert {:error, :malformed_token} = Token.validate("no.dots")
    end

    test "hash/1 generates consistent hashes" do
      hash1 = Token.hash("token1")
      hash2 = Token.hash("token1")
      hash3 = Token.hash("token2")

      assert hash1 == hash2
      assert hash1 != hash3
      assert String.length(hash1) == 32
    end

    test "generate_base_token/0 creates random tokens" do
      token1 = Token.generate_base_token()
      token2 = Token.generate_base_token()

      assert is_binary(token1)
      assert token1 != token2
    end
  end

  describe "Gate" do
    test "can_signal?/1 returns true for waiting gates", %{materialization: mat} do
      gate = %Gate{materialization_id: mat.id, status: :waiting}
      assert Gate.can_signal?(gate)
    end

    test "can_signal?/1 returns false for signaled gates", %{materialization: mat} do
      gate = %Gate{materialization_id: mat.id, status: :signaled}
      refute Gate.can_signal?(gate)
    end

    test "timed_out?/1 detects expired gates", %{materialization: mat} do
      past = DateTime.add(DateTime.utc_now(), -3600, :second)
      future = DateTime.add(DateTime.utc_now(), 3600, :second)

      expired = %Gate{materialization_id: mat.id, status: :waiting, timeout_at: past}
      active = %Gate{materialization_id: mat.id, status: :waiting, timeout_at: future}

      assert Gate.timed_out?(expired)
      refute Gate.timed_out?(active)
    end

    test "wait_duration_ms/1 calculates wait time", %{materialization: mat} do
      created = DateTime.add(DateTime.utc_now(), -5000, :millisecond)
      signaled = DateTime.add(DateTime.utc_now(), -1000, :millisecond)

      gate = %Gate{
        materialization_id: mat.id,
        inserted_at: created,
        signaled_at: signaled
      }

      duration = Gate.wait_duration_ms(gate)
      assert duration >= 3900 and duration <= 4100
    end
  end

  describe "SignalGate.create/1" do
    test "creates gate with signed token", %{materialization: mat} do
      {:ok, gate} =
        SignalGate.create(
          materialization_id: mat.id,
          token: "task-123",
          timeout: :timer.hours(1)
        )

      assert gate.materialization_id == mat.id
      assert gate.status == :waiting
      assert is_binary(gate.token)
      assert is_binary(gate.token_hash)
      assert gate.timeout_at != nil
    end

    test "creates gate with custom options", %{materialization: mat} do
      {:ok, gate} =
        SignalGate.create(
          materialization_id: mat.id,
          token: "task-123",
          timeout: :timer.minutes(30),
          timeout_action: :retry,
          max_timeout_retries: 5,
          metadata: %{"task_type" => "embedding"}
        )

      assert gate.timeout_action == :retry
      assert gate.max_timeout_retries == 5
      assert gate.metadata["task_type"] == "embedding"
    end
  end

  describe "SignalGate.receive_signal/3" do
    test "records signal for waiting gate", %{materialization: mat} do
      {:ok, gate} =
        SignalGate.create(
          materialization_id: mat.id,
          token: "task-123",
          timeout: :timer.hours(1)
        )

      payload = %{"status" => "success", "result" => [1, 2, 3]}

      {:ok, signaled} =
        SignalGate.receive_signal(gate.token, payload,
          source_ip: "192.168.1.1",
          headers: %{"content-type" => "application/json"}
        )

      assert signaled.status == :signaled
      assert signaled.signal_payload == payload
      assert signaled.signal_source_ip == "192.168.1.1"
      assert signaled.signaled_at != nil
    end

    test "rejects signal for already signaled gate", %{materialization: mat} do
      {:ok, gate} =
        SignalGate.create(
          materialization_id: mat.id,
          token: "task-123",
          timeout: :timer.hours(1)
        )

      {:ok, _} = SignalGate.receive_signal(gate.token, %{"status" => "success"})
      {:error, :already_signaled} = SignalGate.receive_signal(gate.token, %{"status" => "again"})
    end

    test "rejects signal with invalid token", %{materialization: _mat} do
      {:error, _} = SignalGate.receive_signal("invalid.token.sig", %{})
    end
  end

  describe "SignalGate.get_by_token/1" do
    test "retrieves gate by valid token", %{materialization: mat} do
      {:ok, gate} =
        SignalGate.create(
          materialization_id: mat.id,
          token: "task-123",
          timeout: :timer.hours(1)
        )

      {:ok, found} = SignalGate.get_by_token(gate.token)
      assert found.id == gate.id
    end

    test "returns error for invalid token", %{materialization: _mat} do
      {:error, _} = SignalGate.get_by_token("invalid.token.sig")
    end
  end

  describe "SignalGate.cancel/1" do
    test "cancels waiting gate", %{materialization: mat} do
      {:ok, gate} =
        SignalGate.create(
          materialization_id: mat.id,
          token: "task-123",
          timeout: :timer.hours(1)
        )

      {:ok, cancelled} = SignalGate.cancel(gate.id)
      assert cancelled.status == :cancelled
    end
  end

  describe "SignalGate.handle_timeout/1" do
    test "marks gate as timed out", %{materialization: mat} do
      {:ok, gate} =
        SignalGate.create(
          materialization_id: mat.id,
          token: "task-123",
          timeout: 1,
          timeout_action: :fail
        )

      # Wait for timeout
      Process.sleep(10)

      {:ok, timed_out} = SignalGate.handle_timeout(gate)
      assert timed_out.status == :timeout
    end

    test "retries when configured", %{materialization: mat} do
      {:ok, gate} =
        SignalGate.create(
          materialization_id: mat.id,
          token: "task-123",
          timeout: 1,
          timeout_action: :retry,
          max_timeout_retries: 3
        )

      {:ok, retried} = SignalGate.handle_timeout(gate)
      assert retried.status == :waiting
      assert retried.timeout_retries == 1
    end
  end

  describe "SignalGate.callback_url/2" do
    test "generates callback URL", %{materialization: mat} do
      {:ok, gate} =
        SignalGate.create(
          materialization_id: mat.id,
          token: "task-123",
          timeout: :timer.hours(1)
        )

      url = SignalGate.callback_url(gate, base_url: "https://api.example.com")

      assert String.starts_with?(url, "https://api.example.com/hooks/flowstone/signal/")
    end
  end

  describe "SignalGate.list_waiting/1" do
    test "lists waiting gates", %{materialization: mat} do
      {:ok, _gate1} =
        SignalGate.create(
          materialization_id: mat.id,
          token: "task-1",
          timeout: :timer.hours(1)
        )

      # Need another materialization for second gate
      {:ok, mat2} =
        %Materialization{}
        |> Materialization.changeset(%{
          asset_name: "test_asset_2",
          run_id: Ecto.UUID.generate(),
          status: :running
        })
        |> Repo.insert()

      {:ok, _gate2} =
        SignalGate.create(
          materialization_id: mat2.id,
          token: "task-2",
          timeout: :timer.hours(2)
        )

      waiting = SignalGate.list_waiting()
      assert length(waiting) >= 2
    end
  end
end
