defmodule Hangout.RateLimiter do
  @moduledoc """
  Token bucket rate limiter. In-memory, per-user, ephemeral.
  """

  defstruct [
    :max_tokens,
    :refill_rate,
    :refill_interval_ms,
    :tokens,
    :last_refill
  ]

  @type t :: %__MODULE__{
          max_tokens: non_neg_integer(),
          refill_rate: non_neg_integer(),
          refill_interval_ms: non_neg_integer(),
          tokens: float(),
          last_refill: integer()
        }

  @doc """
  Create a new rate limiter.

  - `max_tokens`: burst capacity
  - `refill_rate`: tokens added per interval
  - `refill_interval_ms`: interval in milliseconds
  """
  def new(max_tokens \\ nil, refill_rate \\ nil, refill_interval_ms \\ nil) do
    {default_rate, default_interval} = Application.get_env(:hangout, :message_rate_limit, {5, 10_000})
    default_burst = Application.get_env(:hangout, :message_burst, 10)

    max_tokens = max_tokens || default_burst
    refill_rate = refill_rate || default_rate
    refill_interval_ms = refill_interval_ms || default_interval

    %__MODULE__{
      max_tokens: max_tokens,
      refill_rate: refill_rate,
      refill_interval_ms: refill_interval_ms,
      tokens: max_tokens * 1.0,
      last_refill: System.monotonic_time(:millisecond)
    }
  end

  @doc """
  Try to consume one token. Returns `{:ok, updated_limiter}` or `{:error, :rate_limited}`.
  """
  def check(%__MODULE__{} = limiter) do
    limiter = refill(limiter)

    if limiter.tokens >= 1.0 do
      {:ok, %{limiter | tokens: limiter.tokens - 1.0}}
    else
      {:error, :rate_limited}
    end
  end

  defp refill(%__MODULE__{} = limiter) do
    now = System.monotonic_time(:millisecond)
    elapsed = max(now - limiter.last_refill, 0)

    if elapsed >= limiter.refill_interval_ms do
      intervals = div(elapsed, limiter.refill_interval_ms)
      added = intervals * limiter.refill_rate
      new_tokens = min(limiter.max_tokens * 1.0, limiter.tokens + added)

      %{limiter | tokens: new_tokens, last_refill: limiter.last_refill + intervals * limiter.refill_interval_ms}
    else
      limiter
    end
  end
end
