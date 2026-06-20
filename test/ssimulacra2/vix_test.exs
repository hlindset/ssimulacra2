defmodule Ssimulacra2.VixTest do
  use ExUnit.Case, async: true

  @moduletag :vix

  alias Vix.Vips.{Image, Operation}

  test "compare/2 scores identical Vix images ~100" do
    {:ok, img} = Image.new_from_buffer(black_png())
    assert {:ok, score} = Ssimulacra2.Vix.compare(img, img)
    assert score > 99.0
  end

  test "reference/1 builds a Reference usable with Reference.compare/2" do
    {:ok, img} = Image.new_from_buffer(black_png())
    assert {:ok, %Ssimulacra2.Reference{} = ref} = Ssimulacra2.Vix.reference(img)
    {:ok, bin} = Image.write_to_binary(rgb888(img))
    assert {:ok, score} = Ssimulacra2.Reference.compare(ref, bin)
    assert score > 99.0
  end

  test "a 16-bit source yields a :rgb16 reference (bit depth preserved)" do
    bin = gradient_rgb888(64, 64)
    {:ok, img8} = Image.new_from_binary(bin, 64, 64, 3, :VIPS_FORMAT_UCHAR)
    img8 = Operation.copy!(img8, interpretation: :VIPS_INTERPRETATION_sRGB)

    img16 =
      img8
      |> Operation.linear!([257.0], [0.0])
      |> Operation.cast!(:VIPS_FORMAT_USHORT)
      |> Operation.copy!(interpretation: :VIPS_INTERPRETATION_RGB16)

    assert {:ok, ref} = Ssimulacra2.Vix.reference(img16)
    assert ref.format == :rgb16
  end

  test "an 8-bit source yields a :rgb888 reference" do
    {:ok, img8} = Image.new_from_buffer(black_png())
    assert {:ok, ref} = Ssimulacra2.Vix.reference(img8)
    assert ref.format == :rgb888
  end

  test "16-bit and equivalent 8-bit content reconcile without clipping" do
    bin = gradient_rgb888(64, 64)
    {:ok, img8} = Image.new_from_binary(bin, 64, 64, 3, :VIPS_FORMAT_UCHAR)
    img8 = Operation.copy!(img8, interpretation: :VIPS_INTERPRETATION_sRGB)

    # Same content scaled into the full 16-bit range. Both sides are routed
    # through the 16-bit path; the score must stay high (no 8-bit clamp).
    img16 =
      img8
      |> Operation.linear!([257.0], [0.0])
      |> Operation.cast!(:VIPS_FORMAT_USHORT)
      |> Operation.copy!(interpretation: :VIPS_INTERPRETATION_RGB16)

    assert {:ok, score} = Ssimulacra2.Vix.compare(img16, img8)
    assert score > 90.0
  end

  test "compare/2 reuses a precomputed reference against a Vix candidate" do
    bin = gradient_rgb888(64, 64)
    {:ok, img8} = Image.new_from_binary(bin, 64, 64, 3, :VIPS_FORMAT_UCHAR)
    img8 = Operation.copy!(img8, interpretation: :VIPS_INTERPRETATION_sRGB)

    {:ok, ref} = Ssimulacra2.Vix.reference(img8)

    # Identical candidate against the reference scores ~100.
    assert {:ok, identical} = Ssimulacra2.Vix.compare(ref, img8)
    assert identical > 99.0

    # A lightly degraded candidate beats a heavily degraded one.
    light = Operation.gaussblur!(img8, 0.5)
    heavy = Operation.gaussblur!(img8, 3.0)
    assert {:ok, light_score} = Ssimulacra2.Vix.compare(ref, light)
    assert {:ok, heavy_score} = Ssimulacra2.Vix.compare(ref, heavy)
    assert light_score > heavy_score

    # The precompute path matches the rebuild-every-call path within epsilon.
    assert {:ok, pair_score} = Ssimulacra2.Vix.compare(img8, heavy)
    assert_in_delta heavy_score, pair_score, 0.01
  end

  # A deterministic gradient RGB888 binary (varies per pixel).
  defp gradient_rgb888(width, height) do
    for y <- 0..(height - 1), x <- 0..(width - 1), into: <<>> do
      <<rem(x, 256), rem(y, 256), rem(x + y, 256)>>
    end
  end

  # Flatten a (possibly RGBA) Vix image to a packed 8-bit, 3-band sRGB image,
  # matching the packed RGB888 binary that the core API expects.
  defp rgb888(img) do
    img
    |> Operation.colourspace!(:VIPS_INTERPRETATION_sRGB)
    |> Operation.flatten!()
    |> Operation.cast!(:VIPS_FORMAT_UCHAR)
  end

  # A 4x4 black PNG.
  defp black_png do
    Base.decode64!(
      "iVBORw0KGgoAAAANSUhEUgAAAAQAAAAECAYAAACp8Z5+AAAAEUlEQVR4nGNgYGD4z0AkYBxVCAAxAQH/JLAB+QAAAABJRU5ErkJggg=="
    )
  end
end
