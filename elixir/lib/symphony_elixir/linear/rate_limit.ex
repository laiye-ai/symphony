defmodule SymphonyElixir.Linear.RateLimit do
  @moduledoc """
  Global circuit breaker for Linear API rate limiting.

  Linear reports rate limiting as HTTP 400 with `extensions.code == "RATELIMITED"`
  (not 429). Once tripped, every Linear request short-circuits until the pause
  deadline so per-issue polling cannot burn the remaining hourly quota.
  """

  @pause_key {__MODULE__, :paused_until_ms}
  # Linear's rateLimitResult.duration is the full limit window (1 hour); probe
  # at most every 10 minutes so recovery is not delayed by a stale deadline.
  @max_pause_ms 600_000
  @default_pause_ms 60_000

  @spec check() :: :ok | {:rate_limited, pos_integer()}
  def check do
    case remaining_ms() do
      0 -> :ok
      remaining -> {:rate_limited, remaining}
    end
  end

  @doc """
  Pause all Linear requests for `duration_ms`, capped at #{@max_pause_ms}ms.

  Returns the effective pause duration. Never shortens an existing pause.
  """
  @spec pause(term()) :: pos_integer()
  def pause(duration_ms) when is_integer(duration_ms) and duration_ms > 0 do
    capped = min(duration_ms, @max_pause_ms)

    if remaining_ms() < capped do
      :persistent_term.put(@pause_key, System.monotonic_time(:millisecond) + capped)
    end

    capped
  end

  def pause(_duration_ms), do: pause(@default_pause_ms)

  @spec remaining_ms() :: non_neg_integer()
  def remaining_ms do
    case :persistent_term.get(@pause_key, nil) do
      paused_until_ms when is_integer(paused_until_ms) ->
        max(0, paused_until_ms - System.monotonic_time(:millisecond))

      _ ->
        0
    end
  end

  @spec clear() :: :ok
  def clear do
    :persistent_term.erase(@pause_key)
    :ok
  end

  @spec default_pause_ms() :: pos_integer()
  def default_pause_ms, do: @default_pause_ms
end
