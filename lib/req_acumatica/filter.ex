defmodule ReqAcumatica.Filter do
  @moduledoc """
  Builder DSL for constructing OData `$filter` expressions.

  Provides a composable, type-safe way to build filter strings
  instead of hand-writing OData filter syntax.

  ## Examples

      import ReqAcumatica.Filter

      # Simple equality
      filter = eq("Status", "Open")
      # => "Status eq 'Open'"

      # Compound filters
      filter =
        eq("Status", "Open")
        |> and_filter(gt("OrderTotal", 1000))
        |> and_filter(contains("CustomerName", "Newlight"))
      # => "Status eq 'Open' and OrderTotal gt 1000 and contains(CustomerName, 'Newlight')"

      # Use in a query
      ReqAcumatica.query(client, "Sales Orders", filter: to_string(filter))
  """

  defstruct [:expression]

  @type t :: %__MODULE__{expression: String.t()}

  # -- Comparison operators --

  @doc "Equals: `field eq value`"
  @spec eq(String.t(), term()) :: t()
  def eq(field, value), do: %__MODULE__{expression: "#{field} eq #{encode_value(value)}"}

  @doc "Not equals: `field ne value`"
  @spec ne(String.t(), term()) :: t()
  def ne(field, value), do: %__MODULE__{expression: "#{field} ne #{encode_value(value)}"}

  @doc "Greater than: `field gt value`"
  @spec gt(String.t(), term()) :: t()
  def gt(field, value), do: %__MODULE__{expression: "#{field} gt #{encode_value(value)}"}

  @doc "Greater than or equal: `field ge value`"
  @spec ge(String.t(), term()) :: t()
  def ge(field, value), do: %__MODULE__{expression: "#{field} ge #{encode_value(value)}"}

  @doc "Less than: `field lt value`"
  @spec lt(String.t(), term()) :: t()
  def lt(field, value), do: %__MODULE__{expression: "#{field} lt #{encode_value(value)}"}

  @doc "Less than or equal: `field le value`"
  @spec le(String.t(), term()) :: t()
  def le(field, value), do: %__MODULE__{expression: "#{field} le #{encode_value(value)}"}

  # -- String functions --

  @doc "Contains: `contains(field, 'value')`"
  @spec contains(String.t(), String.t()) :: t()
  def contains(field, value),
    do: %__MODULE__{expression: "contains(#{field}, '#{escape_string(value)}')"}

  @doc "Starts with: `startswith(field, 'value')`"
  @spec startswith(String.t(), String.t()) :: t()
  def startswith(field, value),
    do: %__MODULE__{expression: "startswith(#{field}, '#{escape_string(value)}')"}

  @doc "Ends with: `endswith(field, 'value')`"
  @spec endswith(String.t(), String.t()) :: t()
  def endswith(field, value),
    do: %__MODULE__{expression: "endswith(#{field}, '#{escape_string(value)}')"}

  # -- Logical combinators --

  @doc "Combines two filters with `and`."
  @spec and_filter(t(), t()) :: t()
  def and_filter(%__MODULE__{expression: left}, %__MODULE__{expression: right}),
    do: %__MODULE__{expression: "#{left} and #{right}"}

  @doc "Combines two filters with `or`."
  @spec or_filter(t(), t()) :: t()
  def or_filter(%__MODULE__{expression: left}, %__MODULE__{expression: right}),
    do: %__MODULE__{expression: "(#{left}) or (#{right})"}

  @doc "Negates a filter with `not`."
  @spec not_filter(t()) :: t()
  def not_filter(%__MODULE__{expression: expr}),
    do: %__MODULE__{expression: "not (#{expr})"}

  # -- Null checks --

  @doc "Checks if field is null: `field eq null`"
  @spec is_null(String.t()) :: t()
  def is_null(field), do: %__MODULE__{expression: "#{field} eq null"}

  @doc "Checks if field is not null: `field ne null`"
  @spec is_not_null(String.t()) :: t()
  def is_not_null(field), do: %__MODULE__{expression: "#{field} ne null"}

  # -- Conversion --

  @doc "Converts filter to OData filter string."
  @spec to_string(t()) :: String.t()
  def to_string(%__MODULE__{expression: expr}), do: expr

  defimpl String.Chars do
    def to_string(%ReqAcumatica.Filter{expression: expr}), do: expr
  end

  # -- Private helpers --

  defp encode_value(value) when is_binary(value), do: "'#{escape_string(value)}'"
  defp encode_value(value) when is_integer(value), do: Integer.to_string(value)
  defp encode_value(value) when is_float(value), do: Float.to_string(value)
  defp encode_value(true), do: "true"
  defp encode_value(false), do: "false"
  defp encode_value(nil), do: "null"

  defp encode_value(%DateTime{} = dt),
    do: "datetime'#{DateTime.to_iso8601(dt)}'"

  defp encode_value(%Date{} = d),
    do: "datetime'#{Date.to_iso8601(d)}T00:00:00'"

  defp escape_string(value), do: String.replace(value, "'", "''")
end
