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

  def run(cancel, timeout, invoke) when is_integer(timeout) and timeout > 0 do
    token = cancel || CancellationToken.new()
    parent = self()
    tag = make_ref()

    # The caller blocks in the dirty NIF and cannot clean up while parked there,
    # so the canceller is wired with mutual monitoring: it exits if the parent
    # dies mid-NIF (no orphan living for the full timeout), and the parent's
    # status receive can't block forever if the canceller dies abnormally.
    {canceller, cref} =
      spawn_monitor(fn ->
        parent_ref = Process.monitor(parent)

        receive do
          {:done, ^tag} -> send(parent, {:status, tag, :not_timed_out})
          {:DOWN, ^parent_ref, :process, ^parent, _} -> :ok
        after
          timeout ->
            CancellationToken.cancel(token)
            send(parent, {:status, tag, :timed_out})
        end
      end)

    result = invoke.(token.resource)
    send(canceller, {:done, tag})

    status =
      receive do
        {:status, ^tag, s} -> s
        {:DOWN, ^cref, :process, _, _} -> :not_timed_out
      end

    Process.demonitor(cref, [:flush])
    map_result(result, status)
  end

  defp token_resource(%CancellationToken{resource: r}), do: r
  defp token_resource(nil), do: nil

  defp map_result({:ok, score}, _status), do: {:ok, score}
  defp map_result({:error, :cancelled}, :timed_out), do: {:error, :timeout}
  defp map_result({:error, :cancelled}, _status), do: {:error, :cancelled}
  defp map_result({:error, {:failed, message}}, _status), do: {:error, {:ssimulacra2, message}}
end
