# Scatter Example - Dynamic Fan-Out
#
# This example demonstrates FlowStone's Scatter feature for dynamic parallel execution.
# Scatter allows an asset to fan out into multiple parallel instances based on
# runtime-discovered data, then reconverge for downstream assets.

Logger.configure(level: :info)

defmodule ScatterExample do
  @moduledoc """
  Example pipeline demonstrating Scatter for web scraping.
  """

  use FlowStone.Pipeline

  # Source asset that provides URLs to scrape
  asset :source_urls do
    description("List of URLs to scrape")

    execute fn _ctx, _deps ->
      urls = [
        "https://example.com/page1",
        "https://example.com/page2",
        "https://example.com/page3",
        "https://example.com/page4",
        "https://example.com/page5"
      ]

      {:ok, urls}
    end
  end

  # Scattered asset - each URL becomes a parallel instance
  asset :scraped_page do
    description("Scrape individual pages in parallel")
    depends_on([:source_urls])

    # Scatter function: transforms dependency data into scatter keys
    scatter(fn %{source_urls: urls} ->
      Enum.map(urls, &%{url: &1})
    end)

    # Scatter options control parallel execution
    scatter_options do
      max_concurrent(3)
      rate_limit({2, :second})
      failure_threshold(0.2)
      failure_mode(:partial)
    end

    # Execute function runs for each scatter key
    execute fn ctx, _deps ->
      url = ctx.scatter_key["url"]

      # Simulate scraping with random delay
      Process.sleep(Enum.random(100..500))

      {:ok,
       %{
         url: url,
         title: "Page Title for #{url}",
         content: "Content from #{url}",
         scraped_at: DateTime.utc_now()
       }}
    end

    # Gather function aggregates results for downstream
    gather(fn results ->
      results
      |> Map.values()
      |> Enum.sort_by(& &1.scraped_at)
    end)
  end

  # Downstream asset that consumes gathered results
  asset :aggregated_content do
    description("Aggregate scraped content")
    depends_on([:scraped_page])

    execute fn _ctx, deps ->
      pages = deps.scraped_page

      summary = %{
        total_pages: length(pages),
        titles: Enum.map(pages, & &1.title),
        scraped_at: DateTime.utc_now()
      }

      {:ok, summary}
    end
  end
end

# Run the example
IO.puts("=" |> String.duplicate(60))
IO.puts("FlowStone Scatter Example")
IO.puts("=" |> String.duplicate(60))

# Use existing servers from the application or start named ones
defmodule ScatterExample.Helper do
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
registry = ScatterExample.Helper.ensure_started(FlowStone.Registry, FlowStone.Registry)
io_store = ScatterExample.Helper.ensure_started(FlowStone.IO.Memory, FlowStone.IO.Memory)

mat_store =
  ScatterExample.Helper.ensure_started(
    FlowStone.MaterializationStore,
    FlowStone.MaterializationStore
  )

lineage = ScatterExample.Helper.ensure_started(FlowStone.Lineage, FlowStone.Lineage)

FlowStone.register(ScatterExample, registry: registry)

IO.puts("\nRegistered assets from ScatterExample pipeline")

# List assets
assets = FlowStone.Registry.list(server: registry)

for asset <- assets do
  scatter_info =
    if asset.scatter_fn do
      " [SCATTER: max_concurrent=#{asset.scatter_options[:max_concurrent] || :unlimited}]"
    else
      ""
    end

  IO.puts("  - #{asset.name}: #{asset.description || "No description"}#{scatter_info}")
end

# Materialize the source URLs
IO.puts("\nMaterializing :source_urls...")

{:ok, urls} =
  FlowStone.Executor.materialize(:source_urls,
    partition: Date.utc_today(),
    registry: registry,
    io: [manager: FlowStone.IO.Memory, config: %{server: io_store}],
    materialization_store: mat_store,
    lineage_server: lineage,
    use_repo: false
  )

IO.puts("  Source URLs: #{inspect(urls)}")

# Note: Full scatter execution requires Oban integration
# This example shows the DSL and structure
IO.puts("\nScatter pipeline structure defined successfully!")
IO.puts("In production, scatter jobs would be enqueued to Oban for parallel execution.")

IO.puts("\n" <> String.duplicate("=", 60))
IO.puts("Scatter Example Complete!")
IO.puts(String.duplicate("=", 60))
