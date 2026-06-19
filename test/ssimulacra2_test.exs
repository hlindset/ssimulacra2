defmodule Ssimulacra2Test do
  use ExUnit.Case, async: true
  alias Ssimulacra2.Fixtures

  test "native library loads" do
    assert Ssimulacra2.Native.nif_loaded() == true
  end

  describe "compare/5 validation" do
    test "rejects non-positive dimensions" do
      assert {:error, :invalid_dimensions} = Ssimulacra2.compare(<<>>, <<>>, 0, 10)
      assert {:error, :invalid_dimensions} = Ssimulacra2.compare(<<>>, <<>>, 10, -1)
    end

    test "rejects a reference binary whose size != w*h*3" do
      good = Fixtures.solid(4, 4, {1, 2, 3})
      bad = Fixtures.solid(4, 3, {1, 2, 3})
      assert {:error, :size_mismatch} = Ssimulacra2.compare(bad, good, 4, 4)
    end

    test "rejects a distorted binary whose size != w*h*3" do
      good = Fixtures.solid(4, 4, {1, 2, 3})
      bad = Fixtures.solid(4, 3, {1, 2, 3})
      assert {:error, :size_mismatch} = Ssimulacra2.compare(good, bad, 4, 4)
    end
  end

  describe "compare/5 scoring" do
    test "identical images score ~100" do
      img = Fixtures.gradient(64, 64)
      assert {:ok, score} = Ssimulacra2.compare(img, img, 64, 64)
      assert score > 99.0
    end

    test "different images score below identical" do
      a = Fixtures.gradient(64, 64)
      b = Fixtures.solid(64, 64, {128, 128, 128})
      assert {:ok, identical} = Ssimulacra2.compare(a, a, 64, 64)
      assert {:ok, different} = Ssimulacra2.compare(a, b, 64, 64)
      assert different < identical
    end
  end

  describe "compare!/5" do
    test "returns the bare score on success" do
      img = Fixtures.gradient(32, 32)
      assert Ssimulacra2.compare!(img, img, 32, 32) > 99.0
    end

    test "raises Ssimulacra2.Error on bad input" do
      assert_raise Ssimulacra2.Error, fn ->
        Ssimulacra2.compare!(<<>>, <<>>, 0, 0)
      end
    end

    test "passes a non-default format through to the bare score" do
      img = Fixtures.gradient_rgb16(32, 32)
      assert Ssimulacra2.compare!(img, img, 32, 32, format: :rgb16) > 99.0
    end

    test "raises Ssimulacra2.Error on an unknown format" do
      img = Fixtures.gradient_rgb16(8, 8)

      assert_raise Ssimulacra2.Error, fn ->
        Ssimulacra2.compare!(img, img, 8, 8, format: :bogus)
      end
    end
  end
end
