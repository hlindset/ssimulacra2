defmodule Ssimulacra2.CancellationTest do
  # async: false — the cross-process/timeout tests run large comparisons whose
  # wall-clock must dominate the cancel/timer; running them serially keeps dirty
  # schedulers uncontended so timing stays predictable.
  use ExUnit.Case, async: false
  alias Ssimulacra2.{CancellationToken, Fixtures, Reference}

  test "compare/5 with a pre-cancelled token returns {:error, :cancelled}" do
    img = Fixtures.gradient(512, 512)
    tok = CancellationToken.new()
    :ok = CancellationToken.cancel(tok)
    assert {:error, :cancelled} = Ssimulacra2.compare(img, img, 512, 512, cancel: tok)
  end

  test "Reference.compare/3 with a pre-cancelled token returns {:error, :cancelled}" do
    img = Fixtures.gradient(512, 512)
    {:ok, ref} = Reference.new(img, 512, 512)
    tok = CancellationToken.new()
    :ok = CancellationToken.cancel(tok)
    assert {:error, :cancelled} = Reference.compare(ref, img, cancel: tok)
  end

  test "a live token does not affect the result" do
    a = Fixtures.gradient(64, 64)
    b = Fixtures.solid(64, 64, {200, 100, 50})
    tok = CancellationToken.new()
    {:ok, plain} = Ssimulacra2.compare(a, b, 64, 64)
    {:ok, with_tok} = Ssimulacra2.compare(a, b, 64, 64, cancel: tok)
    assert_in_delta plain, with_tok, 1.0e-9
  end

  test "a live token does not affect Reference.compare" do
    a = Fixtures.gradient(64, 64)
    b = Fixtures.solid(64, 64, {200, 100, 50})
    {:ok, ref} = Reference.new(a, 64, 64)
    tok = CancellationToken.new()
    {:ok, plain} = Reference.compare(ref, b)
    {:ok, with_tok} = Reference.compare(ref, b, cancel: tok)
    assert_in_delta plain, with_tok, 1.0e-9
  end

  test "cancelling from another process aborts an in-flight compare" do
    # 3000x3000 (~9 MP): the metric runs for well over the ~10 ms head start
    # below, so the cancel reliably lands mid-flight on idle CI too.
    big = Fixtures.solid(3000, 3000, {123, 50, 200})
    tok = CancellationToken.new()
    parent = self()

    task =
      Task.async(fn ->
        send(parent, :started)
        Ssimulacra2.compare(big, big, 3000, 3000, cancel: tok)
      end)

    assert_receive :started, 1000
    Process.sleep(10)
    CancellationToken.cancel(tok)

    assert {:error, :cancelled} = Task.await(task, 30_000)
  end

  test "compare!/5 raises on cancellation" do
    img = Fixtures.gradient(256, 256)
    tok = CancellationToken.new()
    :ok = CancellationToken.cancel(tok)
    assert_raise Ssimulacra2.Error, fn -> Ssimulacra2.compare!(img, img, 256, 256, cancel: tok) end
  end

  test "Reference.compare!/3 raises on cancellation" do
    img = Fixtures.gradient(256, 256)
    {:ok, ref} = Reference.new(img, 256, 256)
    tok = CancellationToken.new()
    :ok = CancellationToken.cancel(tok)
    assert_raise Ssimulacra2.Error, fn -> Reference.compare!(ref, img, cancel: tok) end
  end

  test "an invalid :cancel value is rejected" do
    img = Fixtures.gradient(64, 64)
    assert {:error, :invalid_cancel} = Ssimulacra2.compare(img, img, 64, 64, cancel: :nope)
  end
end
