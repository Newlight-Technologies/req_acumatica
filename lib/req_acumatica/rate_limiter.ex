defmodule ReqAcumatica.RateLimiter do
  @moduledoc """
  Token bucket rate limiter for Acumatica API requests.

  Enforces a maximum number of requests per time window to stay within
  Acumatica's API rate limits. Callers block until a token is available.

  ## Usage

  Add to your supervision tree:

      children = [
        {ReqAcumatica.RateLimiter, rate: 100, window: 60_000}
      ]

  Then pass it to the client:

      ReqAcumatica.new(
        base_url: "...",
        tenant: "...",
        auth: {...},
        rate_limiter: ReqAcumatica.RateLimiter
      )

  ## Configuration

    * `:rate` — Maximum requests per window (default: 100)
    * `:window` — Window duration in milliseconds (default: 60_000 = 1 minute)
    * `:name` — GenServer name (default: `ReqAcumatica.RateLimiter`)
  """

  use GenServer

  @default_rate 100
  @default_window 60_000

  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    rate = Keyword.get(opts, :rate, @default_rate)
    window = Keyword.get(opts, :window, @default_window)
    GenServer.start_link(__MODULE__, %{rate: rate, window: window}, name: name)
  end

  @doc """
  Acquires a request token. Blocks until one is available.
  """
  @spec acquire(GenServer.server(), timeout()) :: :ok
  def acquire(server \\ __MODULE__, timeout \\ 30_000) do
    GenServer.call(server, :acquire, timeout)
  end

  @doc """
  Returns current rate limiter stats.
  """
  @spec stats(GenServer.server()) :: map()
  def stats(server \\ __MODULE__) do
    GenServer.call(server, :stats)
  end

  # -- Callbacks --

  @impl true
  def init(%{rate: rate, window: window}) do
    {:ok,
     %{
       tokens: rate,
       max_tokens: rate,
       window: window,
       waiters: :queue.new(),
       timer: schedule_refill(window)
     }}
  end

  @impl true
  def handle_call(:acquire, from, %{tokens: 0} = state) do
    waiters = :queue.in(from, state.waiters)
    {:noreply, %{state | waiters: waiters}}
  end

  def handle_call(:acquire, _from, %{tokens: tokens} = state) do
    {:reply, :ok, %{state | tokens: tokens - 1}}
  end

  def handle_call(:stats, _from, state) do
    {:reply,
     %{
       available_tokens: state.tokens,
       max_tokens: state.max_tokens,
       window_ms: state.window,
       queued_waiters: :queue.len(state.waiters)
     }, state}
  end

  @impl true
  def handle_info(:refill, state) do
    {new_tokens, new_waiters} = drain_waiters(state.max_tokens, state.waiters)

    {:noreply,
     %{state | tokens: new_tokens, waiters: new_waiters, timer: schedule_refill(state.window)}}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  defp drain_waiters(tokens, waiters) when tokens > 0 do
    case :queue.out(waiters) do
      {{:value, from}, rest} ->
        GenServer.reply(from, :ok)
        drain_waiters(tokens - 1, rest)

      {:empty, waiters} ->
        {tokens, waiters}
    end
  end

  defp drain_waiters(tokens, waiters), do: {tokens, waiters}

  defp schedule_refill(window) do
    Process.send_after(self(), :refill, window)
  end
end
