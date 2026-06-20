if Code.ensure_loaded?(Vix.Vips.Image) do
  defmodule Ssimulacra2.Vix do
    @moduledoc """
    Convenience wrappers that accept `Vix.Vips.Image` structs.

    Only compiled when the optional `:vix` dependency is available. 8-bit
    sources are coerced to 8-bit sRGB (`:rgb888`); higher-bit-depth sources are
    preserved as 16-bit sRGB (`:rgb16`). Alpha is flattened in both cases.
    """

    alias Vix.Vips.{Image, Operation}

    @doc """
    Compare a Vix candidate against a reference.

    Given two `Image.t()`s, the reference pyramid is rebuilt every call. Given a
    precomputed `Ssimulacra2.Reference` as the first argument, it is reused
    against the candidate — coerce the candidate to the reference's format and
    compare. Use the precompute form when comparing many candidates against one
    original.
    """
    @spec compare(Image.t(), Image.t()) :: {:ok, float()} | {:error, term()}
    @spec compare(Ssimulacra2.Reference.t(), Image.t()) :: {:ok, float()} | {:error, term()}
    def compare(reference, distorted)

    def compare(%Image{} = reference, %Image{} = distorted) do
      format = pair_format(reference, distorted)

      with {:ok, {ref_bin, w, h}} <- coerce(reference, format),
           {:ok, {dist_bin, ^w, ^h}} <- coerce(distorted, format) do
        Ssimulacra2.compare(ref_bin, dist_bin, w, h, format: format)
      else
        {:ok, {_bin, _w2, _h2}} -> {:error, :dimension_mismatch}
        other -> other
      end
    end

    def compare(%Ssimulacra2.Reference{format: format} = reference, %Image{} = distorted) do
      with {:ok, {bin, _w, _h}} <- coerce(distorted, format) do
        Ssimulacra2.Reference.compare(reference, bin)
      end
    end

    @doc "Build a `Ssimulacra2.Reference` from a Vix image, preserving bit depth."
    @spec reference(Image.t()) :: {:ok, Ssimulacra2.Reference.t()} | {:error, term()}
    def reference(%Image{} = image) do
      format = image_format(image)

      with {:ok, {bin, w, h}} <- coerce(image, format) do
        Ssimulacra2.Reference.new(bin, w, h, format: format)
      end
    end

    # 8-bit (UCHAR) sources stay 8-bit; anything else is treated as 16-bit.
    defp image_format(%Image{} = image) do
      if Image.format(image) == :VIPS_FORMAT_UCHAR, do: :rgb888, else: :rgb16
    end

    # When comparing a pair, if either side is higher than 8-bit, both go 16-bit.
    defp pair_format(a, b) do
      if image_format(a) == :rgb888 and image_format(b) == :rgb888,
        do: :rgb888,
        else: :rgb16
    end

    # Coerce to the target format: sRGB primaries, alpha flattened, packed binary.
    defp coerce(%Image{} = image, :rgb888),
      do: do_coerce(image, :VIPS_INTERPRETATION_sRGB, :VIPS_FORMAT_UCHAR)

    defp coerce(%Image{} = image, :rgb16),
      do: do_coerce(image, :VIPS_INTERPRETATION_RGB16, :VIPS_FORMAT_USHORT)

    defp do_coerce(image, interpretation, band_format) do
      colour = Operation.colourspace!(image, interpretation)
      flat = if Image.has_alpha?(colour), do: Operation.flatten!(colour), else: colour
      cast = Operation.cast!(flat, band_format)

      case Image.write_to_binary(cast) do
        {:ok, bin} -> {:ok, {bin, Image.width(cast), Image.height(cast)}}
        {:error, reason} -> {:error, reason}
      end
    end
  end
end
