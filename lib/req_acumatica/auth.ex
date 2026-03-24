defmodule ReqAcumatica.Auth do
  @moduledoc """
  OAuth2 authentication for Acumatica APIs.

  Handles the Resource Owner Password Credentials grant flow
  (`grant_type=password`) against Acumatica's identity server at
  `/identity/connect/token`.

  Manages token lifecycle: acquisition, caching, and automatic refresh.

  ## Setup

  1. In Acumatica, go to **SM303010** (Connected Applications)
  2. Create an application with Flow Type = "Resource Owner Password Credentials"
  3. Note the `client_id` and generate a `client_secret`

  ## Usage

      # Acquire a token
      {:ok, token} = ReqAcumatica.Auth.acquire_token(
        base_url: "https://mycompany.acumatica.com",
        client_id: "your-client-id",
        client_secret: "your-client-secret",
        username: "apiuser",
        password: "secret",
        scope: "api offline_access"
      )

      token.access_token
      # => "eyJhbG..."

      # Refresh an existing token
      {:ok, refreshed} = ReqAcumatica.Auth.refresh_token(token,
        base_url: "https://mycompany.acumatica.com",
        client_id: "your-client-id",
        client_secret: "your-client-secret"
      )
  """

  defstruct [
    :access_token,
    :refresh_token,
    :token_type,
    :expires_at,
    :expires_in
  ]

  @type t :: %__MODULE__{
          access_token: String.t(),
          refresh_token: String.t() | nil,
          token_type: String.t(),
          expires_at: DateTime.t() | nil,
          expires_in: pos_integer() | nil
        }

  @token_path "/identity/connect/token"
  @default_scope "api offline_access"

  @doc """
  Acquires an OAuth2 access token using the Resource Owner Password Credentials grant.

  ## Options

    * `:base_url` (required) — Acumatica instance URL
    * `:client_id` (required) — Connected Application client ID
    * `:client_secret` (required) — Connected Application client secret
    * `:username` (required) — Acumatica username
    * `:password` (required) — Acumatica password
    * `:scope` — OAuth2 scope (default: `"api offline_access"`)
    * `:tenant` — Tenant/company name. If provided, appended to client_id as `client_id@tenant`
  """
  @spec acquire_token(keyword()) :: {:ok, t()} | {:error, term()}
  def acquire_token(opts) do
    base_url = Keyword.fetch!(opts, :base_url)
    client_id = build_client_id(Keyword.fetch!(opts, :client_id), Keyword.get(opts, :tenant))
    client_secret = Keyword.fetch!(opts, :client_secret)
    username = Keyword.fetch!(opts, :username)
    password = Keyword.fetch!(opts, :password)
    scope = Keyword.get(opts, :scope, @default_scope)

    body =
      URI.encode_query(%{
        "grant_type" => "password",
        "client_id" => client_id,
        "client_secret" => client_secret,
        "username" => username,
        "password" => password,
        "scope" => scope
      })

    url = String.trim_trailing(base_url, "/") <> @token_path

    case Req.post(Req.new(),
           url: url,
           body: body,
           headers: [{"content-type", "application/x-www-form-urlencoded"}]
         ) do
      {:ok, %Req.Response{status: 200, body: body}} ->
        {:ok, parse_token_response(body)}

      {:ok, %Req.Response{status: status, body: body}} ->
        {:error, %ReqAcumatica.Error{status: status, message: format_token_error(body)}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Refreshes an existing OAuth2 token using the refresh_token grant.

  ## Options

    * `:base_url` (required) — Acumatica instance URL
    * `:client_id` (required) — Connected Application client ID
    * `:client_secret` (required) — Connected Application client secret
    * `:tenant` — Tenant/company name
  """
  @spec refresh_token(t(), keyword()) :: {:ok, t()} | {:error, term()}
  def refresh_token(%__MODULE__{refresh_token: nil}, _opts) do
    {:error,
     %ReqAcumatica.Error{
       message: "no refresh_token available (was offline_access scope requested?)"
     }}
  end

  def refresh_token(%__MODULE__{refresh_token: refresh_token}, opts) do
    base_url = Keyword.fetch!(opts, :base_url)
    client_id = build_client_id(Keyword.fetch!(opts, :client_id), Keyword.get(opts, :tenant))
    client_secret = Keyword.fetch!(opts, :client_secret)

    body =
      URI.encode_query(%{
        "grant_type" => "refresh_token",
        "client_id" => client_id,
        "client_secret" => client_secret,
        "refresh_token" => refresh_token
      })

    url = String.trim_trailing(base_url, "/") <> @token_path

    case Req.post(Req.new(),
           url: url,
           body: body,
           headers: [{"content-type", "application/x-www-form-urlencoded"}]
         ) do
      {:ok, %Req.Response{status: 200, body: body}} ->
        {:ok, parse_token_response(body)}

      {:ok, %Req.Response{status: status, body: body}} ->
        {:error, %ReqAcumatica.Error{status: status, message: format_token_error(body)}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Returns true if the token has expired or will expire within the given buffer (in seconds).

  Defaults to a 60-second buffer to allow for clock skew and network latency.
  """
  @spec expired?(t(), non_neg_integer()) :: boolean()
  def expired?(token, buffer \\ 60)
  def expired?(%__MODULE__{expires_at: nil}, _buffer), do: false

  def expired?(%__MODULE__{expires_at: expires_at}, buffer) do
    DateTime.compare(DateTime.utc_now(), DateTime.add(expires_at, -buffer, :second)) != :lt
  end

  defp build_client_id(client_id, nil), do: client_id
  defp build_client_id(client_id, tenant), do: "#{client_id}@#{tenant}"

  defp parse_token_response(body) when is_binary(body) do
    case Jason.decode(body) do
      {:ok, parsed} -> parse_token_response(parsed)
      {:error, _} -> %__MODULE__{access_token: body}
    end
  end

  defp parse_token_response(body) when is_map(body) do
    expires_in = body["expires_in"]

    expires_at =
      if is_integer(expires_in) do
        DateTime.add(DateTime.utc_now(), expires_in, :second)
      end

    %__MODULE__{
      access_token: body["access_token"],
      refresh_token: body["refresh_token"],
      token_type: body["token_type"] || "Bearer",
      expires_in: expires_in,
      expires_at: expires_at
    }
  end

  defp format_token_error(body) when is_map(body) do
    error = body["error"] || "unknown_error"
    description = body["error_description"]

    if description do
      "#{error}: #{description}"
    else
      error
    end
  end

  defp format_token_error(body), do: inspect(body)
end
