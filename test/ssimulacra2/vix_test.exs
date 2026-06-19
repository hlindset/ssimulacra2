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
