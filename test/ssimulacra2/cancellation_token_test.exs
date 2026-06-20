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

defmodule Ssimulacra2.CancellationTokenTest do
  use ExUnit.Case, async: true
  alias Ssimulacra2.CancellationToken

  test "new/0 returns a struct wrapping a resource" do
    tok = CancellationToken.new()
    assert %CancellationToken{resource: r} = tok
    assert is_reference(r)
  end

  test "cancel/1 returns :ok" do
    tok = CancellationToken.new()
    assert :ok = CancellationToken.cancel(tok)
  end
end
