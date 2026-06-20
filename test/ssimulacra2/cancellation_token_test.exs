defmodule Ssimulacra2.CancellationTokenNativeTest do
  use ExUnit.Case, async: true
  alias Ssimulacra2.Native

  test "token_new/0 returns a resource reference" do
    assert is_reference(Native.token_new())
  end

  test "token_cancel/1 returns :ok and is idempotent" do
    tok = Native.token_new()
    assert :ok = Native.token_cancel(tok)
    assert :ok = Native.token_cancel(tok)
  end
end
