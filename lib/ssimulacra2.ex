defmodule Ssimulacra2 do
  @moduledoc """
  SSIMULACRA2 perceptual image-quality metric for Elixir, backed by the
  `fast-ssim2` Rust crate.

  Inputs are packed 8-bit sRGB `RGB888` binaries (`byte_size == width * height * 3`).
  The returned score is the native SSIMULACRA2 value on a 0–100 scale: 100 is
  pixel-identical, ~90+ is visually lossless, and low/negative values indicate
  large perceptual differences.
  """

  alias Ssimulacra2.Native

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
    with :ok <- validate_dims(width, height),
         :ok <- validate_size(reference, width, height),
         :ok <- validate_size(distorted, width, height) do
      Native.compare(reference, distorted, width, height)
      |> map_native_error()
    end
  end

  @doc false
  def validate_dims(width, height)
      when is_integer(width) and is_integer(height) and width > 0 and height > 0,
      do: :ok

  def validate_dims(_, _), do: {:error, :invalid_dimensions}

  @doc false
  def validate_size(bin, width, height) do
    if byte_size(bin) == width * height * 3, do: :ok, else: {:error, :size_mismatch}
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
