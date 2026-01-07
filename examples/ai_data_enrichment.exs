# AI Data Enrichment Pipeline
# Demonstrates using Altar.AI.Integrations.FlowStone for AI-powered data classification and enrichment
#
# This pipeline:
# 1. Loads raw customer feedback data
# 2. Uses Altar.AI.Integrations.FlowStone.classify_each for sentiment classification
# 3. Aggregates insights for reporting
#
# Usage:
#   MIX_ENV=dev mix run examples/ai_data_enrichment.exs
#
# Requirements:
#   - {:altar_ai, path: "../altar_ai"} in mix.exs
#   - (Optional) AI SDKs if you replace the Mock adapter with a real one

defmodule Examples.AIDataEnrichment do
  @moduledoc """
  AI-powered data enrichment pipeline using FlowStone and altar_ai.

  Demonstrates:
  - Using Altar.AI.Integrations.FlowStone for unified AI access
  - Using Altar.AI.Integrations.FlowStone helpers for common patterns
  - Mock adapter for local runs (swap to a real adapter in production)
  - Lineage tracking through AI transformations
  """

  alias Altar.AI.Adapters.Mock
  alias Altar.AI.Integrations.FlowStone, as: FlowAI

  def run do
    Application.put_env(:flowstone, :io_managers, %{memory: FlowStone.IO.Memory})

    ensure_oban_stopped()
    ensure_started(FlowStone.Registry, name: :enrichment_registry)
    ensure_started(FlowStone.IO.Memory, name: :enrichment_io)
    ensure_started(FlowStone.Lineage, name: :enrichment_lineage)

    # Initialize AI resource with mock adapter (replace with real adapter in production)
    {:ok, ai_resource} = FlowAI.init(adapter: Mock.new())

    # Store AI resource for assets to access
    Process.put(:ai_resource, ai_resource)

    FlowStone.register(__MODULE__.Pipeline, registry: :enrichment_registry)

    IO.puts("Starting AI Data Enrichment Pipeline...")
    IO.puts("AI capabilities: #{inspect(FlowAI.capabilities(ai_resource))}")
    IO.puts("Processing partition: batch_001\n")

    result =
      FlowStone.materialize_all(:enriched_insights,
        partition: "batch_001",
        registry: :enrichment_registry,
        io: [config: %{agent: :enrichment_io}],
        lineage_server: :enrichment_lineage,
        resource_server: nil
      )

    maybe_drain_oban()

    case result do
      {:ok, insights} ->
        IO.puts("\n=== Enriched Insights ===")
        display_insights(insights)

      :ok ->
        insights =
          FlowStone.IO.load(:enriched_insights, "batch_001", config: %{agent: :enrichment_io})

        IO.puts("\n=== Enriched Insights ===")
        display_insights(insights)

      {:error, reason} ->
        IO.puts("Pipeline failed: #{inspect(reason)}")
    end
  end

  defp display_insights(%{
         total_feedback: total,
         sentiment_distribution: dist,
         top_topics: topics,
         average_confidence: avg_conf
       }) do
    IO.puts("Total feedback analyzed: #{total}")
    IO.puts("\nSentiment Distribution:")

    Enum.each(dist, fn {sentiment, count} ->
      IO.puts("  #{sentiment}: #{count}")
    end)

    IO.puts("\nTop Topics: #{inspect(Map.keys(topics))}")
    IO.puts("Average AI Confidence: #{Float.round(avg_conf, 2)}")
  end

  defp display_insights(insights), do: IO.inspect(insights, pretty: true)

  def sentiment_counts(feedback) do
    Enum.reduce(feedback, %{positive: 0, negative: 0, neutral: 0}, fn item, acc ->
      case item[:classification] do
        classification when classification in ["positive", "negative", "neutral"] ->
          key = String.to_atom(classification)
          Map.update(acc, key, 1, &(&1 + 1))

        _ ->
          Map.update(acc, :neutral, 1, &(&1 + 1))
      end
    end)
  end

  def top_topics(feedback) do
    feedback
    |> Enum.flat_map(fn item -> item[:topics] || [] end)
    |> Enum.frequencies()
    |> Enum.sort_by(fn {_topic, count} -> -count end)
    |> Enum.take(5)
    |> Map.new()
  end

  def samples_by_sentiment(feedback) do
    feedback
    |> Enum.group_by(fn item -> item[:classification] || "neutral" end)
    |> Map.new(fn {sentiment, items} ->
      samples =
        items
        |> Enum.take(3)
        |> Enum.map(fn item -> item.text end)

      {sentiment, samples}
    end)
  end

  def average_confidence(feedback) do
    confidences =
      feedback
      |> Enum.map(&(&1[:confidence] || 0.5))
      |> Enum.filter(&is_number/1)

    case confidences do
      [] -> 0.0
      values -> Enum.sum(values) / length(values)
    end
  end

  defp ensure_started(mod, opts) do
    case Process.whereis(opts[:name]) do
      nil -> mod.start_link(opts)
      pid when is_pid(pid) -> {:ok, pid}
    end
  end

  defp maybe_drain_oban do
    if Process.whereis(Oban) do
      FlowStone.ObanHelpers.drain()
    else
      :ok
    end
  end

  defp ensure_oban_stopped do
    if Process.whereis(Oban.Registry) || Process.whereis(Oban.Config) do
      _ = Application.stop(:oban)

      Enum.each([Oban.Registry, Oban.Config], fn name ->
        case Process.whereis(name) do
          nil -> :ok
          pid -> Process.exit(pid, :kill)
        end
      end)
    end
  end

  defmodule Pipeline do
    @moduledoc """
    Asset definitions for the AI data enrichment pipeline.
    Uses Altar.AI.Integrations.FlowStone for clean AI integration.
    """
    use FlowStone.Pipeline
    alias Altar.AI.Integrations.FlowStone, as: FlowAI

    def sample_feedback do
      [
        %{id: 1, text: "Love the new features! The UI is so much better now.", customer: "alice"},
        %{id: 2, text: "App keeps crashing on startup. Very frustrating.", customer: "bob"},
        %{
          id: 3,
          text: "Decent product but pricing is too high for small teams.",
          customer: "carol"
        },
        %{id: 4, text: "Customer support was incredibly helpful and fast!", customer: "dave"},
        %{
          id: 5,
          text: "Missing basic features that competitors have had for years.",
          customer: "eve"
        }
      ]
    end

    def sentiment_labels, do: ["positive", "negative", "neutral"]
    def topic_labels, do: ["ui", "performance", "pricing", "support", "features", "bugs"]

    asset :raw_feedback do
      description("Raw customer feedback data")

      execute(fn _context, _deps ->
        # In production, this would fetch from a database or API
        {:ok, __MODULE__.sample_feedback()}
      end)
    end

    asset :classified_feedback do
      description("Feedback with AI-classified sentiment")
      depends_on([:raw_feedback])

      execute(fn _context, %{raw_feedback: feedback} ->
        ai = Process.get(:ai_resource)

        # Use Altar.AI.Integrations.FlowStone for clean classification
        FlowAI.classify_each(
          ai,
          feedback,
          & &1.text,
          __MODULE__.sentiment_labels()
        )
      end)
    end

    asset :topic_enriched_feedback do
      description("Feedback enriched with topic extraction")
      depends_on([:classified_feedback])

      execute(fn _context, %{classified_feedback: feedback} ->
        ai = Process.get(:ai_resource)

        # Enrich with topic analysis using AI generation
        {:ok, enriched} =
          FlowAI.enrich_each(
            ai,
            feedback,
            fn item ->
              """
              Analyze this feedback and return only the most relevant topics from this list: #{Enum.join(__MODULE__.topic_labels(), ", ")}
              Return as comma-separated list, max 3 topics.

              Feedback: "#{item.text}"
              """
            end
          )

        # Parse topic strings into lists
        parsed =
          Enum.map(enriched, fn item ->
            topics =
              case item[:ai_enrichment] do
                nil ->
                  []

                response when is_binary(response) ->
                  response
                  |> String.downcase()
                  |> String.split(~r/[,\s]+/, trim: true)
                  |> Enum.filter(&(&1 in __MODULE__.topic_labels()))

                _ ->
                  []
              end

            Map.put(item, :topics, topics)
          end)

        {:ok, parsed}
      end)
    end

    asset :enriched_insights do
      description("Aggregated insights from classified feedback")
      depends_on([:topic_enriched_feedback])

      execute(fn _context, %{topic_enriched_feedback: feedback} ->
        insights = %{
          total_feedback: length(feedback),
          sentiment_distribution: Examples.AIDataEnrichment.sentiment_counts(feedback),
          top_topics: Examples.AIDataEnrichment.top_topics(feedback),
          samples_by_sentiment: Examples.AIDataEnrichment.samples_by_sentiment(feedback),
          average_confidence: Examples.AIDataEnrichment.average_confidence(feedback)
        }

        {:ok, insights}
      end)
    end
  end
end

# Run the example
Examples.AIDataEnrichment.run()
