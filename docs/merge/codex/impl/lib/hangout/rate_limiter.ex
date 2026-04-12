defmodule Hangout.RateLimiter do
  @moduledoc "Small token-bucket limiter kept inside participant state."

  def new(rate \\ nil, burst \\ nil) do
    {tokens, window_ms} = rate || Application.get_env(:hangout, :message_rate_limit, {5, 10_000})
    burst = burst || Application.get_env(:hangout, :message_burst, 10)

    %{
      tokens: burst,
      burst: burst,
      refill_tokens: tokens,
      refill_interval_ms: window_ms,
      updated_at_ms: now_ms()
    }
  end

  def allow?(nil), do: allow?(new())

  def allow?(bucket) do
    bucket = refill(bucket)

    if bucket.tokens >= 1 do
      {true, %{bucket | tokens: bucket.tokens - 1}}
    else
      {false, bucket}
    end
  end

  defp refill(bucket) do
    now = now_ms()
    elapsed = max(now - bucket.updated_at_ms, 0)
    add = elapsed * bucket.refill_tokens / bucket.refill_interval_ms
    tokens = min(bucket.burst, bucket.tokens + add)
    %{bucket | tokens: tokens, updated_at_ms: now}
  end

  defp now_ms, do: System.monotonic_time(:millisecond)
end
