defmodule Ssimulacra2.Reference do
  @moduledoc """
  A precomputed SSIMULACRA2 reference image for efficient batch comparison.

  Build one with `new/4` (optionally passing a `format:` — see `Ssimulacra2`
  for the supported formats; default `:rgb888`), then call `compare/2`
  repeatedly against candidate images of the same dimensions and format. This
  reuses the reference's internal pyramid and is roughly twice as fast per
  comparison as `Ssimulacra2.compare/5` — ideal for a quality-search loop
  comparing many encodings against one original.
  """

  alias Ssimulacra2.{Cancellation, Native, Validate}

  @enforce_keys [:resource, :width, :height, :format]
  defstruct [:resource, :width, :height, :format]

  @type t :: %__MODULE__{
          resource: reference(),
          width: pos_integer(),
          height: pos_integer(),
          format: atom()
        }

  @doc "Precompute a reference from a packed binary of the given format (default :rgb888)."
  @spec new(Ssimulacra2.image_data(), pos_integer(), pos_integer(), keyword()) ::
          {:ok, t()} | {:error, Ssimulacra2.reason()}
  def new(source, width, height, opts \\ []) when is_binary(source) do
    format = Keyword.get(opts, :format, :rgb888)

    with :ok <- Validate.format(format),
         :ok <- Validate.dims(width, height),
         :ok <- Validate.size(source, width, height, format),
         {:ok, resource} <- map_native(Native.reference_new(source, width, height, format)) do
      {:ok, %__MODULE__{resource: resource, width: width, height: height, format: format}}
    end
  end

  @doc """
  Compare a candidate against the precomputed reference (same format as the
  reference).

  Accepts `cancel:` (an `Ssimulacra2.CancellationToken`) and `timeout:`
  (milliseconds) to abort an in-flight comparison; see `Ssimulacra2.compare/5`.
  Returns `{:error, :cancelled}` or `{:error, :timeout}` respectively.
  """
  @spec compare(t(), Ssimulacra2.image_data(), keyword()) ::
          {:ok, float()} | {:error, Ssimulacra2.reason()}
  def compare(%__MODULE__{} = ref, distorted, opts \\ []) when is_binary(distorted) do
    cancel = Keyword.get(opts, :cancel)

    with :ok <- Validate.size(distorted, ref.width, ref.height, ref.format),
         :ok <- Validate.cancel(cancel) do
      Cancellation.run(cancel, nil, fn resource ->
        Native.reference_compare(ref.resource, distorted, ref.width, ref.height, ref.format, resource)
      end)
    end
  end

  @doc "Like `new/4` but returns the reference or raises `Ssimulacra2.Error`."
  @spec new!(Ssimulacra2.image_data(), pos_integer(), pos_integer(), keyword()) :: t()
  def new!(source, width, height, opts \\ []) do
    case new(source, width, height, opts) do
      {:ok, ref} -> ref
      {:error, reason} -> raise Ssimulacra2.Error, reason: reason
    end
  end

  @doc "Like `compare/3` but returns the bare score or raises `Ssimulacra2.Error`."
  @spec compare!(t(), Ssimulacra2.image_data(), keyword()) :: float()
  def compare!(%__MODULE__{} = ref, distorted, opts \\ []) do
    case compare(ref, distorted, opts) do
      {:ok, score} -> score
      {:error, reason} -> raise Ssimulacra2.Error, reason: reason
    end
  end

  defp map_native({:ok, value}), do: {:ok, value}
  defp map_native({:error, message}) when is_binary(message), do: {:error, {:ssimulacra2, message}}
end
