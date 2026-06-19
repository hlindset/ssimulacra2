# Remaining Input Formats Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let `Ssimulacra2.compare` and `Ssimulacra2.Reference` accept `:rgb16`, `:linear_rgb`, `:gray8`, and `:linear_gray` inputs via a `format:` option (default `:rgb888`), and make the Vix bridge preserve 16-bit sources.

**Architecture:** A format atom threads from the Elixir API down to the Rust NIF. Elixir validates the format and the binary's byte size against a single format table; Rust decodes the atom to a `Format` enum and builds the matching `ImgRef`/`ImgVec` before calling `fast_ssim2`'s generic `compute_ssimulacra2` / `Ssimulacra2Reference`. Multi-byte element formats (`u16`, `f32`) are copied into owned, aligned `Vec`s to stay safe on unaligned BEAM sub-binaries.

**Tech Stack:** Elixir, Rustler 0.38, `fast-ssim2` 0.8.2 (`imgref` feature), `imgref`, `bytemuck`, ExUnit, optional Vix.

**Conventions used throughout:** integer element ⇒ sRGB gamma, float element ⇒ linear RGB. Multi-byte elements are native-endian. Format table (atom → `{channels, element_bytes}`): `rgb888 {3,1}`, `rgb16 {3,2}`, `linear_rgb {3,4}`, `gray8 {1,1}`, `linear_gray {1,4}`.

**Build/test note:** the NIF is loaded precompiled by default. To build from source and run tests in this worktree, prefix with `SSIMULACRA2_BUILD=1` and run via mise, e.g. `SSIMULACRA2_BUILD=1 mise exec -- mix test`.

---

## File structure

- `native/ssimulacra2_nif/src/lib.rs` — **rewrite**: `Format` enum + atom decode, per-format builders, generic `score`/`build_reference` helpers, three NIFs gain a `format` atom arg.
- `lib/ssimulacra2/native.ex` — modify: three stubs gain a `format` arg.
- `lib/ssimulacra2/validate.ex` — modify: add format table, `format/1`, format-aware `size/4`.
- `lib/ssimulacra2.ex` — modify: `compare/5` + `compare!/5` with `opts`; add `:unknown_format` to `reason()`.
- `lib/ssimulacra2/reference.ex` — modify: `new/4` + `new!/4` with `opts`; struct stores `:format`; `compare/2` validates against stored format.
- `lib/ssimulacra2/vix.ex` — modify: branch on source bit depth (`:VIPS_FORMAT_UCHAR` ⇒ `:rgb888`, else `:rgb16`).
- `test/support/fixtures.ex` — modify: gradient + solid generators per new format.
- `test/ssimulacra2/formats_test.exs` — **create**: per-format scoring/validation, unknown-format, alignment regression.
- `test/ssimulacra2/reference_test.exs` — modify: per-format reference parity + stored-format validation.
- `test/ssimulacra2/vix_test.exs` — modify: replace the downscale-locking test with bit-depth-preservation tests.
- `README.md` — modify: document formats; update Status.

---

## Task 1: NIF boundary — thread a `format` atom through Rust (rgb888 only)

This is a structural refactor. No new public behavior; existing tests are the regression net. It establishes the full Rust machinery for **all** formats so later tasks need no Rust changes.

**Files:**
- Rewrite: `native/ssimulacra2_nif/src/lib.rs`
- Modify: `lib/ssimulacra2/native.ex:27-34`
- Modify: `lib/ssimulacra2.ex:30` and `lib/ssimulacra2/reference.ex:24,33`

- [ ] **Step 1: Rewrite the Rust NIF**

Replace the entire contents of `native/ssimulacra2_nif/src/lib.rs` with:

```rust
use fast_ssim2::{compute_ssimulacra2, Ssimulacra2Reference, ToLinearRgb};
use imgref::{ImgRef, ImgVec};
use rustler::{Atom, Binary, ResourceArc};

mod atoms {
    rustler::atoms! {
        rgb888,
        rgb16,
        linear_rgb,
        gray8,
        linear_gray,
    }
}

#[rustler::nif]
fn nif_loaded() -> bool {
    true
}

enum Format {
    Rgb888,
    Rgb16,
    LinearRgb,
    Gray8,
    LinearGray,
}

impl Format {
    fn from_atom(a: Atom) -> Result<Self, String> {
        if a == atoms::rgb888() {
            Ok(Format::Rgb888)
        } else if a == atoms::rgb16() {
            Ok(Format::Rgb16)
        } else if a == atoms::linear_rgb() {
            Ok(Format::LinearRgb)
        } else if a == atoms::gray8() {
            Ok(Format::Gray8)
        } else if a == atoms::linear_gray() {
            Ok(Format::LinearGray)
        } else {
            Err("unknown format".to_string())
        }
    }
}

// Per-format builders. 8-bit element types (align 1) borrow the binary
// directly. Multi-byte element types are copied into an owned, aligned Vec
// via from_ne_bytes: BEAM (sub-)binaries are not guaranteed to be 2-/4-byte
// aligned, and bytemuck::cast_slice would panic on a misaligned slice.

fn rgb888(b: &[u8], w: usize, h: usize) -> ImgRef<'_, [u8; 3]> {
    ImgRef::new(bytemuck::cast_slice(b), w, h)
}

fn gray8(b: &[u8], w: usize, h: usize) -> ImgRef<'_, u8> {
    ImgRef::new(b, w, h)
}

fn rgb16(b: &[u8], w: usize, h: usize) -> ImgVec<[u16; 3]> {
    let px: Vec<[u16; 3]> = b
        .chunks_exact(6)
        .map(|c| {
            [
                u16::from_ne_bytes([c[0], c[1]]),
                u16::from_ne_bytes([c[2], c[3]]),
                u16::from_ne_bytes([c[4], c[5]]),
            ]
        })
        .collect();
    ImgVec::new(px, w, h)
}

fn linear_rgb(b: &[u8], w: usize, h: usize) -> ImgVec<[f32; 3]> {
    let px: Vec<[f32; 3]> = b
        .chunks_exact(12)
        .map(|c| {
            [
                f32::from_ne_bytes([c[0], c[1], c[2], c[3]]),
                f32::from_ne_bytes([c[4], c[5], c[6], c[7]]),
                f32::from_ne_bytes([c[8], c[9], c[10], c[11]]),
            ]
        })
        .collect();
    ImgVec::new(px, w, h)
}

fn linear_gray(b: &[u8], w: usize, h: usize) -> ImgVec<f32> {
    let px: Vec<f32> = b
        .chunks_exact(4)
        .map(|c| f32::from_ne_bytes([c[0], c[1], c[2], c[3]]))
        .collect();
    ImgVec::new(px, w, h)
}

fn score<S: ToLinearRgb, D: ToLinearRgb>(s: S, d: D) -> Result<f64, String> {
    compute_ssimulacra2(s, d).map_err(|e| e.to_string())
}

#[rustler::nif(schedule = "DirtyCpu")]
fn compare(
    reference: Binary,
    distorted: Binary,
    width: usize,
    height: usize,
    format: Atom,
) -> Result<f64, String> {
    let (r, d, w, h) = (reference.as_slice(), distorted.as_slice(), width, height);
    match Format::from_atom(format)? {
        Format::Rgb888 => score(rgb888(r, w, h), rgb888(d, w, h)),
        Format::Gray8 => score(gray8(r, w, h), gray8(d, w, h)),
        Format::Rgb16 => {
            let (a, b) = (rgb16(r, w, h), rgb16(d, w, h));
            score(a.as_ref(), b.as_ref())
        }
        Format::LinearRgb => {
            let (a, b) = (linear_rgb(r, w, h), linear_rgb(d, w, h));
            score(a.as_ref(), b.as_ref())
        }
        Format::LinearGray => {
            let (a, b) = (linear_gray(r, w, h), linear_gray(d, w, h));
            score(a.as_ref(), b.as_ref())
        }
    }
}

struct ReferenceResource {
    inner: Ssimulacra2Reference,
}

#[rustler::resource_impl]
impl rustler::Resource for ReferenceResource {}

fn build_reference<S: ToLinearRgb>(src: S) -> Result<ResourceArc<ReferenceResource>, String> {
    let inner = Ssimulacra2Reference::new(src).map_err(|e| e.to_string())?;
    Ok(ResourceArc::new(ReferenceResource { inner }))
}

#[rustler::nif(schedule = "DirtyCpu")]
fn reference_new(
    source: Binary,
    width: usize,
    height: usize,
    format: Atom,
) -> Result<ResourceArc<ReferenceResource>, String> {
    let (s, w, h) = (source.as_slice(), width, height);
    match Format::from_atom(format)? {
        Format::Rgb888 => build_reference(rgb888(s, w, h)),
        Format::Gray8 => build_reference(gray8(s, w, h)),
        Format::Rgb16 => build_reference(rgb16(s, w, h).as_ref()),
        Format::LinearRgb => build_reference(linear_rgb(s, w, h).as_ref()),
        Format::LinearGray => build_reference(linear_gray(s, w, h).as_ref()),
    }
}

#[rustler::nif(schedule = "DirtyCpu")]
fn reference_compare(
    reference: ResourceArc<ReferenceResource>,
    distorted: Binary,
    width: usize,
    height: usize,
    format: Atom,
) -> Result<f64, String> {
    let (d, w, h) = (distorted.as_slice(), width, height);
    let r = &reference.inner;
    match Format::from_atom(format)? {
        Format::Rgb888 => r.compare(rgb888(d, w, h)).map_err(|e| e.to_string()),
        Format::Gray8 => r.compare(gray8(d, w, h)).map_err(|e| e.to_string()),
        Format::Rgb16 => r.compare(rgb16(d, w, h).as_ref()).map_err(|e| e.to_string()),
        Format::LinearRgb => r
            .compare(linear_rgb(d, w, h).as_ref())
            .map_err(|e| e.to_string()),
        Format::LinearGray => r
            .compare(linear_gray(d, w, h).as_ref())
            .map_err(|e| e.to_string()),
    }
}

rustler::init!("Elixir.Ssimulacra2.Native");
```

- [ ] **Step 2: Update the Native stubs to the new arities**

In `lib/ssimulacra2/native.ex`, replace the three stub definitions (lines 27-34) with:

```elixir
  def compare(_reference, _distorted, _width, _height, _format),
    do: :erlang.nif_error(:nif_not_loaded)

  def reference_new(_source, _width, _height, _format),
    do: :erlang.nif_error(:nif_not_loaded)

  def reference_compare(_reference, _distorted, _width, _height, _format),
    do: :erlang.nif_error(:nif_not_loaded)
```

- [ ] **Step 3: Pass `:rgb888` from the Elixir callers (no public API change yet)**

In `lib/ssimulacra2.ex`, change the `Native.compare` call (line 30) to:

```elixir
      Native.compare(reference, distorted, width, height, :rgb888)
```

In `lib/ssimulacra2/reference.ex`, change the `Native.reference_new` call (line 24) to:

```elixir
         {:ok, resource} <- map_native(Native.reference_new(source, width, height, :rgb888)) do
```

and the `Native.reference_compare` call (line 33) to:

```elixir
      Native.reference_compare(ref.resource, distorted, ref.width, ref.height, :rgb888)
```

- [ ] **Step 4: Build from source and run the full suite (regression must stay green)**

Run: `SSIMULACRA2_BUILD=1 mise exec -- mix test --include vix`
Expected: PASS — `17 tests, 0 failures` (same behavior as before; this task only restructures the NIF boundary).

- [ ] **Step 5: Commit**

```bash
git add native/ssimulacra2_nif/src/lib.rs lib/ssimulacra2/native.ex lib/ssimulacra2.ex lib/ssimulacra2/reference.ex
git commit -m "refactor: thread a format atom through the NIF boundary"
```

---

## Task 2: Format table + core `compare`/`compare!` format option

**Files:**
- Modify: `lib/ssimulacra2/validate.ex`
- Modify: `lib/ssimulacra2.ex`
- Modify: `lib/ssimulacra2/reference.ex:22-26,31-34` (switch to `size/4` with `:rgb888`)
- Modify: `test/support/fixtures.ex`
- Create: `test/ssimulacra2/formats_test.exs`

- [ ] **Step 1: Add format fixtures**

Append these functions to `test/support/fixtures.ex`, inside the module (before the final `end`):

```elixir
  @doc "A deterministic 16-bit sRGB gradient (native-endian, w*h*6 bytes)."
  def gradient_rgb16(width, height) do
    for y <- 0..(height - 1), x <- 0..(width - 1), into: <<>> do
      <<rem(x * 257, 65_536)::native-16, rem(y * 257, 65_536)::native-16,
        rem((x + y) * 257, 65_536)::native-16>>
    end
  end

  @doc "A solid-color 16-bit sRGB binary."
  def solid_rgb16(width, height, {r, g, b}) do
    :binary.copy(<<r::native-16, g::native-16, b::native-16>>, width * height)
  end

  @doc "A deterministic linear-RGB f32 gradient in [0,1] (native-endian, w*h*12 bytes)."
  def gradient_linear_rgb(width, height) do
    for y <- 0..(height - 1), x <- 0..(width - 1), into: <<>> do
      <<(rem(x, 256) / 255)::native-float-32, (rem(y, 256) / 255)::native-float-32,
        (rem(x + y, 256) / 255)::native-float-32>>
    end
  end

  @doc "A solid linear-RGB f32 binary (each channel = v)."
  def solid_linear_rgb(width, height, v) do
    :binary.copy(<<v::native-float-32, v::native-float-32, v::native-float-32>>, width * height)
  end

  @doc "A deterministic 8-bit grayscale gradient (w*h bytes)."
  def gradient_gray8(width, height) do
    for y <- 0..(height - 1), x <- 0..(width - 1), into: <<>> do
      <<rem(x + y, 256)>>
    end
  end

  @doc "A solid 8-bit grayscale binary."
  def solid_gray8(width, height, v) do
    :binary.copy(<<v>>, width * height)
  end

  @doc "A deterministic linear grayscale f32 gradient in [0,1] (w*h*4 bytes)."
  def gradient_linear_gray(width, height) do
    for y <- 0..(height - 1), x <- 0..(width - 1), into: <<>> do
      <<(rem(x + y, 256) / 255)::native-float-32>>
    end
  end

  @doc "A solid linear grayscale f32 binary."
  def solid_linear_gray(width, height, v) do
    :binary.copy(<<v::native-float-32>>, width * height)
  end
```

- [ ] **Step 2: Write the failing format test file**

Create `test/ssimulacra2/formats_test.exs`:

```elixir
defmodule Ssimulacra2.FormatsTest do
  use ExUnit.Case, async: true
  alias Ssimulacra2.Fixtures

  @dim 64

  # {format, reference binary, a visibly different binary}
  @cases [
    {:rgb16, Fixtures.gradient_rgb16(@dim, @dim),
     Fixtures.solid_rgb16(@dim, @dim, {40_000, 20_000, 10_000})},
    {:linear_rgb, Fixtures.gradient_linear_rgb(@dim, @dim),
     Fixtures.solid_linear_rgb(@dim, @dim, 0.5)},
    {:gray8, Fixtures.gradient_gray8(@dim, @dim), Fixtures.solid_gray8(@dim, @dim, 128)},
    {:linear_gray, Fixtures.gradient_linear_gray(@dim, @dim),
     Fixtures.solid_linear_gray(@dim, @dim, 0.5)}
  ]

  for {fmt, ref_bin, alt_bin} <- @cases do
    @fmt fmt
    @ref_bin ref_bin
    @alt_bin alt_bin

    describe "format #{fmt}" do
      test "identical images score ~100" do
        assert {:ok, s} = Ssimulacra2.compare(@ref_bin, @ref_bin, @dim, @dim, format: @fmt)
        assert s > 99.0
      end

      test "different images score lower than identical" do
        {:ok, same} = Ssimulacra2.compare(@ref_bin, @ref_bin, @dim, @dim, format: @fmt)
        {:ok, diff} = Ssimulacra2.compare(@ref_bin, @alt_bin, @dim, @dim, format: @fmt)
        assert diff < same
      end

      test "rejects a wrong-size binary" do
        assert {:error, :size_mismatch} =
                 Ssimulacra2.compare(@ref_bin, <<0, 1, 2>>, @dim, @dim, format: @fmt)
      end
    end
  end

  test "unknown format is rejected" do
    img = Fixtures.gradient_rgb16(8, 8)
    assert {:error, :unknown_format} = Ssimulacra2.compare(img, img, 8, 8, format: :bogus)
  end

  test "default format is :rgb888" do
    img = Fixtures.gradient(64, 64)
    assert {:ok, with_opt} = Ssimulacra2.compare(img, img, 64, 64, format: :rgb888)
    assert {:ok, default} = Ssimulacra2.compare(img, img, 64, 64)
    assert with_opt == default
  end
end
```

- [ ] **Step 3: Run it to confirm it fails**

Run: `SSIMULACRA2_BUILD=1 mise exec -- mix test test/ssimulacra2/formats_test.exs`
Expected: FAIL — `Ssimulacra2.compare/5` is undefined (the public function is still arity 4).

- [ ] **Step 4: Add the format table and format-aware size to Validate**

Replace the entire body of `lib/ssimulacra2/validate.ex` with:

```elixir
defmodule Ssimulacra2.Validate do
  @moduledoc false

  # atom => {channels, bytes_per_element}
  @formats %{
    rgb888: {3, 1},
    rgb16: {3, 2},
    linear_rgb: {3, 4},
    gray8: {1, 1},
    linear_gray: {1, 4}
  }

  @doc "Returns :ok or {:error, :invalid_dimensions}."
  def dims(width, height)
      when is_integer(width) and is_integer(height) and width > 0 and height > 0,
      do: :ok

  def dims(_, _), do: {:error, :invalid_dimensions}

  @doc "Returns :ok or {:error, :unknown_format}."
  def format(fmt) when is_map_key(@formats, fmt), do: :ok
  def format(_), do: {:error, :unknown_format}

  @doc """
  Returns :ok or {:error, :size_mismatch} for a packed binary of the given
  format. The format MUST be valid (call `format/1` first).
  """
  def size(bin, width, height, format) do
    {channels, elem_bytes} = Map.fetch!(@formats, format)

    if byte_size(bin) == width * height * channels * elem_bytes,
      do: :ok,
      else: {:error, :size_mismatch}
  end
end
```

- [ ] **Step 5: Add the `format:` option to the core API**

In `lib/ssimulacra2.ex`:

Update the `reason()` type (line 15-16) to include `:unknown_format`:

```elixir
  @type reason ::
          :invalid_dimensions
          | :size_mismatch
          | :dimension_mismatch
          | :unknown_format
          | {:ssimulacra2, String.t()}
```

Replace `compare/4` (lines 23-33) with:

```elixir
  @spec compare(rgb888(), rgb888(), pos_integer(), pos_integer(), keyword()) ::
          {:ok, float()} | {:error, reason()}
  def compare(reference, distorted, width, height, opts \\ [])
      when is_binary(reference) and is_binary(distorted) do
    format = Keyword.get(opts, :format, :rgb888)

    with :ok <- Validate.format(format),
         :ok <- Validate.dims(width, height),
         :ok <- Validate.size(reference, width, height, format),
         :ok <- Validate.size(distorted, width, height, format) do
      Native.compare(reference, distorted, width, height, format)
      |> map_native_error()
    end
  end
```

Replace `compare!/4` (lines 39-45) with:

```elixir
  @spec compare!(rgb888(), rgb888(), pos_integer(), pos_integer(), keyword()) :: float()
  def compare!(reference, distorted, width, height, opts \\ []) do
    case compare(reference, distorted, width, height, opts) do
      {:ok, score} -> score
      {:error, reason} -> raise Ssimulacra2.Error, reason: reason
    end
  end
```

- [ ] **Step 6: Keep Reference compiling against the new `size/4`**

In `lib/ssimulacra2/reference.ex`, update both `Validate.size` calls to the 4-arity form with `:rgb888` (the public Reference format option lands in Task 3):

Line 23 (inside `new/3`):

```elixir
         :ok <- Validate.size(source, width, height, :rgb888),
```

Line 32 (inside `compare/2`):

```elixir
    with :ok <- Validate.size(distorted, ref.width, ref.height, :rgb888) do
```

- [ ] **Step 7: Run the format tests and the full suite**

Run: `SSIMULACRA2_BUILD=1 mise exec -- mix test test/ssimulacra2/formats_test.exs`
Expected: PASS.

Run: `SSIMULACRA2_BUILD=1 mise exec -- mix test --include vix`
Expected: PASS (existing tests unaffected).

- [ ] **Step 8: Commit**

```bash
git add lib/ssimulacra2/validate.ex lib/ssimulacra2.ex lib/ssimulacra2/reference.ex test/support/fixtures.ex test/ssimulacra2/formats_test.exs
git commit -m "feat: format option for Ssimulacra2.compare"
```

---

## Task 3: `Reference` format option

**Files:**
- Modify: `lib/ssimulacra2/reference.ex`
- Modify: `test/ssimulacra2/reference_test.exs`

- [ ] **Step 1: Write failing reference-format tests**

Append these tests to `test/ssimulacra2/reference_test.exs`, inside the module (before the final `end`):

```elixir
  test "new/4 + compare/2 matches one-shot compare for :rgb16" do
    ref_img = Fixtures.gradient_rgb16(64, 64)
    cand = Fixtures.solid_rgb16(64, 64, {40_000, 20_000, 10_000})

    {:ok, oneshot} = Ssimulacra2.compare(ref_img, cand, 64, 64, format: :rgb16)
    {:ok, ref} = Reference.new(ref_img, 64, 64, format: :rgb16)
    {:ok, batch} = Reference.compare(ref, cand)

    assert_in_delta oneshot, batch, 1.0e-4
  end

  test "compare/2 validates the candidate against the reference's stored format" do
    {:ok, ref} = Reference.new(Fixtures.gradient_rgb16(64, 64), 64, 64, format: :rgb16)
    # An RGB888-sized binary (w*h*3) is the wrong size for :rgb16 (needs w*h*6).
    assert {:error, :size_mismatch} = Reference.compare(ref, Fixtures.solid(64, 64, {0, 0, 0}))
  end

  test "new/4 rejects an unknown format" do
    assert {:error, :unknown_format} =
             Reference.new(Fixtures.gradient_rgb16(8, 8), 8, 8, format: :bogus)
  end
```

- [ ] **Step 2: Run them to confirm they fail**

Run: `SSIMULACRA2_BUILD=1 mise exec -- mix test test/ssimulacra2/reference_test.exs`
Expected: FAIL — `Reference.new/4` is undefined.

- [ ] **Step 3: Add the format option to Reference**

In `lib/ssimulacra2/reference.ex`:

Replace the struct/type block (lines 13-16) with:

```elixir
  @enforce_keys [:resource, :width, :height, :format]
  defstruct [:resource, :width, :height, :format]

  @type t :: %__MODULE__{
          resource: reference(),
          width: pos_integer(),
          height: pos_integer(),
          format: atom()
        }
```

Replace `new/3` (lines 18-27) with:

```elixir
  @doc "Precompute a reference from a packed binary of the given format (default :rgb888)."
  @spec new(binary(), pos_integer(), pos_integer(), keyword()) ::
          {:ok, t()} | {:error, Ssimulacra2.reason()}
  def new(source, width, height, opts \\ []) when is_binary(source) do
    format = Keyword.get(opts, :format, :rgb888)

    with :ok <- Validate.format(format),
         :ok <- Validate.dims(width, height),
         :ok <- Validate.size(source, width, height, format),
         {:ok, resource} <- map_native(Native.reference_new(source, width, height, format)) do
      {:ok, %__MODULE__{resource: resource, width: width, height: height, format: format}}
    end
  end
```

Replace `compare/2` (lines 29-36) with:

```elixir
  @doc "Compare a candidate against the precomputed reference (same format as the reference)."
  @spec compare(t(), binary()) :: {:ok, float()} | {:error, Ssimulacra2.reason()}
  def compare(%__MODULE__{} = ref, distorted) when is_binary(distorted) do
    with :ok <- Validate.size(distorted, ref.width, ref.height, ref.format) do
      Native.reference_compare(ref.resource, distorted, ref.width, ref.height, ref.format)
      |> map_native()
    end
  end
```

Replace `new!/3` (lines 38-45) with:

```elixir
  @doc "Like `new/4` but returns the reference or raises `Ssimulacra2.Error`."
  @spec new!(binary(), pos_integer(), pos_integer(), keyword()) :: t()
  def new!(source, width, height, opts \\ []) do
    case new(source, width, height, opts) do
      {:ok, ref} -> ref
      {:error, reason} -> raise Ssimulacra2.Error, reason: reason
    end
  end
```

- [ ] **Step 4: Run reference tests and full suite**

Run: `SSIMULACRA2_BUILD=1 mise exec -- mix test test/ssimulacra2/reference_test.exs`
Expected: PASS.

Run: `SSIMULACRA2_BUILD=1 mise exec -- mix test --include vix`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add lib/ssimulacra2/reference.ex test/ssimulacra2/reference_test.exs
git commit -m "feat: format option for Ssimulacra2.Reference"
```

---

## Task 4: Alignment regression test

Proves the owned-`Vec` builders handle unaligned BEAM sub-binaries (no panic). Test-only.

**Files:**
- Modify: `test/ssimulacra2/formats_test.exs`

- [ ] **Step 1: Write the failing-safe regression test**

Append to `test/ssimulacra2/formats_test.exs`, inside the module (before the final `end`):

```elixir
  # A 1-byte prefix makes binary_part return a sub-binary at a misaligned byte
  # offset, which would panic bytemuck::cast_slice for u16/f32 element types.
  defp misaligned(bin), do: binary_part(<<0>> <> bin, 1, byte_size(bin))

  test "scores an unaligned :rgb16 sub-binary without crashing" do
    base = Fixtures.gradient_rgb16(16, 16)
    shifted = misaligned(base)
    assert byte_size(shifted) == byte_size(base)
    assert {:ok, s} = Ssimulacra2.compare(shifted, shifted, 16, 16, format: :rgb16)
    assert s > 99.0
  end

  test "scores an unaligned :linear_rgb sub-binary without crashing" do
    base = Fixtures.gradient_linear_rgb(16, 16)
    shifted = misaligned(base)
    assert byte_size(shifted) == byte_size(base)
    assert {:ok, s} = Ssimulacra2.compare(shifted, shifted, 16, 16, format: :linear_rgb)
    assert s > 99.0
  end
```

- [ ] **Step 2: Run the tests**

Run: `SSIMULACRA2_BUILD=1 mise exec -- mix test test/ssimulacra2/formats_test.exs`
Expected: PASS (the `from_ne_bytes` builders from Task 1 are alignment-agnostic). If this panics/crashes the NIF, Task 1's builders are wrong — fix there, not here.

- [ ] **Step 3: Commit**

```bash
git add test/ssimulacra2/formats_test.exs
git commit -m "test: lock alignment-safe handling of unaligned sub-binaries"
```

---

## Task 5: Vix bridge preserves bit depth

`:VIPS_FORMAT_UCHAR` sources go through the existing sRGB/8-bit path (`:rgb888`); any other source format goes through `:VIPS_INTERPRETATION_RGB16` / `:VIPS_FORMAT_USHORT` and feeds `:rgb16`. For a two-image compare, if either image is non-UCHAR both are coerced to 16-bit so the formats match.

**Files:**
- Modify: `lib/ssimulacra2/vix.ex`
- Modify: `test/ssimulacra2/vix_test.exs`

- [ ] **Step 1: Write the failing/updated Vix tests**

In `test/ssimulacra2/vix_test.exs`, replace the `"downscales a 16-bit source rather than clipping it"` test (lines 22-39) with:

```elixir
  test "a 16-bit source yields a :rgb16 reference (bit depth preserved)" do
    bin = gradient_rgb888(64, 64)
    {:ok, img8} = Image.new_from_binary(bin, 64, 64, 3, :VIPS_FORMAT_UCHAR)
    img8 = Operation.copy!(img8, interpretation: :VIPS_INTERPRETATION_sRGB)

    img16 =
      img8
      |> Operation.linear!([257.0], [0.0])
      |> Operation.cast!(:VIPS_FORMAT_USHORT)
      |> Operation.copy!(interpretation: :VIPS_INTERPRETATION_RGB16)

    assert {:ok, ref} = Ssimulacra2.Vix.reference(img16)
    assert ref.format == :rgb16
  end

  test "an 8-bit source yields a :rgb888 reference" do
    {:ok, img8} = Image.new_from_buffer(black_png())
    assert {:ok, ref} = Ssimulacra2.Vix.reference(img8)
    assert ref.format == :rgb888
  end

  test "16-bit and equivalent 8-bit content reconcile without clipping" do
    bin = gradient_rgb888(64, 64)
    {:ok, img8} = Image.new_from_binary(bin, 64, 64, 3, :VIPS_FORMAT_UCHAR)
    img8 = Operation.copy!(img8, interpretation: :VIPS_INTERPRETATION_sRGB)

    # Same content scaled into the full 16-bit range. Both sides are routed
    # through the 16-bit path; the score must stay high (no 8-bit clamp).
    img16 =
      img8
      |> Operation.linear!([257.0], [0.0])
      |> Operation.cast!(:VIPS_FORMAT_USHORT)
      |> Operation.copy!(interpretation: :VIPS_INTERPRETATION_RGB16)

    assert {:ok, score} = Ssimulacra2.Vix.compare(img16, img8)
    assert score > 90.0
  end
```

- [ ] **Step 2: Run to confirm failure**

Run: `SSIMULACRA2_BUILD=1 mise exec -- mix test --only vix`
Expected: FAIL — `ref.format` is currently always `:rgb888` for the 16-bit source (and `Reference` did not store `:rgb16` from Vix because Vix downscaled).

- [ ] **Step 3: Rewrite the Vix coercion to preserve bit depth**

Replace the body of the `Ssimulacra2.Vix` module in `lib/ssimulacra2/vix.ex` (everything between `alias ...` and the module's closing `end`) with:

```elixir
    alias Vix.Vips.{Image, Operation}

    @doc "Compare two Vix images with `Ssimulacra2.compare/5`."
    @spec compare(Image.t(), Image.t()) :: {:ok, float()} | {:error, term()}
    def compare(%Image{} = reference, %Image{} = distorted) do
      format = pair_format(reference, distorted)

      with {:ok, {ref_bin, w, h}} <- coerce(reference, format),
           {:ok, {dist_bin, ^w, ^h}} <- coerce(distorted, format) do
        Ssimulacra2.compare(ref_bin, dist_bin, w, h, format: format)
      else
        {:ok, {_bin, _w2, _h2}} -> {:error, :dimension_mismatch}
        other -> other
      end
    end

    @doc "Build a `Ssimulacra2.Reference` from a Vix image, preserving bit depth."
    @spec reference(Image.t()) :: {:ok, Ssimulacra2.Reference.t()} | {:error, term()}
    def reference(%Image{} = image) do
      format = image_format(image)

      with {:ok, {bin, w, h}} <- coerce(image, format) do
        Ssimulacra2.Reference.new(bin, w, h, format: format)
      end
    end

    # 8-bit (UCHAR) sources stay 8-bit; anything else is treated as 16-bit.
    defp image_format(%Image{} = image) do
      if Image.format(image) == :VIPS_FORMAT_UCHAR, do: :rgb888, else: :rgb16
    end

    # When comparing a pair, if either side is higher than 8-bit, both go 16-bit.
    defp pair_format(a, b) do
      if image_format(a) == :rgb888 and image_format(b) == :rgb888,
        do: :rgb888,
        else: :rgb16
    end

    # Coerce to the target format: sRGB primaries, alpha flattened, packed binary.
    defp coerce(%Image{} = image, :rgb888),
      do: do_coerce(image, :VIPS_INTERPRETATION_sRGB, :VIPS_FORMAT_UCHAR)

    defp coerce(%Image{} = image, :rgb16),
      do: do_coerce(image, :VIPS_INTERPRETATION_RGB16, :VIPS_FORMAT_USHORT)

    defp do_coerce(image, interpretation, band_format) do
      colour = Operation.colourspace!(image, interpretation)
      flat = if Image.has_alpha?(colour), do: Operation.flatten!(colour), else: colour
      cast = Operation.cast!(flat, band_format)

      case Image.write_to_binary(cast) do
        {:ok, bin} -> {:ok, {bin, Image.width(cast), Image.height(cast)}}
        {:error, reason} -> {:error, reason}
      end
    end
```

Also update the module `@moduledoc` (lines 4-9) to:

```elixir
    @moduledoc """
    Convenience wrappers that accept `Vix.Vips.Image` structs.

    Only compiled when the optional `:vix` dependency is available. 8-bit
    sources are coerced to 8-bit sRGB (`:rgb888`); higher-bit-depth sources are
    preserved as 16-bit sRGB (`:rgb16`). Alpha is flattened in both cases.
    """
```

- [ ] **Step 4: Run the Vix tests and full suite**

Run: `SSIMULACRA2_BUILD=1 mise exec -- mix test --only vix`
Expected: PASS.

Run: `SSIMULACRA2_BUILD=1 mise exec -- mix test --include vix`
Expected: PASS (all tests).

- [ ] **Step 5: Commit**

```bash
git add lib/ssimulacra2/vix.ex test/ssimulacra2/vix_test.exs
git commit -m "feat: Vix bridge preserves 16-bit sources"
```

---

## Task 6: Documentation

**Files:**
- Modify: `lib/ssimulacra2.ex` (`@moduledoc`)
- Modify: `README.md`

- [ ] **Step 1: Update the module doc**

Replace the `@moduledoc` in `lib/ssimulacra2.ex` (lines 2-10) with:

```elixir
  @moduledoc """
  SSIMULACRA2 perceptual image-quality metric for Elixir, backed by the
  `fast-ssim2` Rust crate.

  Inputs are packed binaries whose layout is chosen with the `:format` option
  (default `:rgb888`). The score is on the native SSIMULACRA2 0–100 scale: 100
  is pixel-identical, ~90+ is visually lossless, and low/negative values
  indicate large perceptual differences.

  ## Formats

  | format | element | channels | bytes/pixel | color space |
  | --- | --- | --- | --- | --- |
  | `:rgb888` (default) | `u8` | 3 | 3 | sRGB (gamma) |
  | `:rgb16` | `u16` | 3 | 6 | sRGB (gamma) |
  | `:linear_rgb` | `f32` | 3 | 12 | linear RGB |
  | `:gray8` | `u8` | 1 | 1 | sRGB grayscale |
  | `:linear_gray` | `f32` | 1 | 4 | linear grayscale |

  Convention: integer elements are sRGB (gamma-encoded); float elements are
  linear RGB. Grayscale is expanded to RGB (R=G=B). Multi-byte elements
  (`u16`, `f32`) are **native-endian** — e.g. `<<v::native-16>>` /
  `<<v::native-float-32>>`. A binary's size must equal
  `width * height * channels * bytes_per_element` for its format.
  """
```

- [ ] **Step 2: Update the README**

In `README.md`, replace the "Usage" intro paragraph (the line beginning `Inputs are packed 8-bit sRGB`) with:

```markdown
Inputs are packed binaries; the layout is selected with the `:format` option
(default `:rgb888`). Scores are on the native SSIMULACRA2 0–100 scale: 100 =
identical, ~90+ ≈ visually lossless, lower (and negative) = larger perceptual
difference.

| format | element | channels | bytes/pixel | color space |
| --- | --- | --- | --- | --- |
| `:rgb888` (default) | `u8` | 3 | 3 | sRGB (gamma) |
| `:rgb16` | `u16` | 3 | 6 | sRGB (gamma) |
| `:linear_rgb` | `f32` | 3 | 12 | linear RGB |
| `:gray8` | `u8` | 1 | 1 | sRGB grayscale |
| `:linear_gray` | `f32` | 1 | 4 | linear grayscale |

Convention: integer = sRGB gamma, float = linear. Multi-byte elements are
native-endian.

```elixir
{:ok, score} = Ssimulacra2.compare(ref_rgb, dist_rgb, width, height)
{:ok, score} = Ssimulacra2.compare(ref16, dist16, width, height, format: :rgb16)
```
```

In `README.md`, replace the "Status" section paragraph (the `v0.1 supports ...` block) with:

```markdown
v0.1 supports 8-bit sRGB, 16-bit sRGB, linear-f32, and grayscale input for the
SSIMULACRA2 metric. Plain-SSIM support is tracked as a future issue.
```

- [ ] **Step 3: Verify docs compile and the suite is green**

Run: `SSIMULACRA2_BUILD=1 mise exec -- mix test --include vix`
Expected: PASS.

Run: `mise exec -- mix docs 2>&1 | tail -3` (if `:ex_doc` is available)
Expected: docs generate without warnings about the changed moduledoc. If `mix docs` is unavailable, skip.

- [ ] **Step 4: Commit**

```bash
git add lib/ssimulacra2.ex README.md
git commit -m "docs: document input formats and native-endian convention"
```

---

## Final verification

- [ ] Run the entire suite from a clean build:

Run: `SSIMULACRA2_BUILD=1 mise exec -- mix test --include vix`
Expected: PASS — all tests, 0 failures.

- [ ] Confirm no compiler warnings:

Run: `SSIMULACRA2_BUILD=1 mise exec -- mix compile --warnings-as-errors`
Expected: compiles cleanly.
