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
          :invalid_dimensions | :size_mismatch | :dimension_mismatch | {:ssimulacra2, String.t()}

  @doc """
  Compare a reference and distorted RGB888 image of the same dimensions.

  Returns `{:ok, score}` or `{:error, reason}`.
  """
  @spec compare(rgb888(), rgb888(), pos_integer(), pos_integer()) ::
          {:ok, float()} | {:error, reason()}
  def compare(reference, distorted, width, height)
      when is_binary(reference) and is_binary(distorted) do
    with :ok <- Validate.dims(width, height),
         :ok <- Validate.size(reference, width, height),
         :ok <- Validate.size(distorted, width, height) do
      Native.compare(reference, distorted, width, height, :rgb888)
      |> map_native_error()
    end
  end

  @doc """
  Like `compare/4` but returns the bare score and raises `Ssimulacra2.Error`
  on failure.
  """
  @spec compare!(rgb888(), rgb888(), pos_integer(), pos_integer()) :: float()
  def compare!(reference, distorted, width, height) do
    case compare(reference, distorted, width, height) do
      {:ok, score} -> score
      {:error, reason} -> raise Ssimulacra2.Error, reason: reason
    end
  end

  defp map_native_error({:ok, score}), do: {:ok, score}
  defp map_native_error({:error, message}), do: {:error, {:ssimulacra2, message}}
end
