defmodule ReqAcumatica.Result do
  @moduledoc """
  Parsed result from an Acumatica OData query.

  Contains the rows returned by the Generic Inquiry along with
  optional metadata like total count and next link for pagination.
  """

  defstruct [:rows, :count, :next_link, :raw]

  @type t :: %__MODULE__{
          rows: [map()],
          count: non_neg_integer() | nil,
          next_link: String.t() | nil,
          raw: map() | nil
        }

  @doc """
  Parses an OData JSON response body into a `Result` struct.

  Handles both OData v3 (`d.results`) and v4 (`value`) response formats,
  as Acumatica may use either depending on the endpoint configuration.
  """
  @spec from_odata_response(map() | String.t()) :: t()
  def from_odata_response(body) when is_binary(body) do
    case Jason.decode(body) do
      {:ok, parsed} -> from_odata_response(parsed)
      {:error, _} -> %__MODULE__{rows: [], count: 0, raw: body}
    end
  end

  # OData v4 format: {"value": [...], "@odata.count": N, "@odata.nextLink": "..."}
  def from_odata_response(%{"value" => rows} = body) when is_list(rows) do
    %__MODULE__{
      rows: rows,
      count: Map.get(body, "@odata.count") || length(rows),
      next_link: Map.get(body, "@odata.nextLink"),
      raw: body
    }
  end

  # OData v3 format: {"d": {"results": [...]}}
  def from_odata_response(%{"d" => %{"results" => rows}} = body) when is_list(rows) do
    %__MODULE__{
      rows: rows,
      count: length(rows),
      next_link: get_in(body, ["d", "__next"]),
      raw: body
    }
  end

  # OData v3 without "results" wrapper: {"d": [...]}
  def from_odata_response(%{"d" => rows} = body) when is_list(rows) do
    %__MODULE__{
      rows: rows,
      count: length(rows),
      next_link: nil,
      raw: body
    }
  end

  # Fallback — response may be a plain list
  def from_odata_response(rows) when is_list(rows) do
    %__MODULE__{
      rows: rows,
      count: length(rows),
      next_link: nil,
      raw: nil
    }
  end

  def from_odata_response(body) do
    %__MODULE__{
      rows: [],
      count: 0,
      next_link: nil,
      raw: body
    }
  end
end
