defmodule Ssimulacra2.CancellationToken do
  @moduledoc """
  A cancellation token for aborting an in-flight `Ssimulacra2.compare/5` or
  `Ssimulacra2.Reference.compare/3`.

  The token is a neutral primitive — *you* assign it meaning. Create one with
  `new/0`, pass it as `cancel: token`, and call `cancel/1` from any process
  (e.g. a client-disconnect monitor or a search deadline) to abort the
  comparison. The aborted call returns `{:error, :cancelled}`.

  A token is **single-use**: once cancelled it stays cancelled. One token can
  cover a whole batch — cancelling it aborts the in-flight comparison and makes
  every subsequent comparison using it return `{:error, :cancelled}` at once.
  """

  alias Ssimulacra2.Native

  @enforce_keys [:resource]
  defstruct [:resource]

  @type t :: %__MODULE__{resource: reference()}

  @doc "Create a fresh, live (not-yet-cancelled) token."
  @spec new() :: t()
  def new(), do: %__MODULE__{resource: Native.token_new()}

  @doc "Trip the token. Returns `:ok`. Safe to call more than once."
  @spec cancel(t()) :: :ok
  def cancel(%__MODULE__{resource: r}), do: Native.token_cancel(r)
end
