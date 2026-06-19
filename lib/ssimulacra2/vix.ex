if Code.ensure_loaded?(Vix.Vips.Image) do
  defmodule Ssimulacra2.Vix do
    @moduledoc """
    Convenience wrappers that accept `Vix.Vips.Image` structs.

    Only compiled when the optional `:vix` dependency is available. Images are
    coerced to 8-bit, 3-band sRGB (alpha flattened) before extraction, then
    handed to the core API as a packed RGB888 binary.
    """

    alias Vix.Vips.{Image, Operation}

    @doc "Compare two Vix images with `Ssimulacra2.compare/4`."
    @spec compare(Image.t(), Image.t()) :: {:ok, float()} | {:error, term()}
    def compare(%Image{} = reference, %Image{} = distorted) do
      with {:ok, {ref_bin, w, h}} <- to_rgb888(reference),
           {:ok, {dist_bin, ^w, ^h}} <- to_rgb888(distorted) do
        Ssimulacra2.compare(ref_bin, dist_bin, w, h)
      else
        {:ok, {_bin, _w2, _h2}} -> {:error, :dimension_mismatch}
        other -> other
      end
    end

    @doc "Build a `Ssimulacra2.Reference` from a Vix image."
    @spec reference(Image.t()) :: {:ok, Ssimulacra2.Reference.t()} | {:error, term()}
    def reference(%Image{} = image) do
      with {:ok, {bin, w, h}} <- to_rgb888(image) do
        Ssimulacra2.Reference.new(bin, w, h)
      end
    end

    # Coerce to sRGB, drop alpha, cast to 8-bit, extract packed RGB888.
    defp to_rgb888(%Image{} = image) do
      srgb = Operation.colourspace!(image, :VIPS_INTERPRETATION_sRGB)
      flat = if Image.has_alpha?(srgb), do: Operation.flatten!(srgb), else: srgb
      rgb = Operation.cast!(flat, :VIPS_FORMAT_UCHAR)

      case Image.write_to_binary(rgb) do
        {:ok, bin} -> {:ok, {bin, Image.width(rgb), Image.height(rgb)}}
        {:error, reason} -> {:error, reason}
      end
    end
  end
end
