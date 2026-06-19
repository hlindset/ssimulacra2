defmodule Ssimulacra2 do
  @moduledoc """
  SSIMULACRA2 perceptual image-quality metric for Elixir, backed by the
  `fast-ssim2` Rust crate.

  Inputs are packed 8-bit sRGB `RGB888` binaries (`byte_size == width * height * 3`).
  The returned score is the native SSIMULACRA2 value on a 0–100 scale: 100 is
  pixel-identical, ~90+ is visually lossless, and low/negative values indicate
  large perceptual differences.
  """

  alias Ssimulacra2.{Native, Validate}

  @type rgb888 :: binary()
  @type reason ::
          :invalid_dimensions
          | :size_mismatch
          | :dimension_mismatch
          | :unknown_format
          | {:ssimulacra2, String.t()}

  @doc """
  Compare a reference and distorted image of the same dimensions.

  Pass `format:` to select the packed pixel layout; it defaults to `:rgb888`
  (packed 8-bit sRGB, `byte_size == width * height * 3`). Other supported
  formats are `:rgb16`, `:linear_rgb`, `:gray8`, and `:linear_gray`.

  Returns `{:ok, score}` or `{:error, reason}`.
  """
  @spec compare(rgb888(), rgb888(), pos_integer(), pos_integer(), keyword()) ::
          {:ok, float()} | {:error, reason()}
  def compare(reference, distorted, width, height, opts \\ [])
      when is_binary(reference) and is_binary(distorted) do
    format = Keyword.get(opts, :format, :rgb888)

    with :ok <- Validate.format(format),
         :ok <- Validate.dims(width, height),
         :ok <- Validate.size(reference, width, height, format),
         :ok <- Validate.size(distorted, width, height, format) do
      Native.compare(reference, distorted, width, height, format)
      |> map_native_error()
    end
  end

  @doc """
  Like `compare/4` but returns the bare score and raises `Ssimulacra2.Error`
  on failure. Accepts the same `format:` option, defaulting to `:rgb888`.
  """
  @spec compare!(rgb888(), rgb888(), pos_integer(), pos_integer(), keyword()) :: float()
  def compare!(reference, distorted, width, height, opts \\ []) do
    case compare(reference, distorted, width, height, opts) do
      {:ok, score} -> score
      {:error, reason} -> raise Ssimulacra2.Error, reason: reason
    end
  end

  defp map_native_error({:ok, score}), do: {:ok, score}
  defp map_native_error({:error, message}), do: {:error, {:ssimulacra2, message}}
end
