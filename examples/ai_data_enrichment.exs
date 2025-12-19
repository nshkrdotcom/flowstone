# AI Data Enrichment Pipeline
# Demonstrates using flowstone_ai for AI-powered data classification and enrichment
#
# This pipeline:
# 1. Loads raw customer feedback data
# 2. Uses FlowStone.AI.Assets.classify_each for sentiment classification
# 3. Aggregates insights for reporting
#
# Usage:
#   MIX_ENV=dev mix run examples/ai_data_enrichment.exs
#
# Requirements:
#   - {:flowstone_ai, path: "../flowstone_ai"} in mix.exs
#   - {:altar_ai, path: "../altar_ai"} in mix.exs (dependency of flowstone_ai)
#   - At least one AI SDK installed (gemini_ex, claude_agent_sdk, or codex_sdk)

defmodule Examples.AIDataEnrichment do
  @moduledoc """
  AI-powered data enrichment pipeline using FlowStone and flowstone_ai.

  Demonstrates:
  - Using FlowStone.AI.Resource for unified AI access
  - Using FlowStone.AI.Assets DSL helpers for common patterns
  - Automatic provider fallback via altar_ai Composite adapter
  - Lineage tracking through AI transformations
  """

  def run do
    ensure_started(FlowStone.Registry, name: :enrichment_registry)
    ensure_started(FlowStone.IO.Memory, name: :enrichment_io)
    ensure_started(FlowStone.Lineage, name: :enrichment_lineage)

    # Initialize AI resource with composite adapter (automatic fallback)
    {:ok, ai_resource} = FlowStone.AI.Resource.init()

    # Store AI resource for assets to access
    Process.put(:ai_resource, ai_resource)

    FlowStone.register(__MODULE__.Pipeline, registry: :enrichment_registry)

    IO.puts("Starting AI Data Enrichment Pipeline...")
    IO.puts("AI capabilities: #{inspect(FlowStone.AI.Resource.capabilities(ai_resource))}")
    IO.puts("Processing partition: batch_001\n")

    result =
      FlowStone.materialize_all(:enriched_insights,
        partition: "batch_001",
        registry: :enrichment_registry,
        io: [config: %{agent: :enrichment_io}],
        lineage_server: :enrichment_lineage,
        resource_server: nil
      )

    FlowStone.ObanHelpers.drain()

    case result do
      {:ok, _} ->
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

  defp ensure_started(mod, opts) do
    case Process.whereis(opts[:name]) do
      nil -> mod.start_link(opts)
      pid when is_pid(pid) -> {:ok, pid}
    end
  end

  defmodule Pipeline do
    @moduledoc """
    Asset definitions for the AI data enrichment pipeline.
    Uses FlowStone.AI.Assets for clean AI integration.
    """
    use FlowStone.Pipeline

    @sample_feedback [
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

    @sentiment_labels ["positive", "negative", "neutral"]
    @topic_labels ["ui", "performance", "pricing", "support", "features", "bugs"]

    asset :raw_feedback do
      description("Raw customer feedback data")

      execute(fn _context, _deps ->
        # In production, this would fetch from a database or API
        {:ok, @sample_feedback}
      end)
    end

    asset :classified_feedback do
      description("Feedback with AI-classified sentiment")
      depends_on([:raw_feedback])

      execute(fn _context, %{raw_feedback: feedback} ->
        ai = Process.get(:ai_resource)

        # Use FlowStone.AI.Assets for clean classification
        FlowStone.AI.Assets.classify_each(
          ai,
          feedback,
          & &1.text,
          @sentiment_labels
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
          FlowStone.AI.Assets.enrich_each(
            ai,
            feedback,
            fn item ->
              """
              Analyze this feedback and return only the most relevant topics from this list: #{Enum.join(@topic_labels, ", ")}
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
                  |> Enum.filter(&(&1 in @topic_labels))

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
          sentiment_distribution: sentiment_counts(feedback),
          top_topics: top_topics(feedback),
          samples_by_sentiment: samples_by_sentiment(feedback),
          average_confidence: average_confidence(feedback)
        }

        {:ok, insights}
      end)
    end

    # Aggregation helpers
    defp sentiment_counts(feedback) do
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

    defp top_topics(feedback) do
      feedback
      |> Enum.flat_map(fn item -> item[:topics] || [] end)
      |> Enum.frequencies()
      |> Enum.sort_by(fn {_topic, count} -> -count end)
      |> Enum.take(5)
      |> Map.new()
    end

    defp samples_by_sentiment(feedback) do
      feedback
      |> Enum.group_by(fn item -> item[:classification] || "neutral" end)
      |> Map.new(fn {sentiment, items} ->
        {sentiment, Enum.map(items, & &1.text) |> Enum.take(2)}
      end)
    end

    defp average_confidence(feedback) do
      confidences =
        feedback
        |> Enum.map(fn item -> item[:confidence] || 0.5 end)

      if Enum.empty?(confidences) do
        0.0
      else
        Enum.sum(confidences) / length(confidences)
      end
    end
  end
end

# Run the example
Examples.AIDataEnrichment.run()
