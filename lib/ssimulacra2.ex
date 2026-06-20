defmodule Ssimulacra2 do
  @moduledoc """
  SSIMULACRA2 perceptual image-quality metric for Elixir, backed by the
  `fast-ssim2` Rust crate.

  Inputs are packed binaries whose layout is chosen with the `:format` option
  (default `:rgb888`). The score is on the native SSIMULACRA2 0–100 scale: 100
  is pixel-identical, ~90+ is visually lossless, and low/negative values
  indicate large perceptual differences.

  ## Formats

  | format | element | channels | bytes/pixel | color space |
  | --- | --- | --- | --- | --- |
  | `:rgb888` (default) | `u8` | 3 | 3 | sRGB (gamma) |
  | `:rgb16` | `u16` | 3 | 6 | sRGB (gamma) |
  | `:linear_rgb` | `f32` | 3 | 12 | linear RGB |
  | `:gray8` | `u8` | 1 | 1 | sRGB grayscale |
  | `:linear_gray` | `f32` | 1 | 4 | linear grayscale |

  Convention: integer elements are sRGB (gamma-encoded); float elements are
  linear RGB. Grayscale is expanded to RGB (R=G=B). Multi-byte elements
  (`u16`, `f32`) are **native-endian** — e.g. `<<v::native-16>>` /
  `<<v::native-float-32>>`. A binary's size must equal
  `width * height * channels * bytes_per_element` for its format.
  """

  alias Ssimulacra2.{Native, Validate}

  @type image_data :: binary()
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
  @spec compare(image_data(), image_data(), pos_integer(), pos_integer(), keyword()) ::
          {:ok, float()} | {:error, reason()}
  def compare(reference, distorted, width, height, opts \\ [])
      when is_binary(reference) and is_binary(distorted) do
    format = Keyword.get(opts, :format, :rgb888)

    with :ok <- Validate.format(format),
         :ok <- Validate.dims(width, height),
         :ok <- Validate.size(reference, width, height, format),
         :ok <- Validate.size(distorted, width, height, format) do
      Native.compare(reference, distorted, width, height, format, nil)
      |> map_native_error()
    end
  end

  @doc """
  Like `compare/5` but returns the bare score and raises `Ssimulacra2.Error`
  on failure. Accepts the same `format:` option, defaulting to `:rgb888`.
  """
  @spec compare!(image_data(), image_data(), pos_integer(), pos_integer(), keyword()) :: float()
  def compare!(reference, distorted, width, height, opts \\ []) do
    case compare(reference, distorted, width, height, opts) do
      {:ok, score} -> score
      {:error, reason} -> raise Ssimulacra2.Error, reason: reason
    end
  end

  defp map_native_error({:ok, score}), do: {:ok, score}
  defp map_native_error({:error, :cancelled}), do: {:error, :cancelled}
  defp map_native_error({:error, {:failed, message}}), do: {:error, {:ssimulacra2, message}}
end
