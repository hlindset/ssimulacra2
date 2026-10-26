defmodule Ssimulacra2.StripParityTest do
  @moduledoc """
  Locks the score for a fixed input so any change to the scoring path (the NIF's
  strip-with-stop route, or a fast-ssim2 bump) shows up as drift. A change larger
  than the delta means scores moved — investigate before accepting it.

  The 64×64 input fits in one strip, where the strip path is bit-identical to
  whole-image scoring. Images taller than one strip are not: fast-ssim2 documents
  strip boundaries as changing the score slightly (~0.02–0.07 at 0.5–2 MP with
  the default 96-row halo, measured on 0.8 and 0.9).
  """
  use ExUnit.Case, async: true
  alias Ssimulacra2.{Fixtures, Reference}

  # Captured at full f64 precision. Originally from the fast-ssim2 0.8 non-strip
  # build (-163.14309657472538); re-captured for 0.9.0, whose bit-exact port of
  # the official implementation moved this pair by ~4.7e-4. 0.9.0's whole-image
  # and strip paths agree bit-for-bit here (64 rows is a single strip).
  @golden_oneshot -163.14356243792145
  @golden_batch -163.14356243792145

  test "one-shot compare/5 matches the locked score" do
    ref = Fixtures.gradient(64, 64)
    cand = Fixtures.solid(64, 64, {200, 100, 50})
    {:ok, score} = Ssimulacra2.compare(ref, cand, 64, 64)
    assert_in_delta score, @golden_oneshot, 1.0e-4
  end

  test "reference compare matches the locked score" do
    ref_img = Fixtures.gradient(64, 64)
    cand = Fixtures.solid(64, 64, {200, 100, 50})
    {:ok, ref} = Reference.new(ref_img, 64, 64)
    {:ok, score} = Reference.compare(ref, cand)
    assert_in_delta score, @golden_batch, 1.0e-4
  end

  # Locks the no-regression guarantee for sub-8px images: they must still score,
  # not error. Since fast-ssim2 0.9 they take the strip path too, which
  # reflect-pads them to the 8px floor.
  test "an image smaller than 8px still scores" do
    img = Fixtures.gradient(6, 6)
    assert {:ok, score} = Ssimulacra2.compare(img, img, 6, 6)
    assert_in_delta score, 100.0, 1.0e-6
    {:ok, ref} = Reference.new(img, 6, 6)
    assert {:ok, batch} = Reference.compare(ref, img)
    assert_in_delta batch, 100.0, 1.0e-6
  end
end
