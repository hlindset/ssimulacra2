defmodule Ssimulacra2.FormatsTest do
  use ExUnit.Case, async: true
  alias Ssimulacra2.Fixtures

  @dim 64

  # {format, reference binary, a visibly different binary}
  @cases [
    {:rgb16, Fixtures.gradient_rgb16(@dim, @dim),
     Fixtures.solid_rgb16(@dim, @dim, {40_000, 20_000, 10_000})},
    {:linear_rgb, Fixtures.gradient_linear_rgb(@dim, @dim),
     Fixtures.solid_linear_rgb(@dim, @dim, 0.5)},
    {:gray8, Fixtures.gradient_gray8(@dim, @dim), Fixtures.solid_gray8(@dim, @dim, 128)},
    {:linear_gray, Fixtures.gradient_linear_gray(@dim, @dim),
     Fixtures.solid_linear_gray(@dim, @dim, 0.5)}
  ]

  for {fmt, ref_bin, alt_bin} <- @cases do
    @fmt fmt
    @ref_bin ref_bin
    @alt_bin alt_bin

    describe "format #{fmt}" do
      test "identical images score ~100" do
        assert {:ok, s} = Ssimulacra2.compare(@ref_bin, @ref_bin, @dim, @dim, format: @fmt)
        assert s > 99.0
      end

      test "different images score lower than identical" do
        {:ok, same} = Ssimulacra2.compare(@ref_bin, @ref_bin, @dim, @dim, format: @fmt)
        {:ok, diff} = Ssimulacra2.compare(@ref_bin, @alt_bin, @dim, @dim, format: @fmt)
        assert diff < same
      end

      test "rejects a wrong-size binary" do
        assert {:error, :size_mismatch} =
                 Ssimulacra2.compare(@ref_bin, <<0, 1, 2>>, @dim, @dim, format: @fmt)
      end
    end
  end

  test "unknown format is rejected" do
    img = Fixtures.gradient_rgb16(8, 8)
    assert {:error, :unknown_format} = Ssimulacra2.compare(img, img, 8, 8, format: :bogus)
  end

  test "default format is :rgb888" do
    img = Fixtures.gradient(64, 64)
    assert {:ok, with_opt} = Ssimulacra2.compare(img, img, 64, 64, format: :rgb888)
    assert {:ok, default} = Ssimulacra2.compare(img, img, 64, 64)
    assert with_opt == default
  end

  # A 1-byte prefix makes binary_part return a sub-binary at a misaligned byte
  # offset, which would panic bytemuck::cast_slice for u16/f32 element types.
  defp misaligned(bin), do: binary_part(<<0>> <> bin, 1, byte_size(bin))

  test "scores an unaligned :rgb16 sub-binary without crashing" do
    base = Fixtures.gradient_rgb16(16, 16)
    shifted = misaligned(base)
    assert byte_size(shifted) == byte_size(base)
    assert {:ok, s} = Ssimulacra2.compare(shifted, shifted, 16, 16, format: :rgb16)
    assert s > 99.0
  end

  test "scores an unaligned :linear_rgb sub-binary without crashing" do
    base = Fixtures.gradient_linear_rgb(16, 16)
    shifted = misaligned(base)
    assert byte_size(shifted) == byte_size(base)
    assert {:ok, s} = Ssimulacra2.compare(shifted, shifted, 16, 16, format: :linear_rgb)
    assert s > 99.0
  end
end
