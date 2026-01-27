defmodule FlowStone.Handlers.AgenticHandlerTest do
  use ExUnit.Case, async: true

  alias FlowStone.Handlers.AgenticHandler

  defmodule MockSynapse do
    def coordinate(spec, inputs, context) do
      mock_fn = context[:coordinate_mock]

      if mock_fn do
        mock_fn.(spec, inputs, context)
      else
        {:ok,
         %Synapse.DelegationResult{
           status: :success,
           outputs: %{result: "mock_output"},
           telemetry: %{
             iterations: 1,
             total_tokens: 100,
             total_cost_usd: Decimal.new("0.01"),
             agents_invoked: spec.agents,
             consensus_score: 1.0
           }
         }}
      end
    end
  end

  describe "execute/2" do
    test "step with type: :agentic delegates to Synapse.coordinate/3" do
      step = %{
        id: "review-code",
        type: :agentic,
        synapse_spec: %{
          coordinator: :test_coordinator,
          agents: [:reviewer_agent],
          max_iterations: 3,
          consensus_threshold: 0.8,
          escalation_policy: :on_failure
        },
        inputs: [:code_diff],
        outputs: [:review_result],
        timeout_ms: 300_000
      }

      context = %{
        run_id: "run-123",
        inputs: %{code_diff: "diff content"},
        resources: %{},
        elapsed_ms: 0,
        synapse_module: MockSynapse,
        coordinate_mock: fn _spec, _inputs, _ctx ->
          {:ok,
           %Synapse.DelegationResult{
             status: :success,
             outputs: %{review_result: %{approved: true}},
             telemetry: %{
               iterations: 1,
               total_tokens: 100,
               total_cost_usd: Decimal.new("0.01"),
               agents_invoked: [:reviewer_agent],
               consensus_score: 1.0
             }
           }}
        end
      }

      assert {:ok, outputs} = AgenticHandler.execute(step, context)
      assert outputs.review_result.approved == true
    end

    test "synapse_spec extracted from step and passed to Synapse" do
      step = %{
        id: "review-code",
        type: :agentic,
        synapse_spec: %{
          coordinator: :specific_coordinator,
          agents: [:agent_a, :agent_b],
          max_iterations: 5,
          consensus_threshold: 0.9,
          escalation_policy: :always_escalate
        },
        inputs: [:data],
        outputs: [:result],
        timeout_ms: 120_000
      }

      captured_spec = :erlang.make_ref()
      test_pid = self()

      context = %{
        run_id: "run-456",
        inputs: %{data: "test"},
        resources: %{},
        elapsed_ms: 0,
        synapse_module: MockSynapse,
        coordinate_mock: fn spec, _inputs, _ctx ->
          send(test_pid, {:captured_spec, spec})

          {:ok,
           %Synapse.DelegationResult{
             status: :success,
             outputs: %{result: "done"},
             telemetry: %{
               iterations: 1,
               total_tokens: 100,
               total_cost_usd: Decimal.new("0.01"),
               agents_invoked: [:agent_a, :agent_b],
               consensus_score: 1.0
             }
           }}
        end
      }

      AgenticHandler.execute(step, context)

      assert_receive {:captured_spec, spec}
      assert spec.coordinator == :specific_coordinator
      assert spec.agents == [:agent_a, :agent_b]
      assert spec.max_iterations == 5
    end

    test ":ok result stores outputs in step context" do
      step = %{
        id: "test-step",
        type: :agentic,
        synapse_spec: %{
          coordinator: nil,
          agents: [:agent_a],
          max_iterations: 1,
          consensus_threshold: 1.0,
          escalation_policy: :on_failure
        },
        inputs: [],
        outputs: [:result],
        timeout_ms: 60_000
      }

      context = %{
        run_id: "run-789",
        inputs: %{},
        resources: %{},
        elapsed_ms: 0,
        synapse_module: MockSynapse,
        coordinate_mock: fn _spec, _inputs, _ctx ->
          {:ok,
           %Synapse.DelegationResult{
             status: :success,
             outputs: %{result: %{data: "output_data"}},
             telemetry: %{
               iterations: 1,
               total_tokens: 50,
               total_cost_usd: Decimal.new("0.005"),
               agents_invoked: [:agent_a],
               consensus_score: 1.0
             }
           }}
        end
      }

      assert {:ok, outputs} = AgenticHandler.execute(step, context)
      assert outputs.result.data == "output_data"
    end

    test ":escalate result triggers approval gate" do
      step = %{
        id: "escalate-step",
        type: :agentic,
        synapse_spec: %{
          coordinator: :test,
          agents: [:agent_a, :agent_b],
          max_iterations: 5,
          consensus_threshold: 0.8,
          escalation_policy: :on_no_consensus
        },
        inputs: [],
        outputs: [:result],
        timeout_ms: 300_000
      }

      context = %{
        run_id: "run-esc",
        inputs: %{},
        resources: %{},
        elapsed_ms: 0,
        synapse_module: MockSynapse,
        coordinate_mock: fn _spec, _inputs, _ctx ->
          {:escalate,
           %Synapse.DelegationResult{
             status: :escalate,
             reason: :no_consensus,
             escalation_request: %{
               type: :human_decision,
               context: "Agents disagree",
               options: [:approve, :reject],
               agent_positions: %{agent_a: :approve, agent_b: :reject},
               disagreement_summary: "Disagreement summary"
             },
             telemetry: %{
               iterations: 5,
               total_tokens: 5000,
               total_cost_usd: Decimal.new("0.50"),
               agents_invoked: [:agent_a, :agent_b],
               consensus_score: 0.4
             }
           }}
        end
      }

      assert {:escalate, result} = AgenticHandler.execute(step, context)
      assert result.escalation_request.type == :human_decision
    end

    test ":timeout result handled per step timeout_policy" do
      step = %{
        id: "timeout-step",
        type: :agentic,
        synapse_spec: %{
          coordinator: :test,
          agents: [:agent_a],
          max_iterations: 10,
          consensus_threshold: 0.8,
          escalation_policy: :on_failure
        },
        inputs: [],
        outputs: [:result],
        timeout_ms: 1000,
        timeout_policy: :fail
      }

      context = %{
        run_id: "run-timeout",
        inputs: %{},
        resources: %{},
        elapsed_ms: 999,
        synapse_module: MockSynapse,
        coordinate_mock: fn _spec, _inputs, _ctx ->
          {:timeout,
           %Synapse.DelegationResult{
             status: :timeout,
             reason: :consensus_timeout,
             partial_outputs: %{partial: "data"},
             telemetry: %{
               iterations: 2,
               total_tokens: 1000,
               total_cost_usd: Decimal.new("0.10"),
               agents_invoked: [:agent_a],
               consensus_score: nil
             }
           }}
        end
      }

      assert {:timeout, result} = AgenticHandler.execute(step, context)
      assert result.partial_outputs.partial == "data"
    end

    test ":error result transitions step to failed" do
      step = %{
        id: "error-step",
        type: :agentic,
        synapse_spec: %{
          coordinator: :test,
          agents: [:agent_a],
          max_iterations: 1,
          consensus_threshold: 0.8,
          escalation_policy: :on_failure
        },
        inputs: [],
        outputs: [:result],
        timeout_ms: 60_000
      }

      context = %{
        run_id: "run-error",
        inputs: %{},
        resources: %{},
        elapsed_ms: 0,
        synapse_module: MockSynapse,
        coordinate_mock: fn _spec, _inputs, _ctx ->
          {:error, :agent_failure}
        end
      }

      assert {:error, :agent_failure} = AgenticHandler.execute(step, context)
    end

    test "timeout remaining calculated and passed" do
      step = %{
        id: "timeout-calc-step",
        type: :agentic,
        synapse_spec: %{
          coordinator: :test,
          agents: [:agent_a],
          max_iterations: 3,
          consensus_threshold: 0.8,
          escalation_policy: :on_failure
        },
        inputs: [],
        outputs: [:result],
        timeout_ms: 300_000
      }

      test_pid = self()

      context = %{
        run_id: "run-tc",
        inputs: %{},
        resources: %{},
        elapsed_ms: 50_000,
        synapse_module: MockSynapse,
        coordinate_mock: fn _spec, _inputs, ctx ->
          send(test_pid, {:timeout_remaining, ctx[:timeout_remaining_ms]})

          {:ok,
           %Synapse.DelegationResult{
             status: :success,
             outputs: %{},
             telemetry: %{
               iterations: 1,
               total_tokens: 50,
               total_cost_usd: Decimal.new("0.005"),
               agents_invoked: [:agent_a],
               consensus_score: 1.0
             }
           }}
        end
      }

      AgenticHandler.execute(step, context)

      assert_receive {:timeout_remaining, timeout_remaining}
      assert timeout_remaining == 250_000
    end
  end
end
