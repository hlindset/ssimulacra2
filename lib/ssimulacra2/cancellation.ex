defmodule Ssimulacra2.Cancellation do
  @moduledoc false
  # Shared cancellation/timeout orchestration for compare and Reference.compare.

  alias Ssimulacra2.CancellationToken

  # `invoke` is a 1-arity fun taking the token resource (or nil) and returning
  # the raw native result: {:ok, score} | {:error, :cancelled}
  #                                       | {:error, {:failed, msg}}.
  @spec run(CancellationToken.t() | nil, pos_integer() | nil, (reference() | nil -> term())) ::
          {:ok, float()}
          | {:error, :cancelled | :timeout | {:ssimulacra2, String.t()}}
  def run(cancel, nil, invoke) do
    resource = token_resource(cancel)
    invoke.(resource) |> map_result(:not_timed_out)
  end

  defp token_resource(%CancellationToken{resource: r}), do: r
  defp token_resource(nil), do: nil

  defp map_result({:ok, score}, _status), do: {:ok, score}
  defp map_result({:error, :cancelled}, _status), do: {:error, :cancelled}
  defp map_result({:error, {:failed, message}}, _status), do: {:error, {:ssimulacra2, message}}
end
