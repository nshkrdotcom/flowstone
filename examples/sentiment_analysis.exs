# Sentiment Analysis Pipeline with Sensor Triggers
# Demonstrates sensor-driven materialization for real-time processing using flowstone_ai
#
# This pipeline:
# 1. Uses a sensor to detect new review files
# 2. Analyzes sentiment using FlowStone.AI.Assets.classify_each
# 3. Generates alerts for negative sentiment
# 4. Tracks trends over time
#
# Usage:
#   MIX_ENV=dev mix run examples/sentiment_analysis.exs
#
# Requirements:
#   - {:flowstone_ai, path: "../flowstone_ai"} in mix.exs
#   - {:altar_ai, path: "../altar_ai"} in mix.exs
#   - At least one AI SDK installed (gemini_ex, claude_agent_sdk, or codex_sdk)

defmodule Examples.SentimentAnalysis do
  @moduledoc """
  Real-time sentiment analysis pipeline using FlowStone sensors and flowstone_ai.

  Demonstrates:
  - File arrival sensors for triggering pipelines
  - FlowStone.AI.Assets.classify_each for sentiment classification
  - Time-window partitioning for streaming data
  - Alert thresholds and notification patterns
  """

  def run do
    ensure_started(FlowStone.Registry, name: :sentiment_registry)
    ensure_started(FlowStone.IO.Memory, name: :sentiment_io)
    ensure_started(FlowStone.Lineage, name: :sentiment_lineage)

    # Initialize AI resource
    {:ok, ai_resource} = FlowStone.AI.Resource.init()
    Process.put(:ai_resource, ai_resource)

    FlowStone.register(__MODULE__.Pipeline, registry: :sentiment_registry)

    IO.puts("Starting Sentiment Analysis Pipeline...")
    IO.puts("AI capabilities: #{inspect(FlowStone.AI.Resource.capabilities(ai_resource))}")
    IO.puts("Processing time window: #{Date.utc_today()}\n")

    # Simulate sensor trigger with today's partition
    partition = Date.to_string(Date.utc_today())

    result =
      FlowStone.materialize_all(:sentiment_alerts,
        partition: partition,
        registry: :sentiment_registry,
        io: [config: %{agent: :sentiment_io}],
        lineage_server: :sentiment_lineage,
        resource_server: nil
      )

    FlowStone.ObanHelpers.drain()

    case result do
      {:ok, _} ->
        alerts = FlowStone.IO.load(:sentiment_alerts, partition, config: %{agent: :sentiment_io})
        IO.puts("\n=== Sentiment Analysis Results ===")
        display_alerts(alerts)

      {:error, reason} ->
        IO.puts("Pipeline failed: #{inspect(reason)}")
    end
  end

  defp display_alerts(%{summary: summary, alerts: alerts, trends: trends}) do
    IO.puts("\n--- Summary ---")
    IO.puts("Total reviews analyzed: #{summary.total_reviews}")
    IO.puts("Sentiment breakdown:")
    IO.puts("  Positive: #{summary.positive_count} (#{summary.positive_pct}%)")
    IO.puts("  Neutral: #{summary.neutral_count} (#{summary.neutral_pct}%)")
    IO.puts("  Negative: #{summary.negative_count} (#{summary.negative_pct}%)")
    IO.puts("Average sentiment score: #{summary.avg_score}")

    if length(alerts) > 0 do
      IO.puts("\n--- Alerts ---")

      Enum.each(alerts, fn alert ->
        IO.puts("[#{alert.severity}] #{alert.message}")
        if alert.details, do: IO.puts("  Details: #{alert.details}")
      end)
    else
      IO.puts("\n--- No alerts generated ---")
    end

    IO.puts("\n--- Trends ---")
    IO.puts("Sentiment trend: #{trends.direction}")
    IO.puts("Top issues: #{Enum.join(trends.top_issues, ", ")}")
  end

  defp display_alerts(alerts), do: IO.inspect(alerts, pretty: true)

  defp ensure_started(mod, opts) do
    case Process.whereis(opts[:name]) do
      nil -> mod.start_link(opts)
      pid when is_pid(pid) -> {:ok, pid}
    end
  end

  defmodule Pipeline do
    @moduledoc """
    Asset definitions for the sentiment analysis pipeline.
    Uses FlowStone.AI.Assets for classification.
    """
    use FlowStone.Pipeline

    # Simulated review data (in production, would come from sensor-detected files)
    @sample_reviews [
      %{
        id: "rev_001",
        text: "Absolutely love this product! Best purchase I've made this year.",
        source: "app_store",
        timestamp: ~U[2025-01-15 10:00:00Z]
      },
      %{
        id: "rev_002",
        text: "App crashes constantly. Lost all my data. Terrible experience.",
        source: "app_store",
        timestamp: ~U[2025-01-15 11:30:00Z]
      },
      %{
        id: "rev_003",
        text: "It's okay. Does what it says but nothing special.",
        source: "play_store",
        timestamp: ~U[2025-01-15 12:15:00Z]
      },
      %{
        id: "rev_004",
        text: "Customer support never responded. Very disappointed.",
        source: "trustpilot",
        timestamp: ~U[2025-01-15 14:00:00Z]
      },
      %{
        id: "rev_005",
        text: "Great features and smooth performance. Highly recommended!",
        source: "play_store",
        timestamp: ~U[2025-01-15 15:30:00Z]
      },
      %{
        id: "rev_006",
        text: "Subscription price is too high for what you get.",
        source: "app_store",
        timestamp: ~U[2025-01-15 16:45:00Z]
      },
      %{
        id: "rev_007",
        text: "The new update fixed all my issues. Thanks team!",
        source: "app_store",
        timestamp: ~U[2025-01-15 17:00:00Z]
      },
      %{
        id: "rev_008",
        text: "Buggy mess. Don't waste your money.",
        source: "trustpilot",
        timestamp: ~U[2025-01-15 18:30:00Z]
      }
    ]

    @sentiment_labels ["positive", "negative", "neutral"]

    # Alert thresholds
    # Alert if >30% negative
    @negative_alert_threshold 0.30
    # Critical if >50% negative
    @negative_critical_threshold 0.50
    @min_reviews_for_alert 5

    asset :raw_reviews do
      description("Raw review data from sensors")
      partitioned_by(:date)

      execute(fn context, _deps ->
        # In production, sensor would trigger with file path
        # and we'd load reviews from that file
        partition = context.partition
        IO.puts("Loading reviews for partition: #{partition}")

        # Simulate loading reviews for this time window
        {:ok, @sample_reviews}
      end)
    end

    asset :analyzed_reviews do
      description("Reviews with sentiment analysis via flowstone_ai")
      depends_on([:raw_reviews])

      execute(fn _context, %{raw_reviews: reviews} ->
        ai = Process.get(:ai_resource)

        # Use FlowStone.AI.Assets for classification
        {:ok, classified} =
          FlowStone.AI.Assets.classify_each(
            ai,
            reviews,
            & &1.text,
            @sentiment_labels
          )

        # Map classification results to expected format and extract topics
        analyzed =
          Enum.map(classified, fn review ->
            sentiment = review[:classification] || "neutral"
            confidence = review[:confidence] || 0.5

            # Convert sentiment to score
            score =
              case sentiment do
                "positive" -> confidence
                "negative" -> -confidence
                _ -> 0.0
              end

            # Extract topics using heuristics (in production, could use AI)
            topics = extract_topics(review.text)

            Map.merge(review, %{
              sentiment: sentiment,
              sentiment_score: Float.round(score, 2),
              topics: topics
            })
          end)

        {:ok, analyzed}
      end)
    end

    asset :sentiment_summary do
      description("Aggregated sentiment metrics")
      depends_on([:analyzed_reviews])

      execute(fn context, %{analyzed_reviews: reviews} ->
        summary = calculate_summary(reviews, context.partition)
        {:ok, summary}
      end)
    end

    asset :sentiment_alerts do
      description("Generated alerts based on sentiment thresholds")
      depends_on([:sentiment_summary, :analyzed_reviews])

      execute(fn _context, %{sentiment_summary: summary, analyzed_reviews: reviews} ->
        alerts = generate_alerts(summary, reviews)
        trends = calculate_trends(reviews)

        {:ok,
         %{
           summary: summary,
           alerts: alerts,
           trends: trends,
           generated_at: DateTime.utc_now()
         }}
      end)
    end

    # Topic extraction using heuristics
    defp extract_topics(text) do
      text_lower = String.downcase(text)

      topic_keywords = %{
        "performance" => ~w(crash crashes slow fast smooth performance),
        "pricing" => ~w(price cost subscription expensive cheap money waste),
        "support" => ~w(support customer service help response responded),
        "features" => ~w(feature features function missing update),
        "bugs" => ~w(bug bugs buggy broken fix fixed issue issues)
      }

      topic_keywords
      |> Enum.filter(fn {_topic, keywords} ->
        Enum.any?(keywords, &String.contains?(text_lower, &1))
      end)
      |> Enum.map(fn {topic, _} -> topic end)
    end

    # Summary calculation
    defp calculate_summary(reviews, partition) do
      total = length(reviews)

      by_sentiment = Enum.group_by(reviews, & &1.sentiment)
      positive_count = length(Map.get(by_sentiment, "positive", []))
      negative_count = length(Map.get(by_sentiment, "negative", []))
      neutral_count = length(Map.get(by_sentiment, "neutral", []))

      avg_score =
        if total > 0 do
          reviews
          |> Enum.map(& &1.sentiment_score)
          |> Enum.sum()
          |> Kernel./(total)
          |> Float.round(2)
        else
          0.0
        end

      %{
        partition: partition,
        total_reviews: total,
        positive_count: positive_count,
        negative_count: negative_count,
        neutral_count: neutral_count,
        positive_pct: percentage(positive_count, total),
        negative_pct: percentage(negative_count, total),
        neutral_pct: percentage(neutral_count, total),
        avg_score: avg_score,
        by_source: group_by_source(reviews)
      }
    end

    defp percentage(count, total) when total > 0, do: round(count / total * 100)
    defp percentage(_, _), do: 0

    defp group_by_source(reviews) do
      reviews
      |> Enum.group_by(& &1.source)
      |> Enum.map(fn {source, items} ->
        avg = items |> Enum.map(& &1.sentiment_score) |> Enum.sum() |> Kernel./(length(items))
        {source, %{count: length(items), avg_score: Float.round(avg, 2)}}
      end)
      |> Map.new()
    end

    # Alert generation
    defp generate_alerts(summary, reviews) do
      alerts = []

      # Check negative ratio
      negative_ratio = summary.negative_count / max(summary.total_reviews, 1)

      alerts =
        cond do
          summary.total_reviews < @min_reviews_for_alert ->
            alerts

          negative_ratio >= @negative_critical_threshold ->
            [
              %{
                severity: :critical,
                type: :high_negative_sentiment,
                message: "Critical: #{summary.negative_pct}% negative sentiment detected",
                details:
                  "#{summary.negative_count} of #{summary.total_reviews} reviews are negative"
              }
              | alerts
            ]

          negative_ratio >= @negative_alert_threshold ->
            [
              %{
                severity: :warning,
                type: :elevated_negative_sentiment,
                message: "Warning: #{summary.negative_pct}% negative sentiment",
                details: nil
              }
              | alerts
            ]

          true ->
            alerts
        end

      # Check for specific issue spikes
      topic_counts =
        reviews
        |> Enum.flat_map(& &1.topics)
        |> Enum.frequencies()

      alerts =
        Enum.reduce(topic_counts, alerts, fn {topic, count}, acc ->
          if count >= 3 and topic in ["bugs", "performance"] do
            [
              %{
                severity: :warning,
                type: :topic_spike,
                message: "Spike in '#{topic}' mentions: #{count} reviews",
                details: nil
              }
              | acc
            ]
          else
            acc
          end
        end)

      Enum.reverse(alerts)
    end

    # Trend calculation
    defp calculate_trends(reviews) do
      # Sort by timestamp
      sorted = Enum.sort_by(reviews, & &1.timestamp, DateTime)

      # Calculate trend direction
      direction =
        if length(sorted) >= 4 do
          first_half = Enum.take(sorted, div(length(sorted), 2))
          second_half = Enum.drop(sorted, div(length(sorted), 2))

          first_avg = avg_sentiment(first_half)
          second_avg = avg_sentiment(second_half)

          cond do
            second_avg - first_avg > 0.2 -> "improving"
            first_avg - second_avg > 0.2 -> "declining"
            true -> "stable"
          end
        else
          "insufficient_data"
        end

      # Identify top issues
      top_issues =
        reviews
        |> Enum.filter(&(&1.sentiment == "negative"))
        |> Enum.flat_map(& &1.topics)
        |> Enum.frequencies()
        |> Enum.sort_by(fn {_, count} -> -count end)
        |> Enum.take(3)
        |> Enum.map(fn {topic, _} -> topic end)

      %{
        direction: direction,
        top_issues: top_issues
      }
    end

    defp avg_sentiment(reviews) when length(reviews) > 0 do
      reviews
      |> Enum.map(& &1.sentiment_score)
      |> Enum.sum()
      |> Kernel./(length(reviews))
    end

    defp avg_sentiment(_), do: 0.0
  end

  # Sensor configuration example (would be used in production)
  defmodule SensorConfig do
    @moduledoc """
    Example sensor configuration for file-triggered processing.

    In production, you would configure this to watch for new review files:

        FlowStone.Sensor.configure(:review_file_sensor,
          type: :s3_file_arrival,
          bucket: "reviews-bucket",
          prefix: "incoming/",
          pattern: "*.json",
          on_arrival: fn file_key ->
            partition = extract_date_from_key(file_key)
            FlowStone.materialize(:sentiment_alerts, partition: partition)
          end
        )
    """

    def example_sensor_config do
      %{
        type: :s3_file_arrival,
        bucket: "reviews-bucket",
        prefix: "incoming/reviews/",
        pattern: ~r/reviews_\d{4}-\d{2}-\d{2}\.json$/,
        poll_interval: :timer.seconds(60),
        on_arrival: &trigger_pipeline/1
      }
    end

    defp trigger_pipeline(file_key) do
      # Extract date partition from filename
      case Regex.run(~r/reviews_(\d{4}-\d{2}-\d{2})\.json$/, file_key) do
        [_, date_str] ->
          FlowStone.materialize_async(:sentiment_alerts, partition: date_str)

        nil ->
          {:error, :invalid_filename}
      end
    end
  end
end

# Run the example
Examples.SentimentAnalysis.run()
