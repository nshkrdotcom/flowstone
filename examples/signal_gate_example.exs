# Signal Gate Example - Durable External Suspension
#
# This example demonstrates FlowStone's Signal Gate feature for durable
# suspension while waiting for external signals (webhooks, callbacks).
# Unlike polling approaches, Signal Gate consumes zero resources while waiting.

Logger.configure(level: :info)

defmodule SignalGateExample do
  @moduledoc """
  Example pipeline demonstrating Signal Gate for external task integration.
  """

  use FlowStone.Pipeline

  # Input asset
  asset :documents do
    description("Documents to process")

    execute fn _ctx, _deps ->
      {:ok,
       [
         %{id: 1, content: "First document content"},
         %{id: 2, content: "Second document content"},
         %{id: 3, content: "Third document content"}
       ]}
    end
  end

  # Asset that triggers external processing and waits for callback
  asset :embedded_documents do
    description("Generate embeddings via external service")
    depends_on([:documents])

    execute fn _ctx, deps ->
      documents = deps.documents

      # In production, this would start an external task (e.g., AWS ECS, Lambda)
      # and return a signal gate to wait for completion
      task_id = "ecs-task-#{Ecto.UUID.generate()}"

      IO.puts("  Starting external embedding task: #{task_id}")
      IO.puts("  Documents to process: #{length(documents)}")

      # Signal gate configuration
      {:signal_gate,
       token: task_id,
       timeout: :timer.hours(1),
       timeout_action: :retry,
       metadata: %{document_count: length(documents)}}
    end

    # Called when external service signals completion
    on_signal(fn _ctx, payload ->
      case payload do
        %{"status" => "success", "embeddings" => embeddings} ->
          {:ok, embeddings}

        %{"status" => "failed", "error" => error} ->
          {:error, error}

        _ ->
          {:error, :invalid_payload}
      end
    end)

    # Called if signal gate times out
    on_timeout(fn ctx ->
      IO.puts("  Task #{ctx.gate.token} timed out!")
      {:error, :timeout}
    end)
  end

  # Downstream asset that uses the embeddings
  asset :similarity_index do
    description("Build similarity index from embeddings")
    depends_on([:embedded_documents])

    execute fn _ctx, deps ->
      embeddings = deps.embedded_documents

      # In production, this would build a vector index
      index = %{
        embedding_count: length(embeddings),
        dimensions: 1536,
        built_at: DateTime.utc_now()
      }

      {:ok, index}
    end
  end
end

# Run the example
IO.puts("=" |> String.duplicate(60))
IO.puts("FlowStone Signal Gate Example")
IO.puts("=" |> String.duplicate(60))

# Use existing servers from the application or start named ones
defmodule SignalGateExample.Helper do
  def ensure_started(module, name) do
    case Process.whereis(name) do
      nil ->
        {:ok, _pid} = module.start_link(name: name)
        name

      _pid ->
        name
    end
  end
end

# Register the pipeline (use existing servers or start new ones)
registry = SignalGateExample.Helper.ensure_started(FlowStone.Registry, FlowStone.Registry)
_io_store = SignalGateExample.Helper.ensure_started(FlowStone.IO.Memory, FlowStone.IO.Memory)

_mat_store =
  SignalGateExample.Helper.ensure_started(
    FlowStone.MaterializationStore,
    FlowStone.MaterializationStore
  )

_lineage = SignalGateExample.Helper.ensure_started(FlowStone.Lineage, FlowStone.Lineage)

FlowStone.register(SignalGateExample, registry: registry)

IO.puts("\nRegistered assets from SignalGateExample pipeline")

assets = FlowStone.Registry.list(server: registry)

for asset <- assets do
  gate_info =
    if asset.on_signal_fn do
      " [SIGNAL_GATE]"
    else
      ""
    end

  IO.puts("  - #{asset.name}: #{asset.description || "No description"}#{gate_info}")
end

# Demonstrate token generation
IO.puts("\n--- Signal Gate Token Demo ---")

alias FlowStone.SignalGate.Token

task_id = "ecs-task-abc123"
expires_at = DateTime.add(DateTime.utc_now(), 3600, :second)
signed_token = Token.generate(task_id, expires_at)

IO.puts("\nGenerated signed token:")
IO.puts("  Base token: #{task_id}")
IO.puts("  Signed token: #{String.slice(signed_token, 0, 60)}...")
IO.puts("  Expires at: #{expires_at}")

# Validate the token
{:ok, validated} = Token.validate(signed_token)
IO.puts("\nValidated token:")
IO.puts("  Extracted token: #{validated.token}")
IO.puts("  Expires at: #{validated.expires_at}")

# Show callback URL format
IO.puts("\n--- Callback URL ---")
callback_path = "/hooks/flowstone/signal/#{URI.encode(signed_token)}"
IO.puts("External service would POST to: https://your-api.com#{callback_path}")
IO.puts("\nPayload format:")

IO.puts("""
  {
    "status": "success",
    "embeddings": [
      {"id": 1, "vector": [0.1, 0.2, ...]},
      {"id": 2, "vector": [0.3, 0.4, ...]}
    ]
  }
""")

IO.puts("\n" <> String.duplicate("=", 60))
IO.puts("Signal Gate Example Complete!")
IO.puts(String.duplicate("=", 60))
