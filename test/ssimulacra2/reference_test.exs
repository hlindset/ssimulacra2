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
end
