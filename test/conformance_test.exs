defmodule Ssimulacra2.ConformanceTest do
  use ExUnit.Case, async: true

  @moduletag :conformance

  @fixtures_dir Path.join([__DIR__, "fixtures", "conformance"])
  @expected Path.join(@fixtures_dir, "expected.json")

  # Tolerance is set from the measured max deviation (see docs/conformance-plan.md).
  # Start strict; widen only with a documented, investigated reason.
  @tolerance 0.5

  test "matches Cloudinary reference scores within tolerance" do
    unless File.exists?(@expected) do
      flunk("""
      Conformance fixtures not found at #{@expected}.
      Generate them per docs/conformance-plan.md before running this test.
      """)
    end

    cases = @expected |> File.read!() |> :json.decode()

    for %{"ref" => ref, "dist" => dist, "score" => expected} <- cases do
      {:ok, ref_rgb, w, h} = load_rgb888(Path.join(@fixtures_dir, ref))
      {:ok, dist_rgb, ^w, ^h} = load_rgb888(Path.join(@fixtures_dir, dist))
      {:ok, score} = Ssimulacra2.compare(ref_rgb, dist_rgb, w, h)

      assert_in_delta score, expected, @tolerance,
        "#{ref} vs #{dist}: got #{score}, expected #{expected}"
    end
  end

  # Decode a PNG to packed RGB888 using Vix (test-only dependency path).
  defp load_rgb888(path) do
    alias Vix.Vips.{Image, Operation}
    {:ok, img} = Image.new_from_file(path)
    srgb = Operation.colourspace!(img, :VIPS_INTERPRETATION_sRGB)
    flat = if Image.has_alpha?(srgb), do: Operation.flatten!(srgb), else: srgb
    rgb = Operation.cast!(flat, :VIPS_FORMAT_UCHAR)
    {:ok, bin} = Image.write_to_binary(rgb)
    {:ok, bin, Image.width(rgb), Image.height(rgb)}
  end
end
