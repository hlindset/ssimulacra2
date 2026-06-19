defmodule Ssimulacra2Test do
  use ExUnit.Case, async: true
  alias Ssimulacra2.Fixtures

  test "native library loads" do
    assert Ssimulacra2.Native.nif_loaded() == true
  end

  describe "compare/4 validation" do
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
end
