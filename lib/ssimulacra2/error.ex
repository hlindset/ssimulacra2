defmodule Ssimulacra2.Error do
  @moduledoc "Raised by the `!` variants when a comparison fails."
  defexception [:reason]

  @impl true
  def message(%__MODULE__{reason: reason}) do
    "ssimulacra2 comparison failed: #{inspect(reason)}"
  end
end
