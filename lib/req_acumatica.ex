defmodule ReqAcumatica do
  @moduledoc """
  Req plugin for the Acumatica OData API (Generic Inquiries).

  Provides a configured `Req.Request` for querying Acumatica Generic Inquiries
  exposed via OData. Handles authentication (Basic Auth or OAuth2) and provides
  helper functions for building OData queries.

  ## Quick start

      # Create a client
      client = ReqAcumatica.new(
        base_url: "https://mycompany.acumatica.com",
        tenant: "MY TENANT",
        auth: {:basic, "admin", "password123"}
      )

      # List available Generic Inquiries
      {:ok, inquiries} = ReqAcumatica.list_inquiries(client)

      # Query a Generic Inquiry
      {:ok, results} = ReqAcumatica.query(client, "Sales Orders and Quotes",
        filter: "Status eq 'Open'",
        top: 25,
        orderby: "OrderTotal desc"
      )

      # Get metadata for a Generic Inquiry
      {:ok, metadata} = ReqAcumatica.metadata(client, "InvoicedItems")

  ## Authentication

  Three auth methods are supported:

  - **Basic Auth**: `{:basic, username, password}`
  - **OAuth2 Bearer**: `{:bearer, token}` (obtain token separately via Connected Applications)
  - **OAuth2 Resource Owner**: `{:oauth2, client_id, client_secret, username, password}` —
    automatically acquires and refreshes tokens via Acumatica's Connected Applications

  ## OData Query Options

  Standard OData query parameters are supported:

  - `$filter` — OData filter expressions (e.g. `"Status eq 'Open'"`)
  - `$top` — limit number of results
  - `$skip` — skip N results (for pagination)
  - `$orderby` — sort results
  - `$select` — select specific fields
  - `$format` — response format (defaults to JSON)
  """

  @type client :: Req.Request.t()

  @type auth ::
          {:basic, username :: String.t(), password :: String.t()}
          | {:bearer, token :: String.t()}
          | {:oauth2, client_id :: String.t(), client_secret :: String.t(),
             username :: String.t(), password :: String.t()}
          | {:oauth2_token, ReqAcumatica.Auth.t()}

  @type query_opt ::
          {:filter, String.t()}
          | {:top, pos_integer()}
          | {:skip, non_neg_integer()}
          | {:orderby, String.t()}
          | {:select, String.t() | [String.t()]}
          | {:format, :json | :atom}

  @doc """
  Creates a new Acumatica OData client.

  ## Options

    * `:base_url` (required) — The base URL of the Acumatica instance
      (e.g. `"https://mycompany.acumatica.com"`)

    * `:tenant` (required) — The tenant/company name
      (e.g. `"NEWLIGHT LIVE"`)

    * `:auth` (required) — Authentication credentials. One of:
      - `{:basic, username, password}` for Basic Auth
      - `{:bearer, token}` for a pre-obtained OAuth2 Bearer token
      - `{:oauth2, client_id, client_secret, username, password}` for automatic
        OAuth2 token acquisition and refresh via Connected Applications
      - `{:oauth2_token, %ReqAcumatica.Auth{}}` for a pre-acquired token struct

    * `:scope` — OAuth2 scope (default: `"api offline_access"`). Only used with `:oauth2` auth.

    * `:req_options` — Additional options passed to `Req.new/1`

  ## Examples

      # Basic Auth
      client = ReqAcumatica.new(
        base_url: "https://newlight.acumatica.com",
        tenant: "NEWLIGHT LIVE",
        auth: {:basic, "apiuser", "secret"}
      )

      # OAuth2 with automatic token management
      client = ReqAcumatica.new(
        base_url: "https://newlight.acumatica.com",
        tenant: "NEWLIGHT LIVE",
        auth: {:oauth2, "client-id", "client-secret", "apiuser", "password"}
      )
  """
  @spec new(keyword()) :: client() | {:error, term()}
  def new(opts) do
    base_url = Keyword.fetch!(opts, :base_url)
    tenant = Keyword.fetch!(opts, :tenant)
    auth = Keyword.fetch!(opts, :auth)
    req_options = Keyword.get(opts, :req_options, [])

    encoded_tenant = URI.encode(tenant)
    odata_base = "#{String.trim_trailing(base_url, "/")}/odata/#{encoded_tenant}"

    case resolve_auth(auth, base_url, tenant, opts) do
      {:ok, auth_headers, resolved_auth} ->
        req_options
        |> Keyword.merge(
          base_url: odata_base,
          headers: [{"accept", "application/json"} | auth_headers]
        )
        |> Req.new()
        |> Req.Request.register_options([:acumatica_tenant, :acumatica_auth])
        |> Req.Request.put_private(:acumatica_tenant, tenant)
        |> Req.Request.put_private(:acumatica_auth, resolved_auth)
        |> Req.Request.put_private(:acumatica_base_url, base_url)
        |> Req.Request.put_private(:acumatica_oauth2_opts, oauth2_private_opts(auth, opts))
        |> maybe_attach_token_refresh(resolved_auth)

      {:error, _} = error ->
        error
    end
  end

  @doc """
  Lists all Generic Inquiries exposed via OData.

  Returns the service document listing available entity sets (GIs).

  ## Examples

      {:ok, inquiries} = ReqAcumatica.list_inquiries(client)
      # => ["Sales Orders and Quotes", "InvoicedItems", ...]
  """
  @spec list_inquiries(client()) :: {:ok, [String.t()]} | {:error, term()}
  def list_inquiries(client) do
    case Req.get(client, url: "") do
      {:ok, %Req.Response{status: 200, body: body}} ->
        names = parse_service_document(body)
        {:ok, names}

      {:ok, %Req.Response{status: status, body: body}} ->
        {:error, %ReqAcumatica.Error{status: status, message: inspect(body)}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Fetches OData `$metadata` for a specific Generic Inquiry.

  Returns the raw XML metadata describing entity types, fields, and keys.

  ## Examples

      {:ok, metadata_xml} = ReqAcumatica.metadata(client, "InvoicedItems")
  """
  @spec metadata(client(), String.t()) :: {:ok, String.t()} | {:error, term()}
  def metadata(client, inquiry_name) do
    # $metadata returns XML, override Accept header
    url = "#{URI.encode(inquiry_name)}/$metadata"

    case Req.get(client, url: url, headers: [{"accept", "application/xml"}]) do
      {:ok, %Req.Response{status: 200, body: body}} ->
        {:ok, body}

      {:ok, %Req.Response{status: status, body: body}} ->
        {:error, %ReqAcumatica.Error{status: status, message: inspect(body)}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Queries a Generic Inquiry via OData.

  ## Options

    * `:filter` — OData `$filter` expression string
    * `:top` — maximum number of results to return
    * `:skip` — number of results to skip
    * `:orderby` — OData `$orderby` expression
    * `:select` — fields to return (string or list of strings)
    * `:format` — `:json` (default) or `:atom`

  ## Examples

      # Simple query
      {:ok, results} = ReqAcumatica.query(client, "Sales Orders and Quotes")

      # With filters and pagination
      {:ok, results} = ReqAcumatica.query(client, "Sales Orders and Quotes",
        filter: "Status eq 'Open' and OrderTotal gt 1000",
        top: 50,
        skip: 0,
        orderby: "OrderTotal desc",
        select: ["OrderNbr", "Status", "OrderTotal"]
      )
  """
  @spec query(client(), String.t(), [query_opt()]) ::
          {:ok, ReqAcumatica.Result.t()} | {:error, term()}
  def query(client, inquiry_name, opts \\ []) do
    params = build_query_params(opts)
    url = URI.encode(inquiry_name)

    case Req.get(client, url: url, params: params) do
      {:ok, %Req.Response{status: 200, body: body}} ->
        result = ReqAcumatica.Result.from_odata_response(body)
        {:ok, result}

      {:ok, %Req.Response{status: status, body: body}} ->
        {:error, %ReqAcumatica.Error{status: status, message: inspect(body)}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Queries a Generic Inquiry and automatically paginates through all results.

  Uses `$top` and `$skip` internally to fetch pages of `page_size` (default 200)
  until all matching results are retrieved or `max_results` is reached.

  ## Options

  Accepts all options from `query/3`, plus:

    * `:page_size` — number of results per page (default: 200)
    * `:max_results` — maximum total results to fetch (default: `:infinity`)

  ## Examples

      {:ok, all_orders} = ReqAcumatica.query_all(client, "Sales Orders and Quotes",
        filter: "Status eq 'Open'",
        max_results: 1000
      )
  """
  @spec query_all(client(), String.t(), keyword()) ::
          {:ok, ReqAcumatica.Result.t()} | {:error, term()}
  def query_all(client, inquiry_name, opts \\ []) do
    page_size = Keyword.get(opts, :page_size, 200)
    max_results = Keyword.get(opts, :max_results, :infinity)
    query_opts = Keyword.drop(opts, [:page_size, :max_results])

    do_paginate(client, inquiry_name, query_opts, page_size, max_results, 0, [])
  end

  @doc """
  Returns a lazy stream of results from a Generic Inquiry.

  Useful for processing large result sets without loading everything into memory.

  ## Examples

      client
      |> ReqAcumatica.stream("Large Inquiry", page_size: 100)
      |> Stream.filter(& &1["Status"] == "Open")
      |> Stream.take(50)
      |> Enum.to_list()
  """
  @spec stream(client(), String.t(), keyword()) :: Enumerable.t()
  def stream(client, inquiry_name, opts \\ []) do
    page_size = Keyword.get(opts, :page_size, 200)
    query_opts = Keyword.drop(opts, [:page_size])

    Stream.resource(
      fn -> 0 end,
      fn
        :halt ->
          {:halt, :done}

        skip ->
          page_opts = Keyword.merge(query_opts, top: page_size, skip: skip)

          case query(client, inquiry_name, page_opts) do
            {:ok, %ReqAcumatica.Result{rows: []}} ->
              {:halt, :done}

            {:ok, %ReqAcumatica.Result{rows: rows}} when length(rows) < page_size ->
              {rows, :halt}

            {:ok, %ReqAcumatica.Result{rows: rows}} ->
              {rows, skip + page_size}

            {:error, error} ->
              raise "ReqAcumatica stream error: #{inspect(error)}"
          end
      end,
      fn _ -> :ok end
    )
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

  # -- Private: Query Building --

  defp build_query_params(opts) do
    opts
    |> Enum.reduce([], fn
      {:filter, value}, acc -> [{"$filter", value} | acc]
      {:top, value}, acc -> [{"$top", to_string(value)} | acc]
      {:skip, value}, acc -> [{"$skip", to_string(value)} | acc]
      {:orderby, value}, acc -> [{"$orderby", value} | acc]
      {:select, fields}, acc when is_list(fields) -> [{"$select", Enum.join(fields, ",")} | acc]
      {:select, value}, acc -> [{"$select", value} | acc]
      {:format, :json}, acc -> [{"$format", "json"} | acc]
      {:format, :atom}, acc -> [{"$format", "atom"} | acc]
      _, acc -> acc
    end)
  end

  defp parse_service_document(%{"value" => entities}) when is_list(entities) do
    Enum.map(entities, fn
      %{"name" => name} -> name
      %{"url" => url} -> url
    end)
  end

  defp parse_service_document(_body), do: []

  defp do_paginate(_client, _name, _opts, _page_size, max, _skip, acc)
       when max != :infinity and length(acc) >= max do
    rows = Enum.take(acc, max)
    {:ok, %ReqAcumatica.Result{rows: rows, count: length(rows)}}
  end

  defp do_paginate(client, name, opts, page_size, max, skip, acc) do
    page_opts = Keyword.merge(opts, top: page_size, skip: skip)

    case query(client, name, page_opts) do
      {:ok, %ReqAcumatica.Result{rows: []}} ->
        {:ok, %ReqAcumatica.Result{rows: acc, count: length(acc)}}

      {:ok, %ReqAcumatica.Result{rows: rows}} ->
        new_acc = acc ++ rows

        if length(rows) < page_size do
          total =
            if max != :infinity, do: Enum.take(new_acc, max), else: new_acc

          {:ok, %ReqAcumatica.Result{rows: total, count: length(total)}}
        else
          do_paginate(client, name, opts, page_size, max, skip + page_size, new_acc)
        end

      {:error, _} = error ->
        error
    end
  end
end
