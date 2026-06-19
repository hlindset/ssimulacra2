defmodule Ssimulacra2.ReferenceTest do
  use ExUnit.Case, async: true
  alias Ssimulacra2.{Fixtures, Reference}

  test "new/3 then compare/2 matches one-shot compare/4" do
    ref_img = Fixtures.gradient(64, 64)
    cand = Fixtures.solid(64, 64, {200, 100, 50})

    {:ok, oneshot} = Ssimulacra2.compare(ref_img, cand, 64, 64)
    {:ok, ref} = Reference.new(ref_img, 64, 64)
    {:ok, batch} = Reference.compare(ref, cand)

    assert_in_delta oneshot, batch, 1.0e-4
  end

  test "compare/2 rejects a candidate of the wrong size" do
    {:ok, ref} = Reference.new(Fixtures.gradient(64, 64), 64, 64)
    assert {:error, :size_mismatch} = Reference.compare(ref, Fixtures.solid(32, 32, {0, 0, 0}))
  end

  test "new/3 validates dimensions and size" do
    assert {:error, :invalid_dimensions} = Reference.new(<<>>, 0, 0)
    assert {:error, :size_mismatch} = Reference.new(Fixtures.solid(4, 3, {0, 0, 0}), 4, 4)
  end

  describe "bang variants" do
    test "new!/3 returns a reference and compare!/2 returns a bare score" do
      ref = Reference.new!(Fixtures.gradient(32, 32), 32, 32)
      assert %Reference{} = ref
      assert Reference.compare!(ref, Fixtures.gradient(32, 32)) > 99.0
    end

    test "new!/3 raises on bad input" do
      assert_raise Ssimulacra2.Error, fn -> Reference.new!(<<>>, 0, 0) end
    end

    test "compare!/2 raises on a wrong-size candidate" do
      ref = Reference.new!(Fixtures.gradient(16, 16), 16, 16)
      assert_raise Ssimulacra2.Error, fn -> Reference.compare!(ref, <<0, 1, 2>>) end
    end
  end

  # {format, reference binary, a different candidate binary}
  @parity_cases [
    {:rgb16, Fixtures.gradient_rgb16(64, 64),
     Fixtures.solid_rgb16(64, 64, {40_000, 20_000, 10_000})},
    {:linear_rgb, Fixtures.gradient_linear_rgb(64, 64),
     Fixtures.solid_linear_rgb(64, 64, 0.5)},
    {:gray8, Fixtures.gradient_gray8(64, 64), Fixtures.solid_gray8(64, 64, 128)},
    {:linear_gray, Fixtures.gradient_linear_gray(64, 64),
     Fixtures.solid_linear_gray(64, 64, 0.5)}
  ]

  for {fmt, ref_img, cand} <- @parity_cases do
    @fmt fmt
    @ref_img ref_img
    @cand cand

    test "new/4 + compare/2 matches one-shot compare for #{fmt}" do
      {:ok, oneshot} = Ssimulacra2.compare(@ref_img, @cand, 64, 64, format: @fmt)
      {:ok, ref} = Reference.new(@ref_img, 64, 64, format: @fmt)
      {:ok, batch} = Reference.compare(ref, @cand)

      assert_in_delta oneshot, batch, 1.0e-4
    end
  end

  test "compare/2 validates the candidate against the reference's stored format" do
    {:ok, ref} = Reference.new(Fixtures.gradient_rgb16(64, 64), 64, 64, format: :rgb16)
    # An RGB888-sized binary (w*h*3) is the wrong size for :rgb16 (needs w*h*6).
    assert {:error, :size_mismatch} = Reference.compare(ref, Fixtures.solid(64, 64, {0, 0, 0}))
  end

  test "new/4 rejects an unknown format" do
    assert {:error, :unknown_format} =
             Reference.new(Fixtures.gradient_rgb16(8, 8), 8, 8, format: :bogus)
  end
end
