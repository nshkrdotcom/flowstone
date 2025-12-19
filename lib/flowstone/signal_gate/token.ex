defmodule FlowStone.SignalGate.Token do
  @moduledoc """
  Secure token generation and validation for Signal Gates.

  Tokens are signed using HMAC-SHA256 to prevent forgery.
  Format: `base_token.timestamp.signature`
  """

  @doc """
  Generate a signed token that can be used in callbacks.

  ## Examples

      iex> token = FlowStone.SignalGate.Token.generate("task-123", DateTime.add(DateTime.utc_now(), 3600, :second))
      "task-123.1703001600.abc123..."
  """
  @spec generate(String.t(), DateTime.t()) :: String.t()
  def generate(base_token, expires_at) do
    timestamp = DateTime.to_unix(expires_at)
    payload = "#{base_token}.#{timestamp}"
    signature = sign(payload)
    "#{payload}.#{signature}"
  end

  @doc """
  Validate and parse a signed token.

  Returns the base token and expiration time if valid.

  ## Examples

      iex> FlowStone.SignalGate.Token.validate("task-123.1703001600.valid_sig")
      {:ok, %{token: "task-123", expires_at: ~U[2023-12-19 12:00:00Z]}}

      iex> FlowStone.SignalGate.Token.validate("invalid")
      {:error, :malformed_token}
  """
  @spec validate(String.t()) ::
          {:ok, %{token: String.t(), expires_at: DateTime.t()}} | {:error, term()}
  def validate(signed_token) do
    case String.split(signed_token, ".") do
      [base_token, timestamp_str, signature] ->
        payload = "#{base_token}.#{timestamp_str}"
        expected_sig = sign(payload)

        cond do
          not secure_compare(signature, expected_sig) ->
            {:error, :invalid_signature}

          expired?(timestamp_str) ->
            {:error, :expired}

          true ->
            {:ok,
             %{
               token: base_token,
               expires_at: DateTime.from_unix!(String.to_integer(timestamp_str))
             }}
        end

      _ ->
        {:error, :malformed_token}
    end
  end

  @doc """
  Hash token for database lookup.
  Uses SHA-256 truncated to 32 chars.
  """
  @spec hash(String.t()) :: String.t()
  def hash(token) do
    :crypto.hash(:sha256, token)
    |> Base.encode16(case: :lower)
    |> binary_part(0, 32)
  end

  @doc """
  Generate a random base token.
  """
  @spec generate_base_token() :: String.t()
  def generate_base_token do
    :crypto.strong_rand_bytes(16)
    |> Base.url_encode64(padding: false)
  end

  defp sign(payload) do
    secret = get_secret()

    :crypto.mac(:hmac, :sha256, secret, payload)
    |> Base.url_encode64(padding: false)
  end

  defp secure_compare(a, b) do
    # Use constant-time comparison to prevent timing attacks
    if byte_size(a) == byte_size(b) do
      Plug.Crypto.secure_compare(a, b)
    else
      false
    end
  end

  defp expired?(timestamp_str) do
    timestamp = String.to_integer(timestamp_str)
    DateTime.to_unix(DateTime.utc_now()) > timestamp
  end

  defp get_secret do
    case Application.get_env(:flowstone, :signal_gate_secret) do
      nil ->
        # Fallback to a derived secret if not configured
        # In production, this should be explicitly set
        :crypto.hash(:sha256, "flowstone-signal-gate-default-secret")
        |> Base.encode64()

      secret ->
        secret
    end
  end
end
