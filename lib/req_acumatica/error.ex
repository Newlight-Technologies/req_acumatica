defmodule ReqAcumatica.Error do
  @moduledoc """
  Error struct for Acumatica API errors.
  """

  defexception [:status, :message]

  @type t :: %__MODULE__{
          status: integer() | nil,
          message: String.t()
        }

  @impl true
  def message(%__MODULE__{status: nil, message: msg}), do: msg
  def message(%__MODULE__{status: status, message: msg}), do: "HTTP #{status}: #{msg}"
end
