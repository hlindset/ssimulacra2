defmodule Ssimulacra2.CancellationTest do
  # async: false — the cross-process/timeout tests run large comparisons whose
  # wall-clock must dominate the cancel/timer; running them serially keeps dirty
  # schedulers uncontended so timing stays predictable.
  use ExUnit.Case, async: false
  alias Ssimulacra2.{CancelRef, Fixtures, Reference}

  test "compare/5 with a pre-cancelled ref returns {:error, :cancelled}" do
    img = Fixtures.gradient(512, 512)
    tok = CancelRef.new()
    :ok = Ssimulacra2.cancel(tok)
    assert {:error, :cancelled} = Ssimulacra2.compare(img, img, 512, 512, cancel: tok)
  end

  test "Reference.compare/3 with a pre-cancelled ref returns {:error, :cancelled}" do
    img = Fixtures.gradient(512, 512)
    {:ok, ref} = Reference.new(img, 512, 512)
    tok = CancelRef.new()
    :ok = Ssimulacra2.cancel(tok)
    assert {:error, :cancelled} = Reference.compare(ref, img, cancel: tok)
  end

  test "a live ref does not affect the result" do
    a = Fixtures.gradient(64, 64)
    b = Fixtures.solid(64, 64, {200, 100, 50})
    tok = CancelRef.new()
    {:ok, plain} = Ssimulacra2.compare(a, b, 64, 64)
    {:ok, with_tok} = Ssimulacra2.compare(a, b, 64, 64, cancel: tok)
    assert_in_delta plain, with_tok, 1.0e-9
  end

  test "a live ref does not affect Reference.compare" do
    a = Fixtures.gradient(64, 64)
    b = Fixtures.solid(64, 64, {200, 100, 50})
    {:ok, ref} = Reference.new(a, 64, 64)
    tok = CancelRef.new()
    {:ok, plain} = Reference.compare(ref, b)
    {:ok, with_tok} = Reference.compare(ref, b, cancel: tok)
    assert_in_delta plain, with_tok, 1.0e-9
  end

  test "cancelling from another process aborts an in-flight compare" do
    # 3000x3000 (~9 MP): the metric runs for well over the ~10 ms head start
    # below, so the cancel reliably lands mid-flight on idle CI too.
    big = Fixtures.solid(3000, 3000, {123, 50, 200})

    # Baseline: how long a full (uncancelled) compare of this image takes.
    {full_us, {:ok, _}} = :timer.tc(fn -> Ssimulacra2.compare(big, big, 3000, 3000) end)

    tok = CancelRef.new()
    parent = self()

    task =
      Task.async(fn ->
        send(parent, :started)
        Ssimulacra2.compare(big, big, 3000, 3000, cancel: tok)
      end)

    assert_receive :started, 1000
    Process.sleep(10)
    Ssimulacra2.cancel(tok)

    {abort_us, result} = :timer.tc(fn -> Task.await(task, 30_000) end)
    assert {:error, :cancelled} = result
    # Proves the abort was mid-flight, not a run-to-completion: it returns in
    # well under half a full compute (measured ~0.1x; the bound scales with the
    # machine because both timings do).
    assert abort_us < full_us / 2
  end

  test "cancelling from another process aborts an in-flight Reference.compare" do
    big = Fixtures.solid(3000, 3000, {123, 50, 200})
    {:ok, ref} = Reference.new(big, 3000, 3000)
    tok = CancelRef.new()
    parent = self()

    task =
      Task.async(fn ->
        send(parent, :started)
        Reference.compare(ref, big, cancel: tok)
      end)

    assert_receive :started, 1000
    Process.sleep(10)
    Ssimulacra2.cancel(tok)

    assert {:error, :cancelled} = Task.await(task, 30_000)
  end

  test "a cancelled ref aborts every subsequent comparison" do
    a = Fixtures.gradient(64, 64)
    b = Fixtures.solid(64, 64, {200, 100, 50})
    tok = CancelRef.new()
    :ok = Ssimulacra2.cancel(tok)

    # One ref covers a whole batch: once tripped, all later compares abort.
    assert {:error, :cancelled} = Ssimulacra2.compare(a, b, 64, 64, cancel: tok)
    assert {:error, :cancelled} = Ssimulacra2.compare(a, b, 64, 64, cancel: tok)
  end

  test "compare!/5 raises on cancellation" do
    img = Fixtures.gradient(256, 256)
    tok = CancelRef.new()
    :ok = Ssimulacra2.cancel(tok)

    assert_raise Ssimulacra2.Error, fn ->
      Ssimulacra2.compare!(img, img, 256, 256, cancel: tok)
    end
  end

  test "Reference.compare!/3 raises on cancellation" do
    img = Fixtures.gradient(256, 256)
    {:ok, ref} = Reference.new(img, 256, 256)
    tok = CancelRef.new()
    :ok = Ssimulacra2.cancel(tok)
    assert_raise Ssimulacra2.Error, fn -> Reference.compare!(ref, img, cancel: tok) end
  end

  test "an invalid :cancel value is rejected" do
    img = Fixtures.gradient(64, 64)
    assert {:error, :invalid_cancel} = Ssimulacra2.compare(img, img, 64, 64, cancel: :nope)
  end

  test "compare/5 returns {:error, :timeout} when it exceeds :timeout" do
    # 2500x2500 (~6 MP): the metric runs for far longer than 1 ms, so the timer
    # always wins, even on fast/idle CI.
    big = Fixtures.solid(2500, 2500, {10, 20, 30})
    assert {:error, :timeout} = Ssimulacra2.compare(big, big, 2500, 2500, timeout: 1)
  end

  test "Reference.compare/3 returns {:error, :timeout} when it exceeds :timeout" do
    big = Fixtures.solid(2500, 2500, {10, 20, 30})
    {:ok, ref} = Reference.new(big, 2500, 2500)
    assert {:error, :timeout} = Reference.compare(ref, big, timeout: 1)
  end

  test "a generous :timeout returns the same score as no timeout" do
    a = Fixtures.gradient(64, 64)
    b = Fixtures.solid(64, 64, {200, 100, 50})
    {:ok, plain} = Ssimulacra2.compare(a, b, 64, 64)
    {:ok, timed} = Ssimulacra2.compare(a, b, 64, 64, timeout: 60_000)
    assert_in_delta plain, timed, 1.0e-9
  end

  test "external cancel during a timed call is reported as :cancelled, not :timeout" do
    big = Fixtures.solid(3000, 3000, {1, 2, 3})
    tok = CancelRef.new()
    parent = self()

    task =
      Task.async(fn ->
        send(parent, :started)
        Ssimulacra2.compare(big, big, 3000, 3000, cancel: tok, timeout: 60_000)
      end)

    assert_receive :started, 1000
    Process.sleep(10)
    Ssimulacra2.cancel(tok)

    assert {:error, :cancelled} = Task.await(task, 30_000)
  end

  test "compare!/5 raises on timeout" do
    big = Fixtures.solid(2500, 2500, {10, 20, 30})

    assert_raise Ssimulacra2.Error, fn ->
      Ssimulacra2.compare!(big, big, 2500, 2500, timeout: 1)
    end
  end

  test "an invalid :timeout value is rejected" do
    img = Fixtures.gradient(64, 64)
    assert {:error, :invalid_timeout} = Ssimulacra2.compare(img, img, 64, 64, timeout: 0)
    assert {:error, :invalid_timeout} = Ssimulacra2.compare(img, img, 64, 64, timeout: -5)
    assert {:error, :invalid_timeout} = Ssimulacra2.compare(img, img, 64, 64, timeout: 1.5)
    assert {:error, :invalid_timeout} = Ssimulacra2.compare(img, img, 64, 64, timeout: "100")
  end
end
