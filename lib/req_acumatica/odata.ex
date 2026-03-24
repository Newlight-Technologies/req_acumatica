defmodule ReqAcumatica.OData do
  @moduledoc """
  OData API for querying Acumatica Generic Inquiries.

  Generic Inquiries (GIs) are custom report-like queries built in Acumatica's UI
  and exposed as read-only OData feeds.

  ## Examples

      req = ReqAcumatica.new(base_url: "...", tenant: "...", auth: {...})

      # List available GIs
      {:ok, inquiries} = ReqAcumatica.OData.list_inquiries(req)

      # Query a GI
      {:ok, result} = ReqAcumatica.OData.query(req, "Sales Orders and Quotes",
        filter: "Status eq 'Open'",
        top: 25
      )

      # Paginate through all results
      {:ok, all} = ReqAcumatica.OData.query_all(req, "Large Inquiry", max_results: 5000)

      # Lazy stream
      req
      |> ReqAcumatica.OData.stream("Inventory Items")
      |> Stream.take(100)
      |> Enum.to_list()
  """

  @type query_opt ::
          {:filter, String.t()}
          | {:top, pos_integer()}
          | {:skip, non_neg_integer()}
          | {:orderby, String.t()}
          | {:select, String.t() | [String.t()]}
          | {:format, :json | :atom}

  @doc """
  Lists all Generic Inquiries exposed via OData.

  Returns the service document listing available entity sets (GIs).
  """
  @spec list_inquiries(Req.Request.t()) :: {:ok, [String.t()]} | {:error, term()}
  def list_inquiries(req) do
    url = ReqAcumatica.odata_url(req)

    case Req.get(req, url: url) do
      {:ok, %Req.Response{status: 200, body: body}} ->
        {:ok, parse_service_document(body)}

      {:ok, resp} ->
        {:error, error_from_response(resp)}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Fetches OData `$metadata` for a specific Generic Inquiry.

  Returns the raw XML metadata describing entity types, fields, and keys.
  """
  @spec metadata(Req.Request.t(), String.t()) :: {:ok, String.t()} | {:error, term()}
  def metadata(req, inquiry_name) do
    url = ReqAcumatica.odata_url(req, "#{URI.encode(inquiry_name)}/$metadata")

    case Req.get(req, url: url, headers: [{"accept", "application/xml"}]) do
      {:ok, %Req.Response{status: 200, body: body}} ->
        {:ok, body}

      {:ok, resp} ->
        {:error, error_from_response(resp)}

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
  """
  @spec query(Req.Request.t(), String.t(), [query_opt()]) ::
          {:ok, ReqAcumatica.Result.t()} | {:error, term()}
  def query(req, inquiry_name, opts \\ []) do
    params = build_query_params(opts)
    url = ReqAcumatica.odata_url(req, URI.encode(inquiry_name))

    case Req.get(req, url: url, params: params) do
      {:ok, %Req.Response{status: 200, body: body}} ->
        {:ok, ReqAcumatica.Result.from_odata_response(body)}

      {:ok, resp} ->
        {:error, error_from_response(resp)}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Queries a Generic Inquiry and automatically paginates through all results.

  ## Options

  Accepts all options from `query/3`, plus:

    * `:page_size` — number of results per page (default: 200)
    * `:max_results` — maximum total results to fetch (default: `:infinity`)
  """
  @spec query_all(Req.Request.t(), String.t(), keyword()) ::
          {:ok, ReqAcumatica.Result.t()} | {:error, term()}
  def query_all(req, inquiry_name, opts \\ []) do
    page_size = Keyword.get(opts, :page_size, 200)
    max_results = Keyword.get(opts, :max_results, :infinity)
    query_opts = Keyword.drop(opts, [:page_size, :max_results])

    do_paginate(req, inquiry_name, query_opts, page_size, max_results, 0, [])
  end

  @doc """
  Returns a lazy stream of results from a Generic Inquiry.

  Useful for processing large result sets without loading everything into memory.
  """
  @spec stream(Req.Request.t(), String.t(), keyword()) :: Enumerable.t()
  def stream(req, inquiry_name, opts \\ []) do
    page_size = Keyword.get(opts, :page_size, 200)
    query_opts = Keyword.drop(opts, [:page_size])

    Stream.resource(
      fn -> 0 end,
      fn
        :halt ->
          {:halt, :done}

        skip ->
          page_opts = Keyword.merge(query_opts, top: page_size, skip: skip)

          case query(req, inquiry_name, page_opts) do
            {:ok, %ReqAcumatica.Result{rows: []}} ->
              {:halt, :done}

            {:ok, %ReqAcumatica.Result{rows: rows}} when length(rows) < page_size ->
              {rows, :halt}

            {:ok, %ReqAcumatica.Result{rows: rows}} ->
              {rows, skip + page_size}

            {:error, error} ->
              raise "ReqAcumatica.OData stream error: #{inspect(error)}"
          end
      end,
      fn _ -> :ok end
    )
  end

  # -- Private --

  defp build_query_params(opts) do
    Enum.reduce(opts, [], fn
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

  defp do_paginate(_req, _name, _opts, _page_size, max, _skip, acc)
       when max != :infinity and length(acc) >= max do
    rows = Enum.take(acc, max)
    {:ok, %ReqAcumatica.Result{rows: rows, count: length(rows)}}
  end

  defp do_paginate(req, name, opts, page_size, max, skip, acc) do
    page_opts = Keyword.merge(opts, top: page_size, skip: skip)

    case query(req, name, page_opts) do
      {:ok, %ReqAcumatica.Result{rows: []}} ->
        {:ok, %ReqAcumatica.Result{rows: acc, count: length(acc)}}

      {:ok, %ReqAcumatica.Result{rows: rows}} ->
        new_acc = acc ++ rows

        if length(rows) < page_size do
          total = if max != :infinity, do: Enum.take(new_acc, max), else: new_acc
          {:ok, %ReqAcumatica.Result{rows: total, count: length(total)}}
        else
          do_paginate(req, name, opts, page_size, max, skip + page_size, new_acc)
        end

      {:error, _} = error ->
        error
    end
  end

  defp error_from_response(%Req.Response{status: status, body: body}) do
    %ReqAcumatica.Error{status: status, message: inspect(body)}
  end
end
