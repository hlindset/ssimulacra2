defmodule Ssimulacra2.StripParityTest do
  @moduledoc """
  Locks the score for a fixed input so switching the NIF to the strip-with-stop
  algorithm is proven score-identical for ≥8px inputs (the strip-switch gate). The
  golden numbers were captured from the pre-strip build; a change larger than
  the delta means the strip path is not equivalent — investigate before
  accepting any drift.

  rgb888 is a sufficient proxy for all five formats: every format is converted
  to linear RGB (`ToLinearRgb`) *before* the strip walk, and the strip-vs-
  non-strip difference is entirely in that post-conversion walk. So a single
  format gates the change for all of them; the existing per-format parity tests
  cover the conversion paths.
  """
  use ExUnit.Case, async: true
  alias Ssimulacra2.{Fixtures, Reference}

  # Captured from the non-strip build (Task 4, Step 1) at full f64 precision.
  @golden_oneshot -163.14309657472538
  @golden_batch -163.14309657472538

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

  # Locks the no-regression guarantee for sub-8px images: they must still score
  # (via the non-strip cancellable path), not error. Passes both before the
  # strip switch (non-strip everywhere) and after (size-dispatch).
  test "an image smaller than 8px still scores" do
    img = Fixtures.gradient(6, 6)
    assert {:ok, score} = Ssimulacra2.compare(img, img, 6, 6)
    assert_in_delta score, 100.0, 1.0e-6
    {:ok, ref} = Reference.new(img, 6, 6)
    assert {:ok, batch} = Reference.compare(ref, img)
    assert_in_delta batch, 100.0, 1.0e-6
  end
end
