defmodule FlowStone.HTTP.Retry do
  @moduledoc """
  Retry logic for HTTP requests with exponential backoff.

  Handles transient failures with configurable retry behavior:
  - Retries on 5xx server errors
  - Retries on 429 rate limit (respects Retry-After header)
  - Retries on transport errors (timeouts, connection refused, etc.)
  - Does not retry on 4xx client errors (except 429)
  - Uses exponential backoff with optional jitter
  """

  @type config :: %{
          max_attempts: pos_integer(),
          base_delay_ms: pos_integer(),
          max_delay_ms: pos_integer(),
          jitter: boolean()
        }

  @type response :: %{
          status: integer(),
          body: term(),
          headers: map()
        }

  @doc """
  Execute function with retry on transient failures.

  The function receives the attempt number (1-indexed) and should return
  `{:ok, response}` or `{:error, reason}`.

  ## Examples

      config = %{max_attempts: 3, base_delay_ms: 1000, max_delay_ms: 30_000, jitter: true}

      Retry.with_retry(config, fn attempt ->
        make_http_request()
      end)

  """
  @spec with_retry(config(), (pos_integer() -> {:ok, response()} | {:error, term()})) ::
          {:ok, response()} | {:error, term()}
  def with_retry(config, fun) do
    do_retry(config, fun, 1, nil)
  end

  defp do_retry(config, _fun, attempt, last_error) when attempt > config.max_attempts do
    case last_error do
      nil -> {:error, :max_retries_exceeded}
      error -> error
    end
  end

  defp do_retry(config, fun, attempt, _last_error) do
    case fun.(attempt) do
      # Success - return immediately
      {:ok, %{status: status} = response} when status in 200..299 ->
        {:ok, response}

      # Rate limited - use Retry-After header if present
      {:ok, %{status: 429} = response} ->
        delay = get_retry_after(response) || calculate_delay(config, attempt)
        Process.sleep(delay)
        do_retry(config, fun, attempt + 1, {:ok, response})

      # Server error - retry with backoff
      {:ok, %{status: status} = response} when status >= 500 ->
        delay = calculate_delay(config, attempt)
        Process.sleep(delay)
        do_retry(config, fun, attempt + 1, {:ok, response})

      # Client error (4xx except 429) - don't retry
      {:ok, response} ->
        {:ok, response}

      # Transport error - retry with backoff
      {:error, {:transport_error, _} = error} ->
        delay = calculate_delay(config, attempt)
        Process.sleep(delay)
        do_retry(config, fun, attempt + 1, {:error, error})

      # Other errors - don't retry
      {:error, _} = error ->
        error
    end
  end

  defp calculate_delay(config, attempt) do
    # Exponential backoff: base * 2^(attempt-1)
    base = config.base_delay_ms * :math.pow(2, attempt - 1)
    capped = min(trunc(base), config.max_delay_ms)

    if config.jitter do
      # Add random jitter up to 50% of delay
      jitter = :rand.uniform(max(1, div(capped, 2)))
      capped + jitter
    else
      capped
    end
  end

  defp get_retry_after(%{headers: headers}) do
    headers
    |> Map.get("retry-after")
    |> parse_retry_after()
  end

  defp parse_retry_after(nil), do: nil
  defp parse_retry_after(value) when is_integer(value), do: value * 1000
  defp parse_retry_after([value | _]) when is_binary(value), do: parse_retry_after_string(value)
  defp parse_retry_after(value) when is_binary(value), do: parse_retry_after_string(value)
  defp parse_retry_after(_), do: nil

  defp parse_retry_after_string(value) do
    case Integer.parse(value) do
      {seconds, _} -> seconds * 1000
      :error -> nil
    end
  end
end
