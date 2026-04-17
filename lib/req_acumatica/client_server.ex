defmodule ReqAcumatica.ClientServer do
  @moduledoc """
  GenServer that maintains a long-lived `ReqAcumatica` client with automatic
  OAuth2 token management.

  Holds a single shared client whose OAuth2 token is automatically refreshed
  before expiry. This avoids re-authenticating on every request and provides
  a single point of configuration for the Acumatica connection.

  ## Configuration

  Configure via application environment:

      config :req_acumatica,
        base_url: "https://example.acumatica.com",
        tenant: "MAIN",
        auth: {:oauth2, "client-id", "client-secret", "api-user", "password"},
        scope: "api offline_access"

  Or pass options directly when starting:

      ReqAcumatica.ClientServer.start_link(
        base_url: "https://example.acumatica.com",
        tenant: "MAIN",
        auth: {:oauth2, "client-id", "client-secret", "api-user", "password"}
      )

  ## Usage

      # Get the cached client
      {:ok, client} = ReqAcumatica.ClientServer.get_client()

      # Use it for queries
      {:ok, result} = ReqAcumatica.query(client, "My Inquiry")

  ## Supervision

  Add to your application supervision tree:

      children = [
        ReqAcumatica.ClientServer
        # or with explicit config:
        # {ReqAcumatica.ClientServer, base_url: "...", tenant: "...", auth: {...}}
      ]

  ## Multiple Instances

  If you need multiple clients (e.g., different tenants), use the `:name` option:

      {ReqAcumatica.ClientServer, name: :acumatica_tenant_a, tenant: "TENANT A", ...}
      {ReqAcumatica.ClientServer, name: :acumatica_tenant_b, tenant: "TENANT B", ...}

      ReqAcumatica.ClientServer.get_client(:acumatica_tenant_a)
  """

  use GenServer

  require Logger

  @default_name __MODULE__
  @refresh_buffer_seconds 120

  # -- Public API --

  @doc """
  Starts the ClientServer.

  ## Options

  Accepts all options from `ReqAcumatica.new/1`, plus:

    * `:name` — GenServer name (default: `ReqAcumatica.ClientServer`)

  If no options are provided, reads from `Application.get_env(:req_acumatica)`.
  """
  def start_link(opts \\ []) do
    {name, opts} = Keyword.pop(opts, :name, @default_name)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc """
  Returns the current cached client.

  If the token has expired or is about to expire, it will be refreshed
  before returning.
  """
  @spec get_client(GenServer.server()) :: {:ok, Req.Request.t()} | {:error, term()}
  def get_client(server \\ @default_name) do
    GenServer.call(server, :get_client)
  end

  @doc """
  Forces a token refresh and returns the new client.
  """
  @spec refresh(GenServer.server()) :: {:ok, Req.Request.t()} | {:error, term()}
  def refresh(server \\ @default_name) do
    GenServer.call(server, :refresh)
  end

  @doc """
  Returns the current token info without triggering a refresh.
  """
  @spec token_info(GenServer.server()) :: {:ok, map()} | {:error, :no_token}
  def token_info(server \\ @default_name) do
    GenServer.call(server, :token_info)
  end

  # -- GenServer Callbacks --

  @impl true
  def init(opts) do
    opts = resolve_config(opts)

    case build_client(opts) do
      {:error, reason} ->
        Logger.error("[ReqAcumatica.ClientServer] Failed to initialize: #{inspect(reason)}")
        {:ok, %{client: nil, opts: opts, error: reason}, {:continue, :retry_init}}

      client ->
        schedule_refresh(client)
        {:ok, %{client: client, opts: opts, error: nil}}
    end
  end

  @impl true
  def handle_continue(:retry_init, %{opts: opts} = state) do
    Process.sleep(5_000)

    case build_client(opts) do
      {:error, reason} ->
        Logger.warning(
          "[ReqAcumatica.ClientServer] Retry failed: #{inspect(reason)}, will retry on next request"
        )

        {:noreply, %{state | client: nil, error: reason}}

      client ->
        Logger.info("[ReqAcumatica.ClientServer] Successfully connected on retry")
        schedule_refresh(client)
        {:noreply, %{state | client: client, error: nil}}
    end
  end

  @impl true
  def handle_call(:get_client, _from, %{client: nil, opts: opts} = state) do
    case build_client(opts) do
      {:error, reason} ->
        {:reply, {:error, reason}, %{state | error: reason}}

      client ->
        schedule_refresh(client)
        {:reply, {:ok, client}, %{state | client: client, error: nil}}
    end
  end

  def handle_call(:get_client, _from, %{client: client} = state) do
    {:reply, {:ok, client}, state}
  end

  def handle_call(:refresh, _from, %{opts: opts} = state) do
    case build_client(opts) do
      {:error, reason} ->
        {:reply, {:error, reason}, %{state | error: reason}}

      client ->
        schedule_refresh(client)
        {:reply, {:ok, client}, %{state | client: client, error: nil}}
    end
  end

  def handle_call(:token_info, _from, %{client: client} = state) when not is_nil(client) do
    case client.private[:acumatica_auth] do
      {:oauth2_token, token} ->
        {:reply,
         {:ok,
          %{
            expires_at: token.expires_at,
            expires_in: token.expires_in,
            token_type: token.token_type,
            has_refresh_token: not is_nil(token.refresh_token)
          }}, state}

      _ ->
        {:reply, {:ok, %{type: :static}}, state}
    end
  end

  def handle_call(:token_info, _from, state) do
    {:reply, {:error, :no_token}, state}
  end

  @impl true
  def handle_info(:refresh_token, %{opts: opts} = state) do
    case build_client(opts) do
      {:error, reason} ->
        Logger.warning("[ReqAcumatica.ClientServer] Token refresh failed: #{inspect(reason)}")
        Process.send_after(self(), :refresh_token, 30_000)
        {:noreply, %{state | error: reason}}

      client ->
        Logger.debug("[ReqAcumatica.ClientServer] Token refreshed successfully")
        schedule_refresh(client)
        {:noreply, %{state | client: client, error: nil}}
    end
  end

  def handle_info(_msg, state), do: {:noreply, state}

  # -- Private --

  defp resolve_config(opts) do
    if opts == [] do
      Application.get_all_env(:req_acumatica)
      |> Keyword.drop([:included_applications])
    else
      opts
    end
  end

  defp build_client(opts) do
    ReqAcumatica.new(opts)
  end

  defp schedule_refresh(client) do
    case client.private[:acumatica_auth] do
      {:oauth2_token, %{expires_at: %DateTime{} = expires_at}} ->
        seconds_until_expiry =
          DateTime.diff(expires_at, DateTime.utc_now(), :second)

        refresh_in = max((seconds_until_expiry - @refresh_buffer_seconds) * 1000, 5_000)
        Process.send_after(self(), :refresh_token, refresh_in)

      _ ->
        :ok
    end
  end
end
