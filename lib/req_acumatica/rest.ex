defmodule ReqAcumatica.REST do
  @moduledoc """
  Contract-Based REST API for Acumatica entity CRUD and actions.

  Provides full create/read/update/delete operations on Acumatica business
  entities (Sales Orders, Shipments, Customers, Inventory Items, etc.)
  via the `/entity/Default/{version}/{EntityName}` endpoints.

  ## Examples

      req = ReqAcumatica.new(base_url: "...", tenant: "...", auth: {...})

      # Get a single entity by key fields
      {:ok, order} = ReqAcumatica.REST.get(req, "SalesOrder",
        filter: "OrderNbr eq 'SO-001234' and OrderType eq 'SO'"
      )

      # List entities
      {:ok, orders} = ReqAcumatica.REST.list(req, "SalesOrder",
        filter: "Status eq 'Open'",
        top: 50,
        select: "OrderNbr,Status,OrderTotal"
      )

      # Create an entity
      {:ok, created} = ReqAcumatica.REST.create(req, "SalesOrder", %{
        "OrderType" => %{"value" => "SO"},
        "CustomerID" => %{"value" => "CUSTOMER01"},
        "Description" => %{"value" => "New order from API"}
      })

      # Update an entity
      {:ok, updated} = ReqAcumatica.REST.update(req, "SalesOrder", %{
        "OrderType" => %{"value" => "SO"},
        "OrderNbr" => %{"value" => "SO-001234"},
        "Description" => %{"value" => "Updated description"}
      })

      # Delete an entity by key fields
      :ok = ReqAcumatica.REST.delete(req, "SalesOrder",
        filter: "OrderNbr eq 'SO-001234' and OrderType eq 'SO'"
      )

      # Invoke an entity action
      {:ok, result} = ReqAcumatica.REST.action(req, "SalesOrder", "ReleaseFromHold", %{
        "entity" => %{
          "OrderType" => %{"value" => "SO"},
          "OrderNbr" => %{"value" => "SO-001234"}
        }
      })

  ## Acumatica REST API Value Format

  Acumatica's REST API wraps field values in `%{"value" => actual_value}` objects.
  When creating or updating entities, you must use this format:

      %{"CustomerID" => %{"value" => "CUST01"}, "Description" => %{"value" => "text"}}

  Read responses also return this format. Use `unwrap_values/1` to flatten:

      {:ok, order} = ReqAcumatica.REST.get(req, "SalesOrder", ...)
      flat = ReqAcumatica.REST.unwrap_values(order)
      # %{"CustomerID" => "CUST01", "Description" => "text", ...}
  """

  @type query_opt ::
          {:filter, String.t()}
          | {:top, pos_integer()}
          | {:skip, non_neg_integer()}
          | {:select, String.t()}
          | {:expand, String.t()}
          | {:custom_fields, String.t()}
          | {:custom, String.t()}

  @doc """
  Retrieves a list of entities.

  ## Options

    * `:filter` — OData `$filter` expression
    * `:top` — maximum number of results
    * `:skip` — number of results to skip
    * `:select` — comma-separated field names to return
    * `:expand` — related entities to include (e.g. `"Details"` or `"Details,TaxDetails,files"`)
    * `:custom_fields` — `$custom` value for Usr fields (e.g. `"Document.UsrField"`)
    * `:custom` — raw query string key to append verbatim (escape hatch)

  Note: this is a single page. For a bounded multi-page pull use `list_all/3`.
  """
  @spec list(Req.Request.t(), String.t(), keyword()) :: {:ok, [map()]} | {:error, term()}
  def list(req, entity_name, opts \\ []) do
    url = ReqAcumatica.rest_url(req, entity_name)
    params = build_params(opts)

    case Req.get(req, url: url, params: params) do
      {:ok, %Req.Response{status: 200, body: body}} when is_list(body) ->
        {:ok, body}

      {:ok, %Req.Response{status: 200, body: body}} ->
        {:ok, List.wrap(body)}

      {:ok, resp} ->
        {:error, error_from_response(resp)}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Retrieves entities across multiple pages via `$top`/`$skip`, bounded by `:max_results`.

  The REST contract API returns at most one page per request; this helper paginates
  until a short page is returned or `:max_results` is reached. Always pass `:max_results`
  for non-browse use so a full read cannot happen by accident.

  ## Options

  All `list/3` options, plus:

    * `:page_size` — rows per request (default `200`)
    * `:max_results` — hard cap on total rows (default `:infinity`)

  ## Examples

      {:ok, rows} = ReqAcumatica.REST.list_all(req, "Bill", filter: "Status eq 'Open'", max_results: 1000)
  """
  @spec list_all(Req.Request.t(), String.t(), keyword()) :: {:ok, [map()]} | {:error, term()}
  def list_all(req, entity_name, opts \\ []) do
    page_size = Keyword.get(opts, :page_size, 200)
    max_results = Keyword.get(opts, :max_results, :infinity)
    base_opts = Keyword.drop(opts, [:page_size, :max_results, :top, :skip])

    do_paginate(req, entity_name, base_opts, page_size, max_results, 0, [])
  end

  @doc """
  Retrieves a single entity by key fields.

  Pass key field values as path segments after the entity name:

      # Single key
      ReqAcumatica.REST.get(req, "Customer/CUST01")

      # Compound key via filter
      ReqAcumatica.REST.get(req, "SalesOrder",
        filter: "OrderNbr eq 'SO-001234' and OrderType eq 'SO'"
      )

  ## Options

    * `:select` — comma-separated field names to return
    * `:expand` — related entities to include
    * `:filter` — OData filter (for compound keys)
  """
  @spec get(Req.Request.t(), String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def get(req, entity_path, opts \\ []) do
    url = ReqAcumatica.rest_url(req, entity_path)
    params = build_params(opts)

    case Req.get(req, url: url, params: params) do
      {:ok, %Req.Response{status: 200, body: body}} ->
        {:ok, body}

      {:ok, resp} ->
        {:error, error_from_response(resp)}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Creates a new entity.

  The `body` map must use Acumatica's value wrapper format:

      %{"FieldName" => %{"value" => actual_value}}

  Returns the created entity on success.
  """
  @spec create(Req.Request.t(), String.t(), map()) :: {:ok, map()} | {:error, term()}
  def create(req, entity_name, body) do
    url = ReqAcumatica.rest_url(req, entity_name)

    case Req.put(req, url: url, json: body) do
      {:ok, %Req.Response{status: status, body: resp_body}} when status in [200, 201] ->
        {:ok, resp_body}

      {:ok, resp} ->
        {:error, error_from_response(resp)}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Updates an existing entity.

  The `body` map must include the key fields to identify the record,
  plus any fields to update, all in Acumatica's value wrapper format.

  Returns the updated entity on success.

  > Note: the contract API has no separate create/update — both `create/3` and
  > `update/3` issue `PUT {Entity}` (an upsert keyed on the body's key fields). The two
  > functions differ only in intent/accepted status codes; pick by what reads clearer.
  """
  @spec update(Req.Request.t(), String.t(), map()) :: {:ok, map()} | {:error, term()}
  def update(req, entity_name, body) do
    url = ReqAcumatica.rest_url(req, entity_name)

    case Req.put(req, url: url, json: body) do
      {:ok, %Req.Response{status: 200, body: resp_body}} ->
        {:ok, resp_body}

      {:ok, resp} ->
        {:error, error_from_response(resp)}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Deletes an entity by key fields.

  Pass key field values as path segments or use `:filter`.

      ReqAcumatica.REST.delete(req, "Customer/CUST01")
  """
  @spec delete(Req.Request.t(), String.t(), keyword()) :: :ok | {:error, term()}
  def delete(req, entity_path, opts \\ []) do
    url = ReqAcumatica.rest_url(req, entity_path)
    params = build_params(opts)

    case Req.delete(req, url: url, params: params) do
      {:ok, %Req.Response{status: status}} when status in [200, 204] ->
        :ok

      {:ok, resp} ->
        {:error, error_from_response(resp)}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Invokes an action on an entity endpoint.

  Actions are Acumatica business logic operations like "ReleaseFromHold",
  "ConfirmShipment", etc.

      ReqAcumatica.REST.action(req, "SalesOrder", "ReleaseFromHold", %{
        "entity" => %{
          "OrderType" => %{"value" => "SO"},
          "OrderNbr" => %{"value" => "SO-001234"}
        }
      })
  """
  @spec action(Req.Request.t(), String.t(), String.t(), map()) ::
          {:ok, map()} | {:error, term()}
  def action(req, entity_name, action_name, body \\ %{}) do
    url = ReqAcumatica.rest_url(req, "#{entity_name}/#{action_name}")

    case Req.post(req, url: url, json: body) do
      {:ok, %Req.Response{status: status, body: resp_body}} when status in [200, 202, 204] ->
        {:ok, resp_body}

      {:ok, resp} ->
        {:error, error_from_response(resp)}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Checks the status of a long-running operation.

  Some Acumatica actions return a `202 Accepted` with a `Location` header
  pointing to a status endpoint. Use this to poll for completion.
  """
  @spec operation_status(Req.Request.t(), String.t()) :: {:ok, map()} | {:error, term()}
  def operation_status(req, location_url) do
    case Req.get(req, url: location_url) do
      {:ok, %Req.Response{status: 200, body: body}} ->
        {:ok, body}

      {:ok, %Req.Response{status: 202, body: body}} ->
        {:ok, Map.put(body || %{}, "status", "In Progress")}

      {:ok, %Req.Response{status: 204}} ->
        {:ok, %{"status" => "Completed"}}

      {:ok, resp} ->
        {:error, error_from_response(resp)}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Unwraps Acumatica's `%{"value" => x}` field format into a flat map.

  Recursively unwraps nested maps and lists.

  ## Examples

      iex> ReqAcumatica.REST.unwrap_values(%{
      ...>   "OrderNbr" => %{"value" => "SO-001"},
      ...>   "Status" => %{"value" => "Open"},
      ...>   "Details" => [%{"InventoryID" => %{"value" => "ITEM1"}}]
      ...> })
      %{"OrderNbr" => "SO-001", "Status" => "Open", "Details" => [%{"InventoryID" => "ITEM1"}]}
  """
  @spec unwrap_values(map() | list()) :: map() | list()
  def unwrap_values(%{"value" => value}), do: value

  def unwrap_values(map) when is_map(map) do
    Map.new(map, fn {key, value} -> {key, unwrap_values(value)} end)
  end

  def unwrap_values(list) when is_list(list) do
    Enum.map(list, &unwrap_values/1)
  end

  def unwrap_values(other), do: other

  # -- File Attachments --

  @doc """
  Uploads a file attachment to an entity.

  Uses PUT with raw binary body to Acumatica's file attachment endpoint.

  ## Examples

      # Upload from file path
      ReqAcumatica.REST.attach_file(req, "PurchaseOrder/PO-001", "invoice.pdf",
        {:file, "/path/to/invoice.pdf"})

      # Upload from binary
      ReqAcumatica.REST.attach_file(req, "PurchaseOrder/PO-001", "data.csv",
        {:binary, csv_content})
  """
  @spec attach_file(
          Req.Request.t(),
          String.t(),
          String.t(),
          {:file, String.t()} | {:binary, binary()}
        ) ::
          :ok | {:error, term()}
  def attach_file(req, entity_path, filename, source) do
    url = ReqAcumatica.rest_url(req, "#{entity_path}/files/#{URI.encode(filename)}")

    body =
      case source do
        {:file, path} -> File.stream!(path, [], 65_536)
        {:binary, data} -> data
      end

    case Req.put(req,
           url: url,
           body: body,
           headers: [{"content-type", "application/octet-stream"}]
         ) do
      {:ok, %Req.Response{status: status}} when status in [200, 204] -> :ok
      {:ok, resp} -> {:error, error_from_response(resp)}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Downloads a file attachment from an entity **by filename**.

  Returns the raw binary content via `GET {entity_path}/files/{filename}`. Note that
  Acumatica filenames are often folder-prefixed (e.g.
  `"Bills and Adjustments (ACR 004849)\\\\invoice.pdf"`), which makes this path fragile.
  Prefer `download_file_by_id/2` with a FileID from `list_files/2`.

  ## Examples

      {:ok, binary} = ReqAcumatica.REST.download_file(req, "PurchaseOrder/PO-001", "invoice.pdf")
      File.write!("/tmp/invoice.pdf", binary)
  """
  @spec download_file(Req.Request.t(), String.t(), String.t()) ::
          {:ok, binary()} | {:error, term()}
  def download_file(req, entity_path, filename) do
    url = ReqAcumatica.rest_url(req, "#{entity_path}/files/#{URI.encode(filename)}")

    case Req.get(req, url: url, raw: true) do
      {:ok, %Req.Response{status: 200, body: body}} -> {:ok, body}
      {:ok, resp} -> {:error, error_from_response(resp)}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Downloads a file attachment by its FileID.

  This is the preferred download path (`GET files/{FileID}`). FileIDs come from
  `list_files/2` (each entry's `"id"`), avoiding the fragile folder-prefixed filename
  that `download_file/3` requires.

  ## Examples

      {:ok, [%{"id" => id} | _]} = ReqAcumatica.REST.list_files(req, "Bill/Invoice/004849")
      {:ok, binary} = ReqAcumatica.REST.download_file_by_id(req, id)
  """
  @spec download_file_by_id(Req.Request.t(), String.t()) :: {:ok, binary()} | {:error, term()}
  def download_file_by_id(req, file_id) do
    url = ReqAcumatica.rest_url(req, "files/#{URI.encode(file_id)}")

    case Req.get(req, url: url, raw: true) do
      {:ok, %Req.Response{status: 200, body: body}} -> {:ok, body}
      {:ok, resp} -> {:error, error_from_response(resp)}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Lists file attachments on an entity via `$expand=files`.

  Returns the raw `files` array from the entity response. Each entry is a map with
  `"filename"`, `"href"`, and `"id"` (the FileID). Download a file with
  `download_file_by_id/2`.

  > Note: this uses `$expand=files`. The older `FileURLs` field is not returned by the
  > contract endpoint, so do not rely on it.

  ## Examples

      {:ok, files} = ReqAcumatica.REST.list_files(req, "Bill/Invoice/004849")
      # => [%{"filename" => "...", "href" => "/entity/.../files/<id>", "id" => "<id>"}]
  """
  @spec list_files(Req.Request.t(), String.t()) :: {:ok, [map()]} | {:error, term()}
  def list_files(req, entity_path) do
    case get(req, entity_path, expand: "files") do
      {:ok, %{"files" => files}} when is_list(files) -> {:ok, files}
      {:ok, _} -> {:ok, []}
      {:error, _} = error -> error
    end
  end

  # -- Custom Fields --

  @doc """
  Extracts a custom field value from an entity response.

  Custom fields in Acumatica are nested as:
  `custom.{ScreenView}.{FieldName}.value`

  ## Examples

      entity = %{"custom" => %{"Item" => %{"UsrMyField" => %{"value" => "hello"}}}}
      ReqAcumatica.REST.get_custom_field(entity, "Item", "UsrMyField")
      # => "hello"

      # Get all custom fields for a view
      ReqAcumatica.REST.get_custom_fields(entity, "Item")
      # => %{"UsrMyField" => "hello", ...}
  """
  @spec get_custom_field(map(), String.t(), String.t()) :: term()
  def get_custom_field(entity, view, field_name) do
    get_in(entity, ["custom", view, field_name, "value"])
  end

  @doc """
  Returns all custom fields for a view as a flat map.
  """
  @spec get_custom_fields(map(), String.t()) :: map()
  def get_custom_fields(entity, view) do
    case get_in(entity, ["custom", view]) do
      fields when is_map(fields) ->
        Map.new(fields, fn {name, spec} ->
          {name, if(is_map(spec), do: spec["value"], else: spec)}
        end)

      _ ->
        %{}
    end
  end

  @doc """
  Builds the custom field structure for create/update requests.

  ## Examples

      custom = ReqAcumatica.REST.build_custom_fields("Item", %{
        "UsrMyField" => "hello",
        "UsrCount" => 42
      })
      # => %{"custom" => %{"Item" => %{"UsrMyField" => %{"value" => "hello"}, ...}}}

      # Merge into entity body
      body = Map.merge(%{"InventoryID" => %{"value" => "ITEM01"}}, custom)
      ReqAcumatica.REST.create(req, "StockItem", body)
  """
  @spec build_custom_fields(String.t(), map()) :: map()
  def build_custom_fields(view, fields) when is_map(fields) do
    wrapped =
      Map.new(fields, fn {name, value} ->
        {name, %{"value" => value}}
      end)

    %{"custom" => %{view => wrapped}}
  end

  @doc """
  Fetches an entity's **live** ad-hoc schema (`GET {Entity}/$adHocSchema`).

  Unlike `describe/2` (which reads the static `swagger.json` and can diverge from a
  tenant's live endpoint — e.g. listing a field that is not actually expandable), this
  returns the schema the running endpoint actually serves, including real custom fields.

  ## Examples

      {:ok, schema} = ReqAcumatica.REST.ad_hoc_schema(req, "StockItem")
  """
  @spec ad_hoc_schema(Req.Request.t(), String.t()) :: {:ok, map()} | {:error, term()}
  def ad_hoc_schema(req, entity_name) do
    url = ReqAcumatica.rest_url(req, "#{entity_name}/$adHocSchema")

    case Req.get(req, url: url) do
      {:ok, %Req.Response{status: 200, body: body}} -> {:ok, body}
      {:ok, resp} -> {:error, error_from_response(resp)}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Describes an entity's schema from the static `swagger.json` spec.

  Returns a map of field names to their types and metadata, including nested
  detail entities (arrays).

  > Note: `swagger.json` is static and may diverge from the live endpoint (it can list
  > fields that are not live-expandable). Use `ad_hoc_schema/2` for the live schema.

  ## Examples

      {:ok, schema} = ReqAcumatica.REST.describe(req, "StockItem")
      # => %{
      #   "InventoryID" => %{type: :string},
      #   "AverageCost" => %{type: :decimal},
      #   "IsAKit" => %{type: :boolean},
      #   "LastModifiedDateTime" => %{type: :datetime},
      #   "NoteID" => %{type: :guid},
      #   "Details" => %{type: :array, entity: "SalesOrderDetail"},
      #   ...
      # }

      # List all available entities
      {:ok, entities} = ReqAcumatica.REST.describe(req)
  """
  @spec describe(Req.Request.t(), String.t() | nil) ::
          {:ok, map() | [String.t()]} | {:error, term()}
  def describe(req, entity_name \\ nil) do
    base_url = req.private[:acumatica_base_url]
    version = req.private[:acumatica_api_version]
    tenant = req.private[:acumatica_tenant]
    url = "#{base_url}/entity/Default/#{version}/swagger.json"

    case Req.get(req, url: url, params: [{"company", tenant}]) do
      {:ok, %Req.Response{status: 200, body: body}} when is_map(body) ->
        schemas = get_in(body, ["components", "schemas"]) || %{}

        if entity_name do
          describe_entity(schemas, entity_name)
        else
          describe_all(body, schemas)
        end

      {:ok, resp} ->
        {:error, error_from_response(resp)}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp describe_entity(schemas, entity_name) do
    case schemas[entity_name] do
      nil ->
        {:error,
         %ReqAcumatica.Error{message: "Entity '#{entity_name}' not found in swagger schema"}}

      schema ->
        props = extract_properties(schema)

        fields =
          Map.new(props, fn {name, spec} ->
            {name, resolve_field_type(spec, schemas)}
          end)
          |> Map.reject(fn {k, _} ->
            k in ["_links", "custom", "id", "note", "rowNumber", "_workflowActions", "FileURLs"]
          end)

        {:ok, fields}
    end
  end

  defp describe_all(body, schemas) do
    paths = Map.keys(body["paths"] || %{})

    entities =
      paths
      |> Enum.map(fn p -> String.trim_leading(p, "/") end)
      |> Enum.reject(fn p ->
        String.contains?(p, "{") or String.contains?(p, "$") or String.contains?(p, "/")
      end)
      |> Enum.sort()

    actions =
      paths
      |> Enum.filter(fn p ->
        parts = p |> String.trim_leading("/") |> String.split("/")

        length(parts) == 2 and not String.starts_with?(Enum.at(parts, 1), "$") and
          not String.starts_with?(Enum.at(parts, 1), "{")
      end)
      |> Enum.group_by(
        fn p -> p |> String.trim_leading("/") |> String.split("/") |> hd() end,
        fn p -> p |> String.trim_leading("/") |> String.split("/") |> List.last() end
      )

    entity_info =
      Enum.map(entities, fn name ->
        has_schema = Map.has_key?(schemas, name)
        entity_actions = Map.get(actions, name, [])

        %{
          name: name,
          has_schema: has_schema,
          actions: entity_actions,
          field_count:
            if(has_schema, do: schemas[name] |> extract_properties() |> map_size(), else: 0)
        }
      end)

    {:ok, entity_info}
  end

  defp extract_properties(%{"allOf" => parts}) do
    Enum.reduce(parts, %{}, fn
      %{"properties" => props}, acc -> Map.merge(acc, props)
      _, acc -> acc
    end)
  end

  defp extract_properties(%{"properties" => props}), do: props
  defp extract_properties(_), do: %{}

  @type_map %{
    "StringValue" => :string,
    "IntValue" => :integer,
    "ShortValue" => :integer,
    "LongValue" => :integer,
    "DecimalValue" => :decimal,
    "DoubleValue" => :decimal,
    "BooleanValue" => :boolean,
    "DateTimeValue" => :datetime,
    "GuidValue" => :guid,
    "CustomStringField" => :string,
    "CustomIntField" => :integer,
    "CustomDecimalField" => :decimal,
    "CustomBooleanField" => :boolean,
    "CustomDateTimeField" => :datetime,
    "CustomGuidField" => :guid
  }

  defp resolve_field_type(%{"$ref" => ref}, _schemas) do
    type_name = ref |> String.split("/") |> List.last()
    %{type: Map.get(@type_map, type_name, :string), raw_type: type_name}
  end

  defp resolve_field_type(%{"type" => "array", "items" => items}, _schemas) do
    entity =
      case items["$ref"] do
        nil -> "unknown"
        ref -> ref |> String.split("/") |> List.last()
      end

    %{type: :array, entity: entity}
  end

  defp resolve_field_type(%{"type" => type}, _schemas), do: %{type: String.to_atom(type)}
  defp resolve_field_type(spec, _schemas), do: %{type: :unknown, raw: spec}

  # -- Private --

  defp do_paginate(req, entity_name, base_opts, page_size, max_results, skip, acc) do
    remaining =
      case max_results do
        :infinity -> page_size
        n -> min(page_size, n - length(acc))
      end

    if remaining <= 0 do
      {:ok, acc}
    else
      page_opts = base_opts |> Keyword.put(:top, remaining) |> Keyword.put(:skip, skip)

      case list(req, entity_name, page_opts) do
        {:ok, []} ->
          {:ok, acc}

        {:ok, rows} ->
          acc = acc ++ rows
          last_page? = length(rows) < remaining
          hit_cap? = max_results != :infinity and length(acc) >= max_results

          if last_page? or hit_cap? do
            {:ok, acc}
          else
            do_paginate(
              req,
              entity_name,
              base_opts,
              page_size,
              max_results,
              skip + length(rows),
              acc
            )
          end

        {:error, _} = error ->
          error
      end
    end
  end

  defp build_params(opts) do
    Enum.reduce(opts, [], fn
      {:filter, value}, acc -> [{"$filter", value} | acc]
      {:top, value}, acc -> [{"$top", to_string(value)} | acc]
      {:skip, value}, acc -> [{"$skip", to_string(value)} | acc]
      {:select, value}, acc -> [{"$select", value} | acc]
      {:expand, value}, acc -> [{"$expand", value} | acc]
      {:custom_fields, value}, acc -> [{"$custom", value} | acc]
      {:custom, value}, acc -> [{value, nil} | acc]
      _, acc -> acc
    end)
  end

  defp error_from_response(%Req.Response{status: status, body: body}) when is_map(body) do
    message =
      body["exceptionMessage"] ||
        body["Message"] ||
        get_in(body, ["error", "message"]) ||
        inspect(body)

    %ReqAcumatica.Error{status: status, message: message}
  end

  defp error_from_response(%Req.Response{status: status, body: body}) do
    %ReqAcumatica.Error{status: status, message: inspect(body)}
  end
end
