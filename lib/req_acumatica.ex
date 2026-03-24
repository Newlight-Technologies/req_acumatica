defmodule ReqAcumatica do
  @moduledoc """
  Req plugin for the [Acumatica](https://www.acumatica.com/) API.

  Provides authenticated access to both the **OData API** (Generic Inquiries)
  and the **Contract-Based REST API** (entity CRUD + actions).

  ## Plugin pattern

  Following the [Dashbit Req SDK pattern](https://dashbit.co/blog/sdks-with-req-s3),
  `ReqAcumatica` is a Req plugin. Use `attach/2` to augment any Req request,
  or `new/1` as a convenience:

      # Plugin style
      req = Req.new() |> ReqAcumatica.attach(base_url: "...", tenant: "...", auth: {...})

      # Convenience
      req = ReqAcumatica.new(base_url: "...", tenant: "...", auth: {...})

  Then use the high-level modules for operations:

      # OData Generic Inquiries (read-only)
      {:ok, result} = ReqAcumatica.OData.query(req, "Sales Orders and Quotes", top: 25)

      # REST API (full CRUD)
      {:ok, order} = ReqAcumatica.REST.get(req, "SalesOrder", "SO-001234")
      {:ok, created} = ReqAcumatica.REST.create(req, "SalesOrder", %{...})

  ## Authentication

  Three auth methods are supported:

  - `{:basic, username, password}` — Basic Auth header
  - `{:bearer, token}` — Pre-obtained OAuth2 Bearer token
  - `{:oauth2, client_id, client_secret, username, password}` — Automatic token
    acquisition and refresh via Acumatica Connected Applications (SM303010)
  """

  @type auth ::
          {:basic, username :: String.t(), password :: String.t()}
          | {:bearer, token :: String.t()}
          | {:session, username :: String.t(), password :: String.t(), company :: String.t()}
          | {:session_token, ReqAcumatica.Session.t()}
          | {:oauth2, client_id :: String.t(), client_secret :: String.t(),
             username :: String.t(), password :: String.t()}
          | {:oauth2_token, ReqAcumatica.Auth.t()}

  @doc """
  Attaches the Acumatica plugin to a `Req.Request`.

  This is the core plugin entry point. It configures authentication,
  stores connection metadata in private fields, and attaches request
  steps for automatic OAuth2 token refresh.

  ## Options

    * `:base_url` (required) — The Acumatica instance URL (e.g. `"https://mycompany.acumatica.com"`)
    * `:tenant` (required) — The tenant/company name (e.g. `"NEWLIGHT LIVE"`)
    * `:auth` (required) — Authentication credentials (see module docs)
    * `:scope` — OAuth2 scope (default: `"api offline_access"`)
    * `:api_version` — REST API contract version (default: `"24.200.001"`)

  ## Examples

      req = Req.new(retry: :transient)
            |> ReqAcumatica.attach(
              base_url: "https://newlight.acumatica.com",
              tenant: "NEWLIGHT LIVE",
              auth: {:basic, "apiuser", "secret"}
            )
  """
  @spec attach(Req.Request.t(), keyword()) :: Req.Request.t() | {:error, term()}
  def attach(req, opts) do
    base_url = Keyword.fetch!(opts, :base_url) |> String.trim_trailing("/")
    tenant = Keyword.fetch!(opts, :tenant)
    auth = Keyword.fetch!(opts, :auth)
    api_version = Keyword.get(opts, :api_version, "24.200.001")

    case resolve_auth(auth, base_url, tenant, opts) do
      {:ok, auth_headers, resolved_auth} ->
        req
        |> Req.merge(headers: [{"accept", "application/json"} | auth_headers])
        |> Req.Request.put_private(:acumatica_base_url, base_url)
        |> Req.Request.put_private(:acumatica_tenant, tenant)
        |> Req.Request.put_private(:acumatica_auth, resolved_auth)
        |> Req.Request.put_private(:acumatica_api_version, api_version)
        |> Req.Request.put_private(:acumatica_oauth2_opts, oauth2_private_opts(auth, opts))
        |> maybe_attach_token_refresh(resolved_auth)

      {:error, _} = error ->
        error
    end
  end

  @doc """
  Creates a new Acumatica client. Convenience for `Req.new() |> attach(opts)`.

  Accepts all options from `attach/2` plus any `Req.new/1` options via `:req_options`.

  ## Examples

      req = ReqAcumatica.new(
        base_url: "https://newlight.acumatica.com",
        tenant: "NEWLIGHT LIVE",
        auth: {:oauth2, "client-id", "client-secret", "apiuser", "password"}
      )
  """
  @spec new(keyword()) :: Req.Request.t() | {:error, term()}
  def new(opts) do
    {req_options, attach_opts} = Keyword.pop(opts, :req_options, [])

    req_options
    |> Req.new()
    |> attach(attach_opts)
  end

  @doc """
  Makes a request using the configured client. Delegates to `Req.request/2`.

  Accepts any `Req.request/2` option.

  ## Examples

      {:ok, resp} = ReqAcumatica.request(req, url: "/entity/Default/24.200.001/SalesOrder")
  """
  @spec request(Req.Request.t(), keyword()) :: {:ok, Req.Response.t()} | {:error, term()}
  def request(req, opts \\ []) do
    Req.request(req, opts)
  end

  @doc """
  Like `request/2` but raises on error.
  """
  @spec request!(Req.Request.t(), keyword()) :: Req.Response.t()
  def request!(req, opts \\ []) do
    Req.request!(req, opts)
  end

  # -- URL Builders (used by OData and REST modules) --

  @doc false
  def odata_url(req, path \\ "") do
    base = req.private[:acumatica_base_url]
    tenant = req.private[:acumatica_tenant]
    encoded_tenant = URI.encode(tenant)
    "#{base}/odata/#{encoded_tenant}/#{path}"
  end

  @doc false
  def rest_url(req, path \\ "") do
    base = req.private[:acumatica_base_url]
    version = req.private[:acumatica_api_version]
    "#{base}/entity/Default/#{version}/#{path}"
  end

  # -- Private: Auth Resolution --

  defp resolve_auth({:basic, username, password}, _base_url, _tenant, _opts) do
    encoded = Base.encode64("#{username}:#{password}")
    {:ok, [{"authorization", "Basic #{encoded}"}], {:basic, username, password}}
  end

  defp resolve_auth({:bearer, token}, _base_url, _tenant, _opts) do
    {:ok, [{"authorization", "Bearer #{token}"}], {:bearer, token}}
  end

  defp resolve_auth(
         {:oauth2, client_id, client_secret, username, password},
         base_url,
         tenant,
         opts
       ) do
    scope = Keyword.get(opts, :scope, "api offline_access")

    case ReqAcumatica.Auth.acquire_token(
           base_url: base_url,
           client_id: client_id,
           client_secret: client_secret,
           username: username,
           password: password,
           tenant: tenant,
           scope: scope
         ) do
      {:ok, token} ->
        {:ok, [{"authorization", "Bearer #{token.access_token}"}], {:oauth2_token, token}}

      {:error, _} = error ->
        error
    end
  end

  defp resolve_auth({:session, username, password, company}, base_url, _tenant, _opts) do
    case ReqAcumatica.Session.login(
           base_url: base_url,
           username: username,
           password: password,
           company: company
         ) do
      {:ok, session} ->
        {:ok, [{"cookie", session.cookies}], {:session_token, session}}

      {:error, _} = error ->
        error
    end
  end

  defp resolve_auth(
         {:session_token, %ReqAcumatica.Session{} = session},
         _base_url,
         _tenant,
         _opts
       ) do
    {:ok, [{"cookie", session.cookies}], {:session_token, session}}
  end

  defp resolve_auth({:oauth2_token, %ReqAcumatica.Auth{} = token}, _base_url, _tenant, _opts) do
    {:ok, [{"authorization", "Bearer #{token.access_token}"}], {:oauth2_token, token}}
  end

  defp oauth2_private_opts({:oauth2, client_id, client_secret, username, password}, opts) do
    %{
      client_id: client_id,
      client_secret: client_secret,
      username: username,
      password: password,
      scope: Keyword.get(opts, :scope, "api offline_access")
    }
  end

  defp oauth2_private_opts(_auth, _opts), do: nil

  defp maybe_attach_token_refresh(req, {:oauth2_token, _token}) do
    Req.Request.prepend_request_steps(req, acumatica_token_refresh: &token_refresh_step/1)
  end

  defp maybe_attach_token_refresh(req, {:session_token, _session}) do
    Req.Request.prepend_request_steps(req, acumatica_session_refresh: &session_refresh_step/1)
  end

  defp maybe_attach_token_refresh(req, _auth), do: req

  defp token_refresh_step(request) do
    token =
      case request.private[:acumatica_auth] do
        {:oauth2_token, t} -> t
        _ -> nil
      end

    if token && ReqAcumatica.Auth.expired?(token) do
      base_url = request.private[:acumatica_base_url]
      oauth2_opts = request.private[:acumatica_oauth2_opts]

      case refresh_or_reacquire(token, base_url, oauth2_opts) do
        {:ok, new_token} ->
          request
          |> Req.Request.put_private(:acumatica_auth, {:oauth2_token, new_token})
          |> Req.Request.put_header("authorization", "Bearer #{new_token.access_token}")

        {:error, _} ->
          request
      end
    else
      request
    end
  end

  defp session_refresh_step(request) do
    session =
      case request.private[:acumatica_auth] do
        {:session_token, s} -> s
        _ -> nil
      end

    if session && ReqAcumatica.Session.expired?(session) do
      case ReqAcumatica.Session.refresh(session) do
        {:ok, new_session} ->
          request
          |> Req.Request.put_private(:acumatica_auth, {:session_token, new_session})
          |> Req.Request.put_header("cookie", new_session.cookies)

        {:error, _} ->
          request
      end
    else
      request
    end
  end

  defp refresh_or_reacquire(
         token,
         base_url,
         %{client_id: client_id, client_secret: client_secret} = oauth2_opts
       ) do
    refresh_opts = [base_url: base_url, client_id: client_id, client_secret: client_secret]

    case ReqAcumatica.Auth.refresh_token(token, refresh_opts) do
      {:ok, _} = success ->
        success

      {:error, _} ->
        ReqAcumatica.Auth.acquire_token(
          base_url: base_url,
          client_id: client_id,
          client_secret: client_secret,
          username: oauth2_opts.username,
          password: oauth2_opts.password,
          scope: oauth2_opts.scope
        )
    end
  end

  defp refresh_or_reacquire(_token, _base_url, _opts), do: {:error, :no_oauth2_config}
end
