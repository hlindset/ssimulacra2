# Cooperative Cancellation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let an in-flight `Ssimulacra2.compare/5` or `Ssimulacra2.Reference.compare/3` be aborted mid-computation via a cancellation token or a `:timeout`, returning `{:error, :cancelled}` / `{:error, :timeout}` and freeing the dirty-scheduler CPU promptly.

**Architecture:** Wire `fast-ssim2`'s `*_strip_with_stop` variants through the NIF. A `SyncStopper` lives in a `ResourceArc` (`Ssimulacra2.CancellationToken`); a cheap *regular* NIF (`token_cancel`) trips it from another process while the dirty `compare` blocks its scheduler thread, polling the token at each strip boundary. `:timeout` is pure-Elixir sugar (a canceller process trips the token after N ms).

**Tech Stack:** Elixir + Rustler 0.38, `fast-ssim2` (git-pinned), `enough` + `almost-enough` crates. Toolchain via `mise` (run everything through `mise exec --`).

**Reference spec:** `docs/superpowers/specs/2026-06-20-cancellation-design.md`

**Conventions for every task:**
- Build + test gate is `mise exec -- mix test` (config sets `force_build: true` in `:test`, so the NIF recompiles).
- Tests are `async: true` and use `Ssimulacra2.Fixtures` (in `test/support/`).
- Commit after each task with the trailer:
  `Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>`

---

## File Structure

- `native/ssimulacra2_nif/Cargo.toml` — dependency pins (git rev + `enough`/`almost-enough`).
- `native/ssimulacra2_nif/src/lib.rs` — token resource, `token_new`/`token_cancel` NIFs, strip-with-stop wiring, `CompareError` enum.
- `lib/ssimulacra2/native.ex` — updated NIF stubs (`token_new/0`, `token_cancel/1`, `compare/6`, `reference_compare/6`).
- `lib/ssimulacra2/cancellation_token.ex` — **new** `Ssimulacra2.CancellationToken` (the neutral primitive).
- `lib/ssimulacra2/cancellation.ex` — **new** `Ssimulacra2.Cancellation` (private timeout orchestration + result mapping).
- `lib/ssimulacra2/validate.ex` — add `cancel/1` and `timeout/1`.
- `lib/ssimulacra2.ex` — `:cancel`/`:timeout` opts on `compare/5`; updated `@type reason`.
- `lib/ssimulacra2/reference.ex` — `:cancel`/`:timeout` opts on `compare/3`.
- `test/ssimulacra2/cancellation_token_test.exs` — **new**.
- `test/ssimulacra2/strip_parity_test.exs` — **new** (score-identity gate).
- `test/ssimulacra2/cancellation_test.exs` — **new** (cancel + timeout behavior).
- `README.md` — cancellation usage + build-from-source note.

---

## Task 1: Pin fast-ssim2 to the cancellation-capable git rev

**Files:**
- Modify: `native/ssimulacra2_nif/Cargo.toml`
- Modify: `native/ssimulacra2_nif/Cargo.lock` (regenerated)

- [ ] **Step 1: Edit the dependencies**

In `native/ssimulacra2_nif/Cargo.toml`, replace the `fast-ssim2` line and add the two token crates:

```toml
[dependencies]
rustler = "0.38.0"
fast-ssim2 = { git = "https://github.com/imazen/fast-ssim2", rev = "093aa6f15a0826b20dc94c249c33e14c0a68bf67", features = ["imgref"] }
enough = "0.4.4"
almost-enough = "0.4.4"
imgref = "1"
bytemuck = "1"
```

- [ ] **Step 2: Rebuild against the new crate (regenerates Cargo.lock)**

Run: `mise exec -- mix compile --force`
Expected: compiles cleanly; `native/ssimulacra2_nif/Cargo.lock` now pins `fast-ssim2` to the git source at that rev (and adds `enough`/`almost-enough`).

- [ ] **Step 3: Run the full suite — existing behavior must be unchanged**

Run: `mise exec -- mix test`
Expected: PASS (all existing tests; the public `compute_ssimulacra2` / `Ssimulacra2Reference::compare` API is unchanged at this rev).

- [ ] **Step 4: Commit**

```bash
git add native/ssimulacra2_nif/Cargo.toml native/ssimulacra2_nif/Cargo.lock
git commit -m "build: pin fast-ssim2 to cancellation-capable git rev

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Task 2: Cancellation token resource + token NIFs (Rust)

**Files:**
- Modify: `native/ssimulacra2_nif/src/lib.rs`
- Modify: `lib/ssimulacra2/native.ex`
- Test: `test/ssimulacra2/cancellation_token_test.exs` (Native-level assertions)

- [ ] **Step 1: Write the failing test**

Create `test/ssimulacra2/cancellation_token_test.exs`:

```elixir
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
```

- [ ] **Step 2: Run it to confirm it fails**

Run: `mise exec -- mix test test/ssimulacra2/cancellation_token_test.exs`
Expected: FAIL — `Native.token_new/0` undefined / `:nif_not_loaded`.

- [ ] **Step 3: Add the `ok` atom**

In `native/ssimulacra2_nif/src/lib.rs`, extend the atoms module:

```rust
mod atoms {
    rustler::atoms! {
        ok,
        rgb888,
        rgb16,
        linear_rgb,
        gray8,
        linear_gray,
    }
}
```

- [ ] **Step 4: Add the resource and the two regular NIFs**

In `native/ssimulacra2_nif/src/lib.rs`, add imports at the top:

```rust
use almost_enough::SyncStopper;
```

Add the resource + NIFs (place after the `nif_loaded` fn):

```rust
struct StopResource {
    stopper: SyncStopper,
}

#[rustler::resource_impl]
impl rustler::Resource for StopResource {}

/// Create a fresh, live cancellation token. Regular (non-dirty) NIF.
#[rustler::nif]
fn token_new() -> ResourceArc<StopResource> {
    ResourceArc::new(StopResource {
        stopper: SyncStopper::new(),
    })
}

/// Trip a cancellation token. Regular NIF — runs instantly on a normal
/// scheduler, so it can cancel a token while a dirty `compare` blocks.
#[rustler::nif]
fn token_cancel(token: ResourceArc<StopResource>) -> Atom {
    token.stopper.cancel();
    atoms::ok()
}
```

(`rustler::init!` auto-registers every `#[rustler::nif]` — no list to update.)

- [ ] **Step 5: Add the Elixir NIF stubs**

In `lib/ssimulacra2/native.ex`, add inside the module:

```elixir
def token_new, do: :erlang.nif_error(:nif_not_loaded)

def token_cancel(_token), do: :erlang.nif_error(:nif_not_loaded)
```

- [ ] **Step 6: Run the test to confirm it passes**

Run: `mise exec -- mix test test/ssimulacra2/cancellation_token_test.exs`
Expected: PASS.

- [ ] **Step 7: Commit**

```bash
git add native/ssimulacra2_nif/src/lib.rs lib/ssimulacra2/native.ex test/ssimulacra2/cancellation_token_test.exs
git commit -m "feat: cancellation token resource and token NIFs

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Task 3: `Ssimulacra2.CancellationToken` Elixir module

**Files:**
- Create: `lib/ssimulacra2/cancellation_token.ex`
- Test: `test/ssimulacra2/cancellation_token_test.exs` (extend)

- [ ] **Step 1: Add the failing test**

Append to `test/ssimulacra2/cancellation_token_test.exs`:

```elixir
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
```

- [ ] **Step 2: Run it to confirm it fails**

Run: `mise exec -- mix test test/ssimulacra2/cancellation_token_test.exs`
Expected: FAIL — `Ssimulacra2.CancellationToken` undefined.

- [ ] **Step 3: Create the module**

Create `lib/ssimulacra2/cancellation_token.ex`:

```elixir
defmodule Ssimulacra2.CancellationToken do
  @moduledoc """
  A cancellation token for aborting an in-flight `Ssimulacra2.compare/5` or
  `Ssimulacra2.Reference.compare/3`.

  The token is a neutral primitive — *you* assign it meaning. Create one with
  `new/0`, pass it as `cancel: token`, and call `cancel/1` from any process
  (e.g. a client-disconnect monitor or a search deadline) to abort the
  comparison. The aborted call returns `{:error, :cancelled}`.

  A token is **single-use**: once cancelled it stays cancelled. One token can
  cover a whole batch — cancelling it aborts the in-flight comparison and makes
  every subsequent comparison using it return `{:error, :cancelled}` at once.
  """

  alias Ssimulacra2.Native

  @enforce_keys [:resource]
  defstruct [:resource]

  @type t :: %__MODULE__{resource: reference()}

  @doc "Create a fresh, live (not-yet-cancelled) token."
  @spec new() :: t()
  def new(), do: %__MODULE__{resource: Native.token_new()}

  @doc "Trip the token. Returns `:ok`. Safe to call more than once."
  @spec cancel(t()) :: :ok
  def cancel(%__MODULE__{resource: r}), do: Native.token_cancel(r)
end
```

- [ ] **Step 4: Run the test to confirm it passes**

Run: `mise exec -- mix test test/ssimulacra2/cancellation_token_test.exs`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add lib/ssimulacra2/cancellation_token.ex test/ssimulacra2/cancellation_token_test.exs
git commit -m "feat: Ssimulacra2.CancellationToken module

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Task 4: Lock current scores (score-identity gate)

This captures the **current non-strip** scores so the next task's switch to the
strip algorithm can be proven score-identical.

**Files:**
- Test: `test/ssimulacra2/strip_parity_test.exs`

- [ ] **Step 1: Capture the current scores**

Run (prints two numbers from the current, pre-strip build):

```bash
mise exec -- mix run -e '
ref = (for y <- 0..63, x <- 0..63, into: <<>>, do: <<rem(x,256), rem(y,256), rem(x+y,256)>>)
cand = :binary.copy(<<200, 100, 50>>, 64*64)
{:ok, oneshot} = Ssimulacra2.compare(ref, cand, 64, 64)
{:ok, r} = Ssimulacra2.Reference.new(ref, 64, 64)
{:ok, batch} = Ssimulacra2.Reference.compare(r, cand)
IO.puts("oneshot=" <> :erlang.float_to_binary(oneshot, decimals: 6))
IO.puts("batch=" <> :erlang.float_to_binary(batch, decimals: 6))
'
```

Record both printed numbers. They will be the golden constants in Step 2.

- [ ] **Step 2: Write the golden test using the captured numbers**

Create `test/ssimulacra2/strip_parity_test.exs`, substituting the two numbers
captured in Step 1 for `<ONESHOT>` and `<BATCH>`:

```elixir
defmodule Ssimulacra2.StripParityTest do
  @moduledoc """
  Locks the score for a fixed input so switching the NIF to the strip-with-stop
  algorithm is proven score-identical (the design's "always strip" gate). The
  golden numbers were captured from the pre-strip build; a change larger than
  the delta means the strip path is not equivalent — investigate before
  accepting any drift.
  """
  use ExUnit.Case, async: true
  alias Ssimulacra2.{Fixtures, Reference}

  # Captured from the non-strip build (Task 4, Step 1).
  @golden_oneshot <ONESHOT>
  @golden_batch <BATCH>

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
end
```

- [ ] **Step 3: Run the golden test to confirm it passes on the current build**

Run: `mise exec -- mix test test/ssimulacra2/strip_parity_test.exs`
Expected: PASS (it locks the behavior you just captured).

- [ ] **Step 4: Commit**

```bash
git add test/ssimulacra2/strip_parity_test.exs
git commit -m "test: lock current scores before strip switch

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Task 5: Switch the NIF to strip-with-stop + optional token + tagged errors

After this task the public API behaves the same (no `:cancel`/`:timeout` yet),
but internally runs the strip-with-stop path and returns the new error shape.

**Files:**
- Modify: `native/ssimulacra2_nif/src/lib.rs`
- Modify: `lib/ssimulacra2/native.ex`
- Modify: `lib/ssimulacra2.ex`
- Modify: `lib/ssimulacra2/reference.ex`

- [ ] **Step 1: Update Rust imports and add the error enum + strip constant**

In `native/ssimulacra2_nif/src/lib.rs`, change the `fast_ssim2` import and add
the token-trait imports:

```rust
use fast_ssim2::{
    compute_ssimulacra2_strip_with_stop, Ssimulacra2Error, Ssimulacra2Reference, ToLinearRgb,
};
use enough::{Stop, Unstoppable};
```

(Keep the existing `use almost_enough::SyncStopper;` from Task 2.)

Add near the top (after the atoms module):

```rust
/// Rows per cancellation-check boundary at scale 0. 256 is upstream's
/// documented memory sweet spot (~bounded peak working set at 40 MP) and
/// gives ~150 ms cancellation latency at scale 0 on a 36 MP image.
const STRIP_HEIGHT: u32 = 256;

#[derive(rustler::NifTaggedEnum)]
enum CompareError {
    Cancelled,
    Failed(String),
}

fn to_compare_error(e: Ssimulacra2Error) -> CompareError {
    match e {
        Ssimulacra2Error::Cancelled(_) => CompareError::Cancelled,
        other => CompareError::Failed(other.to_string()),
    }
}
```

- [ ] **Step 2: Rewrite the `score` helper to take a stop token**

Replace the existing `score` fn:

```rust
fn score<S: ToLinearRgb, D: ToLinearRgb>(
    s: S,
    d: D,
    stop: &dyn Stop,
) -> Result<f64, CompareError> {
    compute_ssimulacra2_strip_with_stop(s, d, STRIP_HEIGHT, stop).map_err(to_compare_error)
}
```

- [ ] **Step 3: Add the `cancel` arg + token plumbing to `compare`**

Replace the existing `compare` NIF:

```rust
#[rustler::nif(schedule = "DirtyCpu")]
fn compare(
    reference: Binary,
    distorted: Binary,
    width: usize,
    height: usize,
    format: Atom,
    cancel: Option<ResourceArc<StopResource>>,
) -> Result<f64, CompareError> {
    let (r, d, w, h) = (reference.as_slice(), distorted.as_slice(), width, height);
    let unstoppable = Unstoppable;
    let stop: &dyn Stop = match &cancel {
        Some(res) => &res.stopper,
        None => &unstoppable,
    };
    let format = Format::from_atom(format).map_err(CompareError::Failed)?;
    match format {
        Format::Rgb888 => score(rgb888(r, w, h), rgb888(d, w, h), stop),
        Format::Gray8 => score(gray8(r, w, h), gray8(d, w, h), stop),
        Format::Rgb16 => {
            let (a, b) = (rgb16(r, w, h), rgb16(d, w, h));
            score(a.as_ref(), b.as_ref(), stop)
        }
        Format::LinearRgb => {
            let (a, b) = (linear_rgb(r, w, h), linear_rgb(d, w, h));
            score(a.as_ref(), b.as_ref(), stop)
        }
        Format::LinearGray => {
            let (a, b) = (linear_gray(r, w, h), linear_gray(d, w, h));
            score(a.as_ref(), b.as_ref(), stop)
        }
    }
}
```

- [ ] **Step 4: Add the `cancel` arg + strip-with-stop to `reference_compare`**

Replace the existing `reference_compare` NIF (leave `reference_new` untouched):

```rust
#[rustler::nif(schedule = "DirtyCpu")]
fn reference_compare(
    reference: ResourceArc<ReferenceResource>,
    distorted: Binary,
    width: usize,
    height: usize,
    format: Atom,
    cancel: Option<ResourceArc<StopResource>>,
) -> Result<f64, CompareError> {
    let (d, w, h) = (distorted.as_slice(), width, height);
    let r = &reference.inner;
    let unstoppable = Unstoppable;
    let stop: &dyn Stop = match &cancel {
        Some(res) => &res.stopper,
        None => &unstoppable,
    };
    let format = Format::from_atom(format).map_err(CompareError::Failed)?;
    match format {
        Format::Rgb888 => r
            .compare_strip_with_stop(rgb888(d, w, h), STRIP_HEIGHT, stop)
            .map_err(to_compare_error),
        Format::Gray8 => r
            .compare_strip_with_stop(gray8(d, w, h), STRIP_HEIGHT, stop)
            .map_err(to_compare_error),
        Format::Rgb16 => r
            .compare_strip_with_stop(rgb16(d, w, h).as_ref(), STRIP_HEIGHT, stop)
            .map_err(to_compare_error),
        Format::LinearRgb => r
            .compare_strip_with_stop(linear_rgb(d, w, h).as_ref(), STRIP_HEIGHT, stop)
            .map_err(to_compare_error),
        Format::LinearGray => r
            .compare_strip_with_stop(linear_gray(d, w, h).as_ref(), STRIP_HEIGHT, stop)
            .map_err(to_compare_error),
    }
}
```

- [ ] **Step 5: Update the Elixir NIF stubs to the new arity**

In `lib/ssimulacra2/native.ex`, replace the `compare` and `reference_compare`
stubs (leave `reference_new/4` unchanged):

```elixir
def compare(_reference, _distorted, _width, _height, _format, _cancel),
  do: :erlang.nif_error(:nif_not_loaded)

def reference_compare(_reference, _distorted, _width, _height, _format, _cancel),
  do: :erlang.nif_error(:nif_not_loaded)
```

- [ ] **Step 6: Update `Ssimulacra2.compare/5` to call the new NIF and map the new error shape**

In `lib/ssimulacra2.ex`, replace the body of `compare/5` and `map_native_error`:

```elixir
  def compare(reference, distorted, width, height, opts \\ [])
      when is_binary(reference) and is_binary(distorted) do
    format = Keyword.get(opts, :format, :rgb888)

    with :ok <- Validate.format(format),
         :ok <- Validate.dims(width, height),
         :ok <- Validate.size(reference, width, height, format),
         :ok <- Validate.size(distorted, width, height, format) do
      Native.compare(reference, distorted, width, height, format, nil)
      |> map_native_error()
    end
  end
```

```elixir
  defp map_native_error({:ok, score}), do: {:ok, score}
  defp map_native_error({:error, :cancelled}), do: {:error, :cancelled}
  defp map_native_error({:error, {:failed, message}}), do: {:error, {:ssimulacra2, message}}
```

- [ ] **Step 7: Update `Reference.compare/2` to call the new NIF and map the new error shape**

In `lib/ssimulacra2/reference.ex`, replace `compare/2`'s native call and the
`map_native` clause for compare. Update the `compare/2` body:

```elixir
  def compare(%__MODULE__{} = ref, distorted) when is_binary(distorted) do
    with :ok <- Validate.size(distorted, ref.width, ref.height, ref.format) do
      Native.reference_compare(ref.resource, distorted, ref.width, ref.height, ref.format, nil)
      |> map_compare()
    end
  end
```

Add a dedicated mapper (keep the existing `map_native/1` for `new/4`):

```elixir
  defp map_compare({:ok, value}), do: {:ok, value}
  defp map_compare({:error, :cancelled}), do: {:error, :cancelled}
  defp map_compare({:error, {:failed, message}}), do: {:error, {:ssimulacra2, message}}
```

- [ ] **Step 8: Run the score-identity gate**

Run: `mise exec -- mix test test/ssimulacra2/strip_parity_test.exs`
Expected: PASS — strip scores match the locked golden values within `1.0e-4`.
(If it fails by more than the delta, stop and investigate: the strip path is not
equivalent. Do NOT just update the goldens.)

- [ ] **Step 9: Run the full suite**

Run: `mise exec -- mix test`
Expected: PASS (all existing tests; behavior unchanged for ≥8px images).

- [ ] **Step 10: Commit**

```bash
git add native/ssimulacra2_nif/src/lib.rs lib/ssimulacra2/native.ex lib/ssimulacra2.ex lib/ssimulacra2/reference.ex
git commit -m "feat: run compares via strip-with-stop with optional token

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Task 6: Wire the `:cancel` option

**Files:**
- Create: `lib/ssimulacra2/cancellation.ex`
- Modify: `lib/ssimulacra2/validate.ex`
- Modify: `lib/ssimulacra2.ex`
- Modify: `lib/ssimulacra2/reference.ex`
- Test: `test/ssimulacra2/cancellation_test.exs`

- [ ] **Step 1: Write the failing tests**

Create `test/ssimulacra2/cancellation_test.exs`:

```elixir
defmodule Ssimulacra2.CancellationTest do
  use ExUnit.Case, async: true
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

  test "cancelling from another process aborts an in-flight compare" do
    big = Fixtures.solid(2500, 2500, {123, 50, 200})
    tok = CancellationToken.new()
    parent = self()

    task =
      Task.async(fn ->
        send(parent, :started)
        Ssimulacra2.compare(big, big, 2500, 2500, cancel: tok)
      end)

    assert_receive :started, 1000
    Process.sleep(20)
    CancellationToken.cancel(tok)

    assert {:error, :cancelled} = Task.await(task, 30_000)
  end

  test "compare!/5 raises on cancellation" do
    img = Fixtures.gradient(256, 256)
    tok = CancellationToken.new()
    :ok = CancellationToken.cancel(tok)
    assert_raise Ssimulacra2.Error, fn -> Ssimulacra2.compare!(img, img, 256, 256, cancel: tok) end
  end

  test "an invalid :cancel value is rejected" do
    img = Fixtures.gradient(64, 64)
    assert {:error, :invalid_cancel} = Ssimulacra2.compare(img, img, 64, 64, cancel: :nope)
  end
end
```

- [ ] **Step 2: Run them to confirm they fail**

Run: `mise exec -- mix test test/ssimulacra2/cancellation_test.exs`
Expected: FAIL — `compare/5` ignores `:cancel`; `:invalid_cancel` not returned.

- [ ] **Step 3: Add validation helpers**

In `lib/ssimulacra2/validate.ex`, add:

```elixir
  @doc "Returns :ok or {:error, :invalid_cancel}."
  def cancel(nil), do: :ok
  def cancel(%Ssimulacra2.CancellationToken{}), do: :ok
  def cancel(_), do: {:error, :invalid_cancel}
```

- [ ] **Step 4: Create the cancellation orchestration module (no-timeout path)**

Create `lib/ssimulacra2/cancellation.ex`:

```elixir
defmodule Ssimulacra2.Cancellation do
  @moduledoc false
  # Shared cancellation/timeout orchestration for compare and Reference.compare.

  alias Ssimulacra2.CancellationToken

  # `invoke` is a 1-arity fun taking the token resource (or nil) and returning
  # the raw native result: {:ok, score} | {:error, :cancelled}
  #                                       | {:error, {:failed, msg}}.
  @spec run(CancellationToken.t() | nil, pos_integer() | nil, (reference() | nil -> term())) ::
          {:ok, float()}
          | {:error, :cancelled | :timeout | {:ssimulacra2, String.t()}}
  def run(cancel, nil, invoke) do
    resource = token_resource(cancel)
    invoke.(resource) |> map_result(:not_timed_out)
  end

  defp token_resource(%CancellationToken{resource: r}), do: r
  defp token_resource(nil), do: nil

  defp map_result({:ok, score}, _status), do: {:ok, score}
  defp map_result({:error, :cancelled}, :timed_out), do: {:error, :timeout}
  defp map_result({:error, :cancelled}, _status), do: {:error, :cancelled}
  defp map_result({:error, {:failed, message}}, _status), do: {:error, {:ssimulacra2, message}}
end
```

- [ ] **Step 5: Wire `:cancel` into `Ssimulacra2.compare/5`**

In `lib/ssimulacra2.ex`, add the alias and rewrite `compare/5` to read `:cancel`
and delegate to `Cancellation.run`. Replace `alias Ssimulacra2.{Native, Validate}`
with:

```elixir
  alias Ssimulacra2.{Cancellation, Native, Validate}
```

Replace `compare/5`:

```elixir
  def compare(reference, distorted, width, height, opts \\ [])
      when is_binary(reference) and is_binary(distorted) do
    format = Keyword.get(opts, :format, :rgb888)
    cancel = Keyword.get(opts, :cancel)

    with :ok <- Validate.format(format),
         :ok <- Validate.dims(width, height),
         :ok <- Validate.size(reference, width, height, format),
         :ok <- Validate.size(distorted, width, height, format),
         :ok <- Validate.cancel(cancel) do
      Cancellation.run(cancel, nil, fn resource ->
        Native.compare(reference, distorted, width, height, format, resource)
      end)
    end
  end
```

Delete the now-unused `map_native_error/1` private function from `lib/ssimulacra2.ex`.

Add the new reasons to `@type reason`:

```elixir
  @type reason ::
          :invalid_dimensions
          | :size_mismatch
          | :dimension_mismatch
          | :unknown_format
          | :invalid_cancel
          | :cancelled
          | {:ssimulacra2, String.t()}
```

- [ ] **Step 6: Wire `:cancel` into `Reference.compare`**

In `lib/ssimulacra2/reference.ex`, add the alias and convert `compare/2` to
`compare/3` with opts. Replace `alias Ssimulacra2.{Native, Validate}` with:

```elixir
  alias Ssimulacra2.{Cancellation, Native, Validate}
```

Replace `compare/2`:

```elixir
  @doc "Compare a candidate against the precomputed reference (same format as the reference)."
  @spec compare(t(), Ssimulacra2.image_data(), keyword()) ::
          {:ok, float()} | {:error, Ssimulacra2.reason()}
  def compare(%__MODULE__{} = ref, distorted, opts \\ []) when is_binary(distorted) do
    cancel = Keyword.get(opts, :cancel)

    with :ok <- Validate.size(distorted, ref.width, ref.height, ref.format),
         :ok <- Validate.cancel(cancel) do
      Cancellation.run(cancel, nil, fn resource ->
        Native.reference_compare(ref.resource, distorted, ref.width, ref.height, ref.format, resource)
      end)
    end
  end
```

Delete the now-unused `map_compare/1` from `lib/ssimulacra2/reference.ex` (its
mapping now lives in `Cancellation`). Keep `map_native/1` (used by `new/4`).

- [ ] **Step 7: Run the cancellation tests**

Run: `mise exec -- mix test test/ssimulacra2/cancellation_test.exs`
Expected: PASS.

- [ ] **Step 8: Run the full suite**

Run: `mise exec -- mix test`
Expected: PASS.

- [ ] **Step 9: Commit**

```bash
git add lib/ssimulacra2/cancellation.ex lib/ssimulacra2/validate.ex lib/ssimulacra2.ex lib/ssimulacra2/reference.ex test/ssimulacra2/cancellation_test.exs
git commit -m "feat: :cancel option for compare and Reference.compare

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Task 7: Wire the `:timeout` option

**Files:**
- Modify: `lib/ssimulacra2/cancellation.ex`
- Modify: `lib/ssimulacra2/validate.ex`
- Modify: `lib/ssimulacra2.ex`
- Modify: `lib/ssimulacra2/reference.ex`
- Test: `test/ssimulacra2/cancellation_test.exs` (extend)

- [ ] **Step 1: Write the failing tests**

Append to `test/ssimulacra2/cancellation_test.exs` (inside the module, before the
final `end`):

```elixir
  test "compare/5 returns {:error, :timeout} when it exceeds :timeout" do
    big = Fixtures.solid(2000, 2000, {10, 20, 30})
    assert {:error, :timeout} = Ssimulacra2.compare(big, big, 2000, 2000, timeout: 1)
  end

  test "Reference.compare/3 returns {:error, :timeout} when it exceeds :timeout" do
    big = Fixtures.solid(2000, 2000, {10, 20, 30})
    {:ok, ref} = Reference.new(big, 2000, 2000)
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
    big = Fixtures.solid(2500, 2500, {1, 2, 3})
    tok = CancellationToken.new()
    parent = self()

    task =
      Task.async(fn ->
        send(parent, :started)
        Ssimulacra2.compare(big, big, 2500, 2500, cancel: tok, timeout: 60_000)
      end)

    assert_receive :started, 1000
    Process.sleep(20)
    CancellationToken.cancel(tok)

    assert {:error, :cancelled} = Task.await(task, 30_000)
  end

  test "compare!/5 raises on timeout" do
    big = Fixtures.solid(2000, 2000, {10, 20, 30})
    assert_raise Ssimulacra2.Error, fn -> Ssimulacra2.compare!(big, big, 2000, 2000, timeout: 1) end
  end

  test "an invalid :timeout value is rejected" do
    img = Fixtures.gradient(64, 64)
    assert {:error, :invalid_timeout} = Ssimulacra2.compare(img, img, 64, 64, timeout: 0)
    assert {:error, :invalid_timeout} = Ssimulacra2.compare(img, img, 64, 64, timeout: -5)
  end
```

- [ ] **Step 2: Run them to confirm they fail**

Run: `mise exec -- mix test test/ssimulacra2/cancellation_test.exs`
Expected: FAIL — `:timeout` ignored (a real timeout will crash `Cancellation.run`
with no matching clause, or `:invalid_timeout` is not returned).

- [ ] **Step 3: Add timeout validation**

In `lib/ssimulacra2/validate.ex`, add:

```elixir
  @doc "Returns :ok or {:error, :invalid_timeout}."
  def timeout(nil), do: :ok
  def timeout(ms) when is_integer(ms) and ms > 0, do: :ok
  def timeout(_), do: {:error, :invalid_timeout}
```

- [ ] **Step 4: Add the timeout branch to `Cancellation.run`**

In `lib/ssimulacra2/cancellation.ex`, add a second `run/3` clause (after the
existing `nil`-timeout clause):

```elixir
  def run(cancel, timeout, invoke) when is_integer(timeout) and timeout > 0 do
    token = cancel || CancellationToken.new()
    parent = self()
    tag = make_ref()

    canceller =
      spawn(fn ->
        receive do
          {:done, ^tag} -> send(parent, {:status, tag, :not_timed_out})
        after
          timeout ->
            CancellationToken.cancel(token)
            send(parent, {:status, tag, :timed_out})
        end
      end)

    result = invoke.(token.resource)
    send(canceller, {:done, tag})
    status =
      receive do
        {:status, ^tag, s} -> s
      end

    map_result(result, status)
  end
```

- [ ] **Step 5: Pass `:timeout` through from `Ssimulacra2.compare/5`**

In `lib/ssimulacra2.ex`, update `compare/5` to read and validate `:timeout` and
pass it to `Cancellation.run`:

```elixir
  def compare(reference, distorted, width, height, opts \\ [])
      when is_binary(reference) and is_binary(distorted) do
    format = Keyword.get(opts, :format, :rgb888)
    cancel = Keyword.get(opts, :cancel)
    timeout = Keyword.get(opts, :timeout)

    with :ok <- Validate.format(format),
         :ok <- Validate.dims(width, height),
         :ok <- Validate.size(reference, width, height, format),
         :ok <- Validate.size(distorted, width, height, format),
         :ok <- Validate.cancel(cancel),
         :ok <- Validate.timeout(timeout) do
      Cancellation.run(cancel, timeout, fn resource ->
        Native.compare(reference, distorted, width, height, format, resource)
      end)
    end
  end
```

Extend `@type reason` with `:timeout` and `:invalid_timeout`:

```elixir
  @type reason ::
          :invalid_dimensions
          | :size_mismatch
          | :dimension_mismatch
          | :unknown_format
          | :invalid_cancel
          | :invalid_timeout
          | :cancelled
          | :timeout
          | {:ssimulacra2, String.t()}
```

- [ ] **Step 6: Pass `:timeout` through from `Reference.compare/3`**

In `lib/ssimulacra2/reference.ex`, update `compare/3`:

```elixir
  def compare(%__MODULE__{} = ref, distorted, opts \\ []) when is_binary(distorted) do
    cancel = Keyword.get(opts, :cancel)
    timeout = Keyword.get(opts, :timeout)

    with :ok <- Validate.size(distorted, ref.width, ref.height, ref.format),
         :ok <- Validate.cancel(cancel),
         :ok <- Validate.timeout(timeout) do
      Cancellation.run(cancel, timeout, fn resource ->
        Native.reference_compare(ref.resource, distorted, ref.width, ref.height, ref.format, resource)
      end)
    end
  end
```

- [ ] **Step 7: Run the cancellation tests**

Run: `mise exec -- mix test test/ssimulacra2/cancellation_test.exs`
Expected: PASS.

- [ ] **Step 8: Run the full suite**

Run: `mise exec -- mix test`
Expected: PASS.

- [ ] **Step 9: Commit**

```bash
git add lib/ssimulacra2/cancellation.ex lib/ssimulacra2/validate.ex lib/ssimulacra2.ex lib/ssimulacra2/reference.ex test/ssimulacra2/cancellation_test.exs
git commit -m "feat: :timeout option for compare and Reference.compare

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Task 8: Documentation

**Files:**
- Modify: `lib/ssimulacra2.ex` (moduledoc + `compare/5` doc)
- Modify: `lib/ssimulacra2/reference.ex` (`compare/3` doc)
- Modify: `README.md`

- [ ] **Step 1: Document the options on `Ssimulacra2.compare/5`**

In `lib/ssimulacra2.ex`, update the `compare/5` `@doc` to describe the new opts
(append to the existing doc text):

```
  ## Cancellation

  Pass `cancel:` an `Ssimulacra2.CancellationToken` to abort the comparison
  from another process (e.g. on client disconnect) — the call returns
  `{:error, :cancelled}`. Pass `timeout:` a positive integer of milliseconds to
  bound the wall-clock time — the call returns `{:error, :timeout}` if it
  exceeds that. Both may be combined; cancellation is checked at strip
  boundaries, so the CPU is freed promptly without leaving the dirty scheduler.

  Note: images smaller than 8 px on a side now return
  `{:error, {:ssimulacra2, _}}` rather than being upscaled-by-mirroring and
  scored.
```

- [ ] **Step 2: Document the options on `Reference.compare/3`**

In `lib/ssimulacra2/reference.ex`, update `compare/3`'s `@doc`:

```
  Accepts `cancel:` (an `Ssimulacra2.CancellationToken`) and `timeout:`
  (milliseconds) to abort an in-flight comparison; see `Ssimulacra2.compare/5`.
  Returns `{:error, :cancelled}` or `{:error, :timeout}` respectively.
```

- [ ] **Step 3: Add a cancellation section to the README**

In `README.md`, add a section (place it after the existing usage examples):

```markdown
## Cancellation & timeouts

Long comparisons can be aborted mid-computation:

​```elixir
# Wall-clock timeout — returns {:error, :timeout} if it overruns.
Ssimulacra2.compare(ref, dist, w, h, timeout: 3_000)

# External cancellation — trip the token from any process.
tok = Ssimulacra2.CancellationToken.new()
task = Task.async(fn -> Ssimulacra2.compare(ref, dist, w, h, cancel: tok) end)
# ... on client disconnect / shutdown:
Ssimulacra2.CancellationToken.cancel(tok)
Task.await(task)  #=> {:error, :cancelled}
​```

Both options work on `Ssimulacra2.Reference.compare/3` too. Cancellation is
cooperative (checked at strip boundaries) and frees the CPU promptly.

> **Build note:** while this library pins `fast-ssim2` to a git revision
> (pending an upstream release), it cannot be consumed via precompiled NIFs —
> build from source with `SSIMULACRA2_BUILD=1` or `config :ssimulacra2,
> force_build: true`.
```

(Remove the zero-width space characters shown around the code fences — they are
only here to keep this plan's Markdown intact.)

- [ ] **Step 4: Verify docs compile and the suite is green**

Run: `mise exec -- mix test`
Expected: PASS.

Run: `mise exec -- mix docs` (if `ex_doc` is available) or `mise exec -- mix compile --warnings-as-errors`
Expected: no doc/compile warnings.

- [ ] **Step 5: Commit**

```bash
git add lib/ssimulacra2.ex lib/ssimulacra2/reference.ex README.md
git commit -m "docs: document cancellation and timeout options

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Final verification

- [ ] Run the whole suite one more time: `mise exec -- mix test`
- [ ] Confirm `mise exec -- mix compile --warnings-as-errors` is clean.
- [ ] Sanity-check the diff: `git diff main --stat`.
```
