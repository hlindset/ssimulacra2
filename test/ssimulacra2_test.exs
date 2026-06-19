defmodule Ssimulacra2Test do
  use ExUnit.Case, async: true

  test "native library loads" do
    assert Ssimulacra2.Native.nif_loaded() == true
  end
end
