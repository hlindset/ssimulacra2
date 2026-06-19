# ssimulacra2 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a standalone Elixir/Hex library `ssimulacra2` (module `Ssimulacra2`) that wraps the Rust crate `fast-ssim2` via Rustler, exposing the SSIMULACRA2 perceptual metric (native 0–100 score) to Elixir from packed RGB888 binaries.

**Architecture:** A thin Rust NIF (`native/ssimulacra2_nif`) borrows Elixir binaries zero-copy as `ImgRef<[u8;3]>` and calls `fast-ssim2`, running on a dirty-CPU scheduler. Elixir does all argument validation before the NIF boundary. Two compute paths: one-shot `compare/4` and a reused-reference batch path (`Ssimulacra2.Reference`, backed by a Rustler `ResourceArc`). Distribution via `rustler_precompiled`. An optional `Ssimulacra2.Vix` helper (compiled only when `:vix` is present) converts Vix images to RGB888.

**Tech Stack:** Elixir 1.20.1 / Erlang OTP 29, Rust 1.96.0 (pinned via mise), Rustler 0.38.0, rustler_precompiled 0.9.0, fast-ssim2 0.8.2 (BSD-2-Clause), imgref 1.x, bytemuck 1.x.

**Toolchain note:** All `mix`/`cargo`/`iex` commands run through `mise exec --`. `fast-ssim2` 0.8.2 has MSRV 1.89.0, so the pinned Rust (1.96.0) is mandatory — the system Rust (1.85.1) cannot build it.

**Reference spec:** `docs/superpowers/specs/2026-06-19-ssimulacra2-design.md`

---

## File Structure

| File | Responsibility |
|---|---|
| `mise.toml` | Pin erlang/elixir/rust versions |
| `mix.exs` | Project + deps + hex package metadata |
| `lib/ssimulacra2.ex` | Public API: `compare/4`, `compare!/4`, validation, error mapping |
| `lib/ssimulacra2/reference.ex` | `%Ssimulacra2.Reference{}` struct + `new/3`, `compare/2` |
| `lib/ssimulacra2/native.ex` | `rustler_precompiled` load + NIF stub functions |
| `lib/ssimulacra2/error.ex` | `Ssimulacra2.Error` exception |
| `lib/ssimulacra2/vix.ex` | Optional Vix→RGB888 helper (guarded compile) |
| `native/ssimulacra2_nif/Cargo.toml` | Rust crate manifest (pinned deps) |
| `native/ssimulacra2_nif/Cargo.lock` | Committed lockfile |
| `native/ssimulacra2_nif/src/lib.rs` | NIF implementations |
| `test/ssimulacra2_test.exs` | Validation + one-shot compare tests |
| `test/ssimulacra2/reference_test.exs` | Reference batch path tests |
| `test/ssimulacra2/vix_test.exs` | Vix helper tests (`@tag :vix`) |
| `test/conformance_test.exs` | Cloudinary parity tests (`@tag :conformance`) |
| `test/support/fixtures.ex` | Helpers to synthesize RGB888 test binaries |
| `test/test_helper.exs` | Exclude `:conformance` and `:vix` by default |
| `.github/workflows/ci.yml` | mix test on pinned toolchain |
| `.github/workflows/release.yml` | Precompile NIF matrix on tag |
| `README.md` | Usage + score semantics |

---

## Task 1: Toolchain pin + project scaffold

**Files:**
- Create: `mise.toml`
- Create (via generator): `mix.exs`, `lib/ssimulacra2.ex`, `test/test_helper.exs`, `test/ssimulacra2_test.exs`, `.gitignore`, `.formatter.exs`

- [ ] **Step 1: Pin toolchain with mise**

Create `mise.toml`:

```toml
[tools]
erlang = "29.0.2"
elixir = "1.20.1-otp-29"
rust = "1.96.0"
```

- [ ] **Step 2: Install the pinned toolchain**

Run: `mise install`
Expected: erlang/elixir/rust resolve to the pinned versions (already cached versions are reused). Verify:

Run: `mise exec -- elixir --version && mise exec -- rustc --version`
Expected: Elixir 1.20.1 (OTP 29) and `rustc 1.96.0`.

- [ ] **Step 3: Scaffold the Mix project in-place**

The directory already contains `.git`, `.claude/`, and `docs/`. Generate into it:

Run: `mise exec -- mix new . --app ssimulacra2`
Expected: creates `lib/`, `test/`, `mix.exs`, `.gitignore`, `.formatter.exs`. Answer `Y` if prompted about the non-empty directory.

- [ ] **Step 4: Verify the bare project compiles and tests run**

Run: `mise exec -- mix test`
Expected: PASS — 1 doctest, 0 failures (the generated stub).

- [ ] **Step 5: Append build artifacts to .gitignore**

Add to `.gitignore`:

```gitignore
# Rust NIF build artifacts
/native/*/target/
# rustler_precompiled cached artifacts
/priv/native/
```

- [ ] **Step 6: Commit**

```bash
git add mise.toml mix.exs lib test .gitignore .formatter.exs
git commit -m "chore: scaffold mix project and pin toolchain via mise"
```

---

## Task 2: Rust NIF crate + smoke NIF end-to-end

This proves the full Elixir↔Rust pipeline compiles and loads before any real logic.

**Files:**
- Create: `native/ssimulacra2_nif/Cargo.toml`
- Create: `native/ssimulacra2_nif/src/lib.rs`
- Create: `lib/ssimulacra2/native.ex`
- Modify: `mix.exs` (add deps + remove default app stub if present)
- Test: `test/ssimulacra2_test.exs`

- [ ] **Step 1: Write the failing test for the smoke NIF**

Replace `test/ssimulacra2_test.exs` with:

```elixir
defmodule Ssimulacra2Test do
  use ExUnit.Case, async: true

  test "native library loads" do
    assert Ssimulacra2.Native.nif_loaded() == true
  end
end
```

- [ ] **Step 2: Run it to verify it fails**

Run: `mise exec -- mix test test/ssimulacra2_test.exs`
Expected: FAIL — `Ssimulacra2.Native.__struct__/0` undefined or module not available.

- [ ] **Step 3: Add deps to mix.exs**

In `mix.exs`, set `deps/0` to:

```elixir
defp deps do
  [
    {:rustler_precompiled, "~> 0.9"},
    {:rustler, ">= 0.0.0", optional: true},
    {:vix, "~> 0.31", optional: true},
    {:ex_doc, "~> 0.34", only: :dev, runtime: false}
  ]
end
```

- [ ] **Step 4: Create the Rust crate manifest**

Create `native/ssimulacra2_nif/Cargo.toml`:

```toml
[package]
name = "ssimulacra2_nif"
version = "0.1.0"
edition = "2021"
rust-version = "1.89"

[lib]
name = "ssimulacra2_nif"
crate-type = ["cdylib"]

[dependencies]
rustler = "0.38.0"
fast-ssim2 = "0.8.2"
imgref = "1"
bytemuck = "1"
```

- [ ] **Step 5: Write the smoke NIF**

Create `native/ssimulacra2_nif/src/lib.rs`:

```rust
#[rustler::nif]
fn nif_loaded() -> bool {
    true
}

rustler::init!("Elixir.Ssimulacra2.Native");
```

- [ ] **Step 6: Write the Native module**

Create `lib/ssimulacra2/native.ex`:

```elixir
defmodule Ssimulacra2.Native do
  @moduledoc false

  version = Mix.Project.config()[:version]

  use RustlerPrecompiled,
    otp_app: :ssimulacra2,
    crate: "ssimulacra2_nif",
    base_url: "https://github.com/hlindset/ssimulacra2/releases/download/v#{version}",
    version: version,
    # Build locally for now; flip to a release-gated condition once artifacts are published (Task 11).
    force_build: true,
    nif_versions: ["2.15", "2.16", "2.17"],
    targets: ~w(
      aarch64-apple-darwin
      x86_64-apple-darwin
      x86_64-unknown-linux-gnu
      aarch64-unknown-linux-gnu
      x86_64-unknown-linux-musl
      aarch64-unknown-linux-musl
      x86_64-pc-windows-msvc
    )

  def nif_loaded, do: :erlang.nif_error(:nif_not_loaded)
end
```

- [ ] **Step 7: Build the NIF and run the test**

Run: `mise exec -- mix deps.get && mise exec -- mix test test/ssimulacra2_test.exs`
Expected: PASS — the crate compiles (first build is slow), NIF loads, `nif_loaded/0` returns `true`.

- [ ] **Step 8: Commit (including Cargo.lock)**

```bash
git add native mix.exs mix.lock lib/ssimulacra2/native.ex test/ssimulacra2_test.exs
git add native/ssimulacra2_nif/Cargo.lock
git commit -m "feat: add rust nif crate with smoke nif loading end-to-end"
```

---

## Task 3: Argument validation (pure Elixir, no NIF)

**Files:**
- Modify: `lib/ssimulacra2.ex`
- Test: `test/ssimulacra2_test.exs`
- Create: `test/support/fixtures.ex`
- Modify: `test/test_helper.exs`

- [ ] **Step 1: Add a fixtures helper**

Create `test/support/fixtures.ex`:

```elixir
defmodule Ssimulacra2.Fixtures do
  @moduledoc false

  @doc "A solid-color RGB888 binary of the given size."
  def solid(width, height, {r, g, b}) do
    :binary.copy(<<r, g, b>>, width * height)
  end

  @doc "A deterministic gradient RGB888 binary (varies per pixel)."
  def gradient(width, height) do
    for y <- 0..(height - 1), x <- 0..(width - 1), into: <<>> do
      <<rem(x, 256), rem(y, 256), rem(x + y, 256)>>
    end
  end
end
```

- [ ] **Step 2: Compile test support**

In `mix.exs`, add to the project config a test elixirc path. Set:

```elixir
def project do
  [
    app: :ssimulacra2,
    version: "0.1.0",
    elixir: "~> 1.17",
    elixirc_paths: elixirc_paths(Mix.env()),
    start_permanent: Mix.env() == :prod,
    deps: deps(),
    description: "SSIMULACRA2 perceptual image-quality metric for Elixir (fast-ssim2 NIF)",
    package: package(),
    name: "Ssimulacra2",
    source_url: "https://github.com/hlindset/ssimulacra2"
  ]
end

defp elixirc_paths(:test), do: ["lib", "test/support"]
defp elixirc_paths(_), do: ["lib"]
```

(Add a `package/0` returning `[]` for now; filled in Task 11.)

- [ ] **Step 3: Write failing validation tests**

Replace `test/ssimulacra2_test.exs` with:

```elixir
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
```

- [ ] **Step 4: Run to verify failure**

Run: `mise exec -- mix test test/ssimulacra2_test.exs`
Expected: FAIL — `Ssimulacra2.compare/4` undefined.

- [ ] **Step 5: Implement validation (NIF call stubbed to a guard for now)**

Replace `lib/ssimulacra2.ex` with:

```elixir
defmodule Ssimulacra2 do
  @moduledoc """
  SSIMULACRA2 perceptual image-quality metric for Elixir, backed by the
  `fast-ssim2` Rust crate.

  Inputs are packed 8-bit sRGB `RGB888` binaries (`byte_size == width * height * 3`).
  The returned score is the native SSIMULACRA2 value on a 0–100 scale: 100 is
  pixel-identical, ~90+ is visually lossless, and low/negative values indicate
  large perceptual differences.
  """

  alias Ssimulacra2.Native

  @type rgb888 :: binary()
  @type reason :: :invalid_dimensions | :size_mismatch | {:ssimulacra2, String.t()}

  @doc """
  Compare a reference and distorted RGB888 image of the same dimensions.

  Returns `{:ok, score}` or `{:error, reason}`.
  """
  @spec compare(rgb888(), rgb888(), pos_integer(), pos_integer()) ::
          {:ok, float()} | {:error, reason()}
  def compare(reference, distorted, width, height)
      when is_binary(reference) and is_binary(distorted) do
    with :ok <- validate_dims(width, height),
         :ok <- validate_size(reference, width, height),
         :ok <- validate_size(distorted, width, height) do
      Native.compare(reference, distorted, width, height)
      |> map_native_error()
    end
  end

  @doc false
  def validate_dims(width, height)
      when is_integer(width) and is_integer(height) and width > 0 and height > 0,
      do: :ok

  def validate_dims(_, _), do: {:error, :invalid_dimensions}

  @doc false
  def validate_size(bin, width, height) do
    if byte_size(bin) == width * height * 3, do: :ok, else: {:error, :size_mismatch}
  end

  defp map_native_error({:ok, score}), do: {:ok, score}
  defp map_native_error({:error, message}), do: {:error, {:ssimulacra2, message}}
end
```

- [ ] **Step 6: Add a temporary Native.compare stub so validation tests pass**

In `lib/ssimulacra2/native.ex`, add below `nif_loaded`:

```elixir
  def compare(_reference, _distorted, _width, _height),
    do: :erlang.nif_error(:nif_not_loaded)
```

(The validation tests never reach the NIF — they fail validation first — so this stub is only for compile-time resolution.)

- [ ] **Step 7: Run validation tests**

Run: `mise exec -- mix test test/ssimulacra2_test.exs`
Expected: PASS — validation tests green, `native library loads` green.

- [ ] **Step 8: Commit**

```bash
git add lib/ssimulacra2.ex lib/ssimulacra2/native.ex mix.exs test
git commit -m "feat: add compare/4 argument validation"
```

---

## Task 4: Real one-shot compare NIF

**Files:**
- Modify: `native/ssimulacra2_nif/src/lib.rs`
- Test: `test/ssimulacra2_test.exs`

- [ ] **Step 1: Write the failing behavioral test**

Add to `test/ssimulacra2_test.exs` inside the module:

```elixir
  describe "compare/4 scoring" do
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
```

- [ ] **Step 2: Run to verify failure**

Run: `mise exec -- mix test test/ssimulacra2_test.exs`
Expected: FAIL — `:nif_not_loaded` (the stub) is raised by `Native.compare/4`.

- [ ] **Step 3: Implement the real compare NIF**

Replace `native/ssimulacra2_nif/src/lib.rs` with:

```rust
use fast_ssim2::compute_ssimulacra2;
use imgref::ImgRef;
use rustler::Binary;

#[rustler::nif]
fn nif_loaded() -> bool {
    true
}

/// Reinterpret a packed RGB888 byte slice as `ImgRef<[u8; 3]>` with stride = width.
/// Caller (Elixir) guarantees `bytes.len() == width * height * 3`.
fn as_imgref(bytes: &[u8], width: usize, height: usize) -> ImgRef<'_, [u8; 3]> {
    let pixels: &[[u8; 3]] = bytemuck::cast_slice(bytes);
    ImgRef::new(pixels, width, height)
}

#[rustler::nif(schedule = "DirtyCpu")]
fn compare(
    reference: Binary,
    distorted: Binary,
    width: usize,
    height: usize,
) -> Result<f64, String> {
    let r = as_imgref(reference.as_slice(), width, height);
    let d = as_imgref(distorted.as_slice(), width, height);
    compute_ssimulacra2(r, d)
        .map(|s| s as f64)
        .map_err(|e| e.to_string())
}

rustler::init!("Elixir.Ssimulacra2.Native");
```

- [ ] **Step 4: Remove the now-shadowing Elixir stub**

In `lib/ssimulacra2/native.ex`, delete the `def compare(...)` stub body and replace with a proper NIF stub (kept for when the NIF fails to load):

```elixir
  def compare(_reference, _distorted, _width, _height),
    do: :erlang.nif_error(:nif_not_loaded)
```

(Unchanged in shape — confirm it is still present exactly once. The real implementation comes from the loaded NIF and overrides this at load time.)

- [ ] **Step 5: Rebuild and run**

Run: `mise exec -- mix test test/ssimulacra2_test.exs`
Expected: PASS — identical ≈ 100, different < identical. (Rust recompiles.)

- [ ] **Step 6: Commit**

```bash
git add native/ssimulacra2_nif/src/lib.rs lib/ssimulacra2/native.ex test
git add native/ssimulacra2_nif/Cargo.lock
git commit -m "feat: implement one-shot SSIMULACRA2 compare/4"
```

---

## Task 5: compare!/4 + Ssimulacra2.Error

**Files:**
- Create: `lib/ssimulacra2/error.ex`
- Modify: `lib/ssimulacra2.ex`
- Test: `test/ssimulacra2_test.exs`

- [ ] **Step 1: Write the failing test**

Add to `test/ssimulacra2_test.exs`:

```elixir
  describe "compare!/4" do
    test "returns the bare score on success" do
      img = Fixtures.gradient(32, 32)
      assert Ssimulacra2.compare!(img, img, 32, 32) > 99.0
    end

    test "raises Ssimulacra2.Error on bad input" do
      assert_raise Ssimulacra2.Error, fn ->
        Ssimulacra2.compare!(<<>>, <<>>, 0, 0)
      end
    end
  end
```

- [ ] **Step 2: Run to verify failure**

Run: `mise exec -- mix test test/ssimulacra2_test.exs`
Expected: FAIL — `Ssimulacra2.compare!/4` undefined.

- [ ] **Step 3: Define the exception**

Create `lib/ssimulacra2/error.ex`:

```elixir
defmodule Ssimulacra2.Error do
  @moduledoc "Raised by the `!` variants when a comparison fails."
  defexception [:reason]

  @impl true
  def message(%__MODULE__{reason: reason}) do
    "ssimulacra2 comparison failed: #{inspect(reason)}"
  end
end
```

- [ ] **Step 4: Implement compare!/4**

Add to `lib/ssimulacra2.ex` after `compare/4`:

```elixir
  @doc """
  Like `compare/4` but returns the bare score and raises `Ssimulacra2.Error`
  on failure.
  """
  @spec compare!(rgb888(), rgb888(), pos_integer(), pos_integer()) :: float()
  def compare!(reference, distorted, width, height) do
    case compare(reference, distorted, width, height) do
      {:ok, score} -> score
      {:error, reason} -> raise Ssimulacra2.Error, reason: reason
    end
  end
```

- [ ] **Step 5: Run**

Run: `mise exec -- mix test test/ssimulacra2_test.exs`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add lib/ssimulacra2.ex lib/ssimulacra2/error.ex test
git commit -m "feat: add compare!/4 and Ssimulacra2.Error"
```

---

## Task 6: Reference batch path (ResourceArc)

**Files:**
- Modify: `native/ssimulacra2_nif/src/lib.rs`
- Modify: `lib/ssimulacra2/native.ex`
- Create: `lib/ssimulacra2/reference.ex`
- Test: `test/ssimulacra2/reference_test.exs`

- [ ] **Step 1: Write the failing test**

Create `test/ssimulacra2/reference_test.exs`:

```elixir
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
```

- [ ] **Step 2: Run to verify failure**

Run: `mise exec -- mix test test/ssimulacra2/reference_test.exs`
Expected: FAIL — `Ssimulacra2.Reference` undefined.

- [ ] **Step 3: Add resource + NIFs in Rust**

Replace `native/ssimulacra2_nif/src/lib.rs` with:

```rust
use fast_ssim2::{compute_ssimulacra2, Ssimulacra2Reference};
use imgref::ImgRef;
use rustler::{Binary, ResourceArc};

#[rustler::nif]
fn nif_loaded() -> bool {
    true
}

fn as_imgref(bytes: &[u8], width: usize, height: usize) -> ImgRef<'_, [u8; 3]> {
    let pixels: &[[u8; 3]] = bytemuck::cast_slice(bytes);
    ImgRef::new(pixels, width, height)
}

#[rustler::nif(schedule = "DirtyCpu")]
fn compare(
    reference: Binary,
    distorted: Binary,
    width: usize,
    height: usize,
) -> Result<f64, String> {
    let r = as_imgref(reference.as_slice(), width, height);
    let d = as_imgref(distorted.as_slice(), width, height);
    compute_ssimulacra2(r, d)
        .map(|s| s as f64)
        .map_err(|e| e.to_string())
}

/// Precomputed reference, owned by the BEAM and handed back as an opaque resource.
struct ReferenceResource {
    inner: Ssimulacra2Reference,
}

#[rustler::resource_impl]
impl rustler::Resource for ReferenceResource {}

#[rustler::nif(schedule = "DirtyCpu")]
fn reference_new(
    source: Binary,
    width: usize,
    height: usize,
) -> Result<ResourceArc<ReferenceResource>, String> {
    let src = as_imgref(source.as_slice(), width, height);
    let inner = Ssimulacra2Reference::new(src).map_err(|e| e.to_string())?;
    Ok(ResourceArc::new(ReferenceResource { inner }))
}

#[rustler::nif(schedule = "DirtyCpu")]
fn reference_compare(
    reference: ResourceArc<ReferenceResource>,
    distorted: Binary,
    width: usize,
    height: usize,
) -> Result<f64, String> {
    let d = as_imgref(distorted.as_slice(), width, height);
    reference
        .inner
        .compare(d)
        .map(|s| s as f64)
        .map_err(|e| e.to_string())
}

rustler::init!("Elixir.Ssimulacra2.Native");
```

**Note:** This assumes `Ssimulacra2Reference: Send + Sync` (required by `ResourceArc`). If the crate's type is not `Sync`, wrap it in a `std::sync::Mutex` inside `ReferenceResource` and lock in `reference_compare`. Verify by compiling — a missing bound surfaces as a clear compile error.

- [ ] **Step 4: Add NIF stubs in Native**

Add to `lib/ssimulacra2/native.ex`:

```elixir
  def reference_new(_source, _width, _height),
    do: :erlang.nif_error(:nif_not_loaded)

  def reference_compare(_reference, _distorted, _width, _height),
    do: :erlang.nif_error(:nif_not_loaded)
```

- [ ] **Step 5: Implement the Reference module**

Create `lib/ssimulacra2/reference.ex`:

```elixir
defmodule Ssimulacra2.Reference do
  @moduledoc """
  A precomputed SSIMULACRA2 reference image for efficient batch comparison.

  Build one with `new/3`, then call `compare/2` repeatedly against candidate
  images of the same dimensions. This reuses the reference's internal pyramid
  and is roughly twice as fast per comparison as `Ssimulacra2.compare/4` —
  ideal for a quality-search loop comparing many encodings against one original.
  """

  alias Ssimulacra2.Native

  @enforce_keys [:resource, :width, :height]
  defstruct [:resource, :width, :height]

  @type t :: %__MODULE__{resource: reference(), width: pos_integer(), height: pos_integer()}

  @doc "Precompute a reference from a packed RGB888 binary."
  @spec new(binary(), pos_integer(), pos_integer()) ::
          {:ok, t()} | {:error, Ssimulacra2.reason()}
  def new(source, width, height) when is_binary(source) do
    with :ok <- Ssimulacra2.validate_dims(width, height),
         :ok <- Ssimulacra2.validate_size(source, width, height),
         {:ok, resource} <- map_native(Native.reference_new(source, width, height)) do
      {:ok, %__MODULE__{resource: resource, width: width, height: height}}
    end
  end

  @doc "Compare a candidate RGB888 binary against the precomputed reference."
  @spec compare(t(), binary()) :: {:ok, float()} | {:error, Ssimulacra2.reason()}
  def compare(%__MODULE__{} = ref, distorted) when is_binary(distorted) do
    with :ok <- Ssimulacra2.validate_size(distorted, ref.width, ref.height) do
      Native.reference_compare(ref.resource, distorted, ref.width, ref.height)
      |> map_native()
    end
  end

  defp map_native({:ok, value}), do: {:ok, value}
  defp map_native({:error, message}) when is_binary(message), do: {:error, {:ssimulacra2, message}}
  defp map_native(other), do: {:ok, other}
end
```

**Note:** `reference_new` returns a bare resource term (not an `{:ok, _}` tuple) only when the NIF succeeds, but our Rust returns `Result<ResourceArc, String>` which rustler encodes as `{:ok, resource}` / `{:error, msg}` — so `map_native/1`'s first two clauses handle it; the `other` clause is defensive and unused in practice.

- [ ] **Step 6: Run**

Run: `mise exec -- mix test test/ssimulacra2/reference_test.exs`
Expected: PASS — batch matches one-shot within delta; size/dim validation works.

- [ ] **Step 7: Commit**

```bash
git add native/ssimulacra2_nif/src/lib.rs native/ssimulacra2_nif/Cargo.lock lib/ssimulacra2/native.ex lib/ssimulacra2/reference.ex test/ssimulacra2/reference_test.exs
git commit -m "feat: add Reference batch comparison path via ResourceArc"
```

---

## Task 7: Optional Vix helper

**Files:**
- Create: `lib/ssimulacra2/vix.ex`
- Test: `test/ssimulacra2/vix_test.exs`
- Modify: `test/test_helper.exs`

- [ ] **Step 1: Exclude :vix and :conformance tests by default**

Replace `test/test_helper.exs` with:

```elixir
ExUnit.start(exclude: [:vix, :conformance])
```

- [ ] **Step 2: Write the failing test (tagged :vix)**

Create `test/ssimulacra2/vix_test.exs`:

```elixir
defmodule Ssimulacra2.VixTest do
  use ExUnit.Case, async: true

  @moduletag :vix

  alias Vix.Vips.Image

  test "compare/2 scores identical Vix images ~100" do
    {:ok, img} = Image.new_from_buffer(black_png(), "")
    assert {:ok, score} = Ssimulacra2.Vix.compare(img, img)
    assert score > 99.0
  end

  # A 4x4 black PNG.
  defp black_png do
    Base.decode64!(
      "iVBORw0KGgoAAAANSUhEUgAAAAQAAAAECAYAAACp8Z5+AAAAEUlEQVR4nGNgYGD4z0AkYBxVCAAxAQH/JLAB+QAAAABJRU5ErkJggg=="
    )
  end
end
```

- [ ] **Step 3: Run to verify failure (with the vix tag included)**

Run: `mise exec -- mix test test/ssimulacra2/vix_test.exs --include vix`
Expected: FAIL — `Ssimulacra2.Vix` undefined (vix dep is present because it is `optional` but still fetched in dev/test).

- [ ] **Step 4: Implement the Vix helper (guarded compile)**

Create `lib/ssimulacra2/vix.ex`:

```elixir
if Code.ensure_loaded?(Vix.Vips.Image) do
  defmodule Ssimulacra2.Vix do
    @moduledoc """
    Convenience wrappers that accept `Vix.Vips.Image` structs.

    Only compiled when the optional `:vix` dependency is available. Images are
    coerced to 8-bit, 3-band sRGB (alpha flattened) before extraction, then
    handed to the core API as a packed RGB888 binary.
    """

    alias Vix.Vips.{Image, Operation}

    @doc "Compare two Vix images with `Ssimulacra2.compare/4`."
    @spec compare(Image.t(), Image.t()) :: {:ok, float()} | {:error, term()}
    def compare(%Image{} = reference, %Image{} = distorted) do
      with {:ok, {ref_bin, w, h}} <- to_rgb888(reference),
           {:ok, {dist_bin, ^w, ^h}} <- to_rgb888(distorted) do
        Ssimulacra2.compare(ref_bin, dist_bin, w, h)
      else
        {:ok, {_bin, _w2, _h2}} -> {:error, :dimension_mismatch}
        other -> other
      end
    end

    @doc "Build a `Ssimulacra2.Reference` from a Vix image."
    @spec reference(Image.t()) :: {:ok, Ssimulacra2.Reference.t()} | {:error, term()}
    def reference(%Image{} = image) do
      with {:ok, {bin, w, h}} <- to_rgb888(image) do
        Ssimulacra2.Reference.new(bin, w, h)
      end
    end

    # Coerce to sRGB, drop alpha, cast to 8-bit, extract packed RGB888.
    defp to_rgb888(%Image{} = image) do
      srgb = Operation.colourspace!(image, :VIPS_INTERPRETATION_sRGB)
      flat = if Image.has_alpha?(srgb), do: Operation.flatten!(srgb), else: srgb
      rgb = Operation.cast!(flat, :VIPS_FORMAT_UCHAR)

      case Image.write_to_binary(rgb) do
        {:ok, bin} -> {:ok, {bin, Image.width(rgb), Image.height(rgb)}}
        {:error, reason} -> {:error, reason}
      end
    end
  end
end
```

- [ ] **Step 5: Run the vix test**

Run: `mise exec -- mix test test/ssimulacra2/vix_test.exs --include vix`
Expected: PASS.

- [ ] **Step 6: Verify the default suite still excludes vix**

Run: `mise exec -- mix test`
Expected: PASS — vix test is skipped (excluded), everything else green.

- [ ] **Step 7: Commit**

```bash
git add lib/ssimulacra2/vix.ex test/ssimulacra2/vix_test.exs test/test_helper.exs
git commit -m "feat: add optional Vix.Vips.Image helper"
```

---

## Task 8: Conformance test scaffold + plan

This task sets up the **gating** external-parity check against the Cloudinary reference. It does not assert a guessed tolerance — it measures and documents the real deviation.

**Files:**
- Create: `test/conformance_test.exs`
- Create: `test/fixtures/conformance/README.md`
- Create: `docs/conformance-plan.md`

- [ ] **Step 1: Document the conformance plan**

Create `docs/conformance-plan.md`:

```markdown
# SSIMULACRA2 conformance plan

**Goal:** Validate that `ssimulacra2` (via `fast-ssim2`) produces scores in
agreement with the canonical Cloudinary reference implementation
(https://github.com/cloudinary/ssimulacra2), within a measured tolerance.

The crate's documented ~1e-5 internal agreement is between its own strip and
full-image code paths — NOT proven parity with Cloudinary. This plan establishes
the external check.

## Vectors

Assemble a small set of `(reference.png, distorted.png, expected_score)` cases:

1. Clone `cloudinary/ssimulacra2` and build the reference binary (C++), OR use
   any published score table from that repo / its issues if available.
2. Pick 6–10 image pairs spanning the score range: near-identical (recompressed
   at q95), moderate (q70), heavy (q30), a resize, a chroma-subsampled case.
3. For each pair, run the Cloudinary binary to get the authoritative score and
   record it in `test/fixtures/conformance/expected.json` as
   `[{"ref": "...", "dist": "...", "score": <float>}]`.
4. Store the PNGs under `test/fixtures/conformance/`.

## Tolerance

Run the Elixir implementation across all vectors, compute `abs(ours - reference)`
per case, and record the maximum. Set the test tolerance to a documented value
derived from that measurement (with a small margin), e.g. the observed max plus
headroom. If the deviation is large (> ~0.5 on the 0–100 scale), that is a
finding to investigate and surface — possibly a colorspace/gamma handling
difference — not something to paper over by widening tolerance.

## Running

Conformance tests are tagged `:conformance` and excluded by default. Run with:

    mise exec -- mix test --include conformance
```

- [ ] **Step 2: Create the fixtures placeholder**

Create `test/fixtures/conformance/README.md`:

```markdown
# Conformance fixtures

Place reference/distorted PNG pairs here plus `expected.json` with authoritative
Cloudinary scores. See `docs/conformance-plan.md`. These are intentionally not
committed until generated; the conformance test skips cleanly when absent.
```

- [ ] **Step 3: Write the conformance test (skips when fixtures absent)**

Create `test/conformance_test.exs`:

```elixir
defmodule Ssimulacra2.ConformanceTest do
  use ExUnit.Case, async: true

  @moduletag :conformance

  @fixtures_dir Path.join([__DIR__, "fixtures", "conformance"])
  @expected Path.join(@fixtures_dir, "expected.json")

  # Tolerance is set from the measured max deviation (see docs/conformance-plan.md).
  # Start strict; widen only with a documented, investigated reason.
  @tolerance 0.5

  test "matches Cloudinary reference scores within tolerance" do
    unless File.exists?(@expected) do
      flunk("""
      Conformance fixtures not found at #{@expected}.
      Generate them per docs/conformance-plan.md before running this test.
      """)
    end

    cases = @expected |> File.read!() |> :json.decode()

    for %{"ref" => ref, "dist" => dist, "score" => expected} <- cases do
      {:ok, ref_rgb, w, h} = load_rgb888(Path.join(@fixtures_dir, ref))
      {:ok, dist_rgb, ^w, ^h} = load_rgb888(Path.join(@fixtures_dir, dist))
      {:ok, score} = Ssimulacra2.compare(ref_rgb, dist_rgb, w, h)

      assert_in_delta score, expected, @tolerance,
        "#{ref} vs #{dist}: got #{score}, expected #{expected}"
    end
  end

  # Decode a PNG to packed RGB888 using Vix (test-only dependency path).
  defp load_rgb888(path) do
    alias Vix.Vips.{Image, Operation}
    {:ok, img} = Image.new_from_file(path)
    srgb = Operation.colourspace!(img, :VIPS_INTERPRETATION_sRGB)
    flat = if Image.has_alpha?(srgb), do: Operation.flatten!(srgb), else: srgb
    rgb = Operation.cast!(flat, :VIPS_FORMAT_UCHAR)
    {:ok, bin} = Image.write_to_binary(rgb)
    {:ok, bin, Image.width(rgb), Image.height(rgb)}
  end
end
```

- [ ] **Step 4: Verify it is excluded by default and flunks-with-guidance when included**

Run: `mise exec -- mix test`
Expected: PASS — conformance test excluded.

Run: `mise exec -- mix test --include conformance`
Expected: FAIL with the "fixtures not found" guidance (until vectors are generated). This is the expected pending state; generating vectors is the follow-up gating work tracked separately.

- [ ] **Step 5: Commit**

```bash
git add docs/conformance-plan.md test/fixtures/conformance/README.md test/conformance_test.exs
git commit -m "test: add conformance scaffold and plan against Cloudinary reference"
```

---

## Task 9: README + hex package metadata

**Files:**
- Create: `README.md`
- Modify: `mix.exs`

- [ ] **Step 1: Fill in package metadata**

In `mix.exs`, implement `package/0`:

```elixir
defp package do
  [
    licenses: ["BSD-2-Clause"],
    links: %{
      "GitHub" => "https://github.com/hlindset/ssimulacra2",
      "fast-ssim2" => "https://github.com/imazen/fast-ssim2"
    },
    files: ~w(lib native/ssimulacra2_nif/src native/ssimulacra2_nif/Cargo.toml
              native/ssimulacra2_nif/Cargo.lock mix.exs README.md checksum-*.exs)
  ]
end
```

- [ ] **Step 2: Write the README**

Create `README.md`:

```markdown
# ssimulacra2

SSIMULACRA2 perceptual image-quality metric for Elixir, backed by the
[`fast-ssim2`](https://github.com/imazen/fast-ssim2) Rust crate (BSD-2-Clause)
via Rustler. Precompiled NIFs mean **no Rust toolchain is required** to use it.

## Installation

    def deps do
      [{:ssimulacra2, "~> 0.1"}]
    end

## Usage

Inputs are packed 8-bit sRGB `RGB888` binaries (`byte_size == width * height * 3`).
Scores are on the native SSIMULACRA2 0–100 scale: 100 = identical, ~90+ ≈
visually lossless, lower (and negative) = larger perceptual difference.

    {:ok, score} = Ssimulacra2.compare(ref_rgb, dist_rgb, width, height)

For a quality-search loop comparing many candidates against one original, reuse
the reference (~2× faster per compare):

    {:ok, ref} = Ssimulacra2.Reference.new(original_rgb, width, height)
    {:ok, s1} = Ssimulacra2.Reference.compare(ref, candidate1_rgb)
    {:ok, s2} = Ssimulacra2.Reference.compare(ref, candidate2_rgb)

### With Vix

If `:vix` is a dependency, pass images directly:

    {:ok, score} = Ssimulacra2.Vix.compare(ref_image, dist_image)

## Status

v0.1 supports 8-bit sRGB input and the SSIMULACRA2 metric. 16-bit, linear-f32,
and plain-SSIM support are tracked as issues.

## License

This wrapper is released under BSD-2-Clause, matching `fast-ssim2`.
```

- [ ] **Step 3: Verify docs build and project compiles cleanly**

Run: `mise exec -- mix compile --warnings-as-errors && mise exec -- mix test`
Expected: PASS — no warnings, all non-excluded tests green.

- [ ] **Step 4: Commit**

```bash
git add README.md mix.exs
git commit -m "docs: add README and hex package metadata"
```

---

## Task 10: CI + precompile release workflows

**Files:**
- Create: `.github/workflows/ci.yml`
- Create: `.github/workflows/release.yml`

- [ ] **Step 1: CI workflow**

Create `.github/workflows/ci.yml`:

```yaml
name: CI
on:
  push:
    branches: [main]
  pull_request:

jobs:
  test:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: jdx/mise-action@v2
      - name: Install deps
        run: mise exec -- mix deps.get
      - name: Compile (warnings as errors)
        run: mise exec -- mix compile --warnings-as-errors
        env:
          SSIMULACRA2_BUILD: "1"
      - name: Test
        run: mise exec -- mix test
```

- [ ] **Step 2: Release / precompile workflow**

Create `.github/workflows/release.yml`:

```yaml
name: Build precompiled NIFs
on:
  push:
    tags: ["v*"]

jobs:
  build_release:
    name: NIF ${{ matrix.nif }} - ${{ matrix.job.target }}
    runs-on: ${{ matrix.job.os }}
    permissions:
      contents: write
    strategy:
      fail-fast: false
      matrix:
        nif: ["2.16", "2.15"]
        job:
          - { target: aarch64-apple-darwin, os: macos-14 }
          - { target: x86_64-apple-darwin, os: macos-13 }
          - { target: x86_64-unknown-linux-gnu, os: ubuntu-22.04 }
          - { target: aarch64-unknown-linux-gnu, os: ubuntu-22.04, use-cross: true }
          - { target: x86_64-unknown-linux-musl, os: ubuntu-22.04, use-cross: true }
          - { target: aarch64-unknown-linux-musl, os: ubuntu-22.04, use-cross: true }
          - { target: x86_64-pc-windows-msvc, os: windows-2022 }
    steps:
      - uses: actions/checkout@v4
      - uses: philss/rustler-precompiled-action@v1.1.4
        with:
          project-name: ssimulacra2_nif
          project-version: ${{ github.ref_name }}
          target: ${{ matrix.job.target }}
          nif-version: ${{ matrix.nif }}
          use-cross: ${{ matrix.job.use-cross }}
          project-dir: "native/ssimulacra2_nif"
```

**Note:** `philss/rustler-precompiled-action` provisions the Rust toolchain itself; it does not use mise. Pin `rust-version` in `native/ssimulacra2_nif/Cargo.toml` (already set to `1.89`) so the action's toolchain satisfies fast-ssim2's MSRV; bump it if the action's default Rust is older.

- [ ] **Step 3: Commit**

```bash
git add .github/workflows
git commit -m "ci: add test workflow and precompiled NIF release workflow"
```

---

## Task 11: Release-gate force_build + file deferred-format issues + push

**Files:**
- Modify: `lib/ssimulacra2/native.ex`

- [ ] **Step 1: Make force_build release-aware**

In `lib/ssimulacra2/native.ex`, replace `force_build: true` with:

```elixir
    force_build:
      System.get_env("SSIMULACRA2_BUILD") in ["1", "true"] or
        Application.compile_env(:ssimulacra2, :force_build, false),
```

(Once a tagged release with precompiled artifacts exists, consumers download them; local dev/CI opts in via `SSIMULACRA2_BUILD=1`. Set `config :ssimulacra2, force_build: true` in this lib's own dev/test config so its own suite always builds.)

Create `config/config.exs`:

```elixir
import Config
if config_env() in [:dev, :test], do: config(:ssimulacra2, force_build: true)
```

- [ ] **Step 2: Verify the suite still builds and passes**

Run: `mise exec -- mix test`
Expected: PASS.

- [ ] **Step 3: Commit**

```bash
git add lib/ssimulacra2/native.ex config/config.exs
git commit -m "chore: gate force_build behind env/config for release readiness"
```

- [ ] **Step 4: File deferred-format tracking issues**

Run each:

```bash
gh issue create --repo hlindset/ssimulacra2 \
  --title "Support 16-bit sRGB input (ImgRef<[u16;3]>)" \
  --body "fast-ssim2 accepts ImgRef<[u16;3]> for 16-bit sRGB. Add a compare path (RGB161616 binary, byte_size == w*h*6) and validation. Deferred from v1 (see docs/superpowers/specs/2026-06-19-ssimulacra2-design.md)."

gh issue create --repo hlindset/ssimulacra2 \
  --title "Support linear f32 input (ImgRef<[f32;3]>)" \
  --body "fast-ssim2 accepts ImgRef<[f32;3]> as linear RGB. Add a compare path for f32 binaries. Deferred from v1."

gh issue create --repo hlindset/ssimulacra2 \
  --title "Investigate exposing plain SSIM" \
  --body "fast-ssim2 is SSIMULACRA2-specific and does not expose a general SSIM. Decide whether plain SSIM is worth a separate implementation/crate. Deferred from v1; likely out of scope for the #344 use case."
```

Expected: three issue URLs printed.

- [ ] **Step 5: Push to origin**

```bash
git push -u origin main
```

Expected: branch published to `https://github.com/hlindset/ssimulacra2`.

---

## Self-Review Notes

- **Spec coverage:** binary-core API (Tasks 3–5), Reference batch path (Task 6), optional Vix helper (Task 7), native 0–100 score (Task 4), dirty scheduler (Task 4/6), error handling (Tasks 3/5), rustler_precompiled distribution (Tasks 2/10/11), conformance gating (Task 8), deferred-format issues (Task 11), standalone repo + push (Task 11). All covered.
- **Score type:** `fast-ssim2` returns `f32`; the NIF casts to `f64` (Tasks 4/6). Tests assert ranges, not exact equality.
- **Reference resource Send+Sync:** flagged in Task 6 Step 3 with a Mutex fallback if the bound is missing.
- **force_build:** starts `true` (Task 2) for local-only dev, then release-gated (Task 11) — consistent across tasks.
- **Open value:** conformance tolerance is intentionally measured (Task 8), not guessed — matches the spec's empirical-tolerance decision.
```

