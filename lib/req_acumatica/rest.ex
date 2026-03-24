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
          | {:custom, String.t()}

  @doc """
  Retrieves a list of entities.

  ## Options

    * `:filter` — OData `$filter` expression
    * `:top` — maximum number of results
    * `:skip` — number of results to skip
    * `:select` — comma-separated field names to return
    * `:expand` — related entities to include (e.g. `"Details"`)
    * `:custom` — custom query string to append verbatim
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

  @doc """
  Describes an entity's schema by fetching type information from the swagger spec.

  Returns a map of field names to their types and metadata, including nested
  detail entities (arrays).

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

  defp build_params(opts) do
    Enum.reduce(opts, [], fn
      {:filter, value}, acc -> [{"$filter", value} | acc]
      {:top, value}, acc -> [{"$top", to_string(value)} | acc]
      {:skip, value}, acc -> [{"$skip", to_string(value)} | acc]
      {:select, value}, acc -> [{"$select", value} | acc]
      {:expand, value}, acc -> [{"$expand", value} | acc]
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
