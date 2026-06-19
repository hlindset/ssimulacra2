# Design: Support Remaining Input Formats

Date: 2026-06-20
Status: Approved (design); pending spec review

## Goal

Expose the input pixel formats that `fast-ssim2` supports but the Elixir wrapper
does not yet. Today only packed 8-bit sRGB (`RGB888`) is reachable. Add:

| atom | element | channels | bytes/px | color space |
|------|---------|----------|----------|-------------|
| `:rgb888` *(default)* | `u8` | 3 | 3 | sRGB (gamma) |
| `:rgb16` | `u16` | 3 | 6 | sRGB (gamma) |
| `:linear_rgb` | `f32` | 3 | 12 | linear RGB |
| `:gray8` | `u8` | 1 | 1 | sRGB grayscale |
| `:linear_gray` | `f32` | 1 | 4 | linear grayscale |

Convention (matches `fast-ssim2`): **integer element ⇒ sRGB gamma, float
element ⇒ linear**. Grayscale is expanded to RGB (R=G=B) by the crate.

The library is unreleased; backward compatibility is **not** a goal. The chosen
API is the one we would pick greenfield, not a compatibility artifact.

## API (Elixir)

A `format:` option threads through the existing functions via a default
argument (`:rgb888` when omitted). No new public module.

```elixir
Ssimulacra2.compare(ref, dist, w, h)                       # :rgb888
Ssimulacra2.compare(ref, dist, w, h, format: :rgb16)
Ssimulacra2.compare!(ref, dist, w, h, format: :linear_rgb)

{:ok, ref} = Ssimulacra2.Reference.new(src, w, h, format: :rgb16)
Ssimulacra2.Reference.compare(ref, candidate)              # uses ref's format
```

- `Ssimulacra2.compare/5` and `compare!/5` — final `opts \\ []` arg, reads
  `:format` (default `:rgb888`).
- `Ssimulacra2.Reference.new/4` and `new!/4` — same `opts`. The returned struct
  **stores its `format`**. `Reference.compare/2` validates the candidate against
  the reference's stored format and dimensions (a reference is bound to one
  format; the candidate format is not re-specified per call).

### Endianness

Multi-byte elements (`u16`, `f32`) are **native-endian**. Documented in
`@moduledoc` and README. Rationale: `Vix.write_to_binary` emits native-endian,
and hand-built binaries use `<<v::native-16>>` / `<<v::native-float-32>>`. All
RustlerPrecompiled targets are little-endian in practice.

## Validation (`Ssimulacra2.Validate`)

- Introduce a format table mapping atom → `{channels, element_bytes}`. Single
  source of truth, shared by `compare` and `Reference`.
- `size/3` becomes format-aware: expected `byte_size = w * h * channels *
  element_bytes`. Mismatch ⇒ `{:error, :size_mismatch}`.
- Unrecognized format atom ⇒ `{:error, :unknown_format}` (added to the
  `Ssimulacra2.reason()` type).
- `dims/2` unchanged.

## Native NIF (Rust)

`compare`, `reference_new`, `reference_compare` each gain a `format` atom
argument. Decode it to an internal `enum Format`, `match` to build the correct
`ImgRef<…>`, then call the existing generic
`compute_ssimulacra2` / `Ssimulacra2Reference::{new, compare}`.

- `ReferenceResource` stays **one concrete type** — verified that
  `Ssimulacra2Reference` is not generic (its internal planes are `Vec<f32>`);
  only its `new`/`compare` are generic over the input type. No enum-wrapped
  resource needed.
- **Alignment**: BEAM binaries — particularly sub-binaries from slicing — are
  not guaranteed to be 2-/4-byte aligned, so `bytemuck::cast_slice` to
  `[u16; 3]` / `[f32; 3]` could panic. Build an owned, aligned
  `Vec<[T; 3]>` / `Vec<[T; 1]>` from the bytes via `from_ne_bytes` chunks, then
  `ImgRef::new(&vec, w, h)`. The `:rgb888` / `:gray8` paths (element align 1)
  may borrow the binary slice directly as today.
- Unknown atom from Elixir is prevented by Elixir-side validation; the Rust
  decoder still returns an error rather than panicking if it sees one.

## Vix bridge (`Ssimulacra2.Vix`) — preserve bit depth

Currently always coerces to 8-bit sRGB (and a test locks the 16-bit
*downscale*). New behavior: preserve up to 16-bit sRGB.

- Inspect source `Image.format/1` **before** colourspace conversion. The branch
  predicate is exact: `:VIPS_FORMAT_UCHAR` ⇒ 8-bit path; **any other format**
  (USHORT, UINT, FLOAT, …) ⇒ 16-bit path.
- 8-bit path: existing `:VIPS_INTERPRETATION_sRGB` / `:VIPS_FORMAT_UCHAR`
  conversion, feed `:rgb888`.
- 16-bit path: colourspace to `:VIPS_INTERPRETATION_RGB16`, cast
  `:VIPS_FORMAT_USHORT`, feed `:rgb16` (higher-precision and float sources are
  thereby preserved at 16-bit rather than collapsed to 8-bit).
- Alpha flatten step unchanged (applied after colourspace, before cast).
- Grayscale and linear auto-detection are **out of scope** (the "full
  auto-mapping" option was not chosen). Vix emits only `:rgb888` or `:rgb16`.
- The existing test that locks 16-bit downscaling is rewritten to assert 16-bit
  is **preserved** (a 16-bit distinction that would be lost at 8-bit is
  retained in the score path).

## Testing (TDD)

Per new format (`:rgb16`, `:linear_rgb`, `:gray8`, `:linear_gray`):

- Size validation: correct size ⇒ `:ok`; wrong size ⇒ `:size_mismatch`.
- Identical reference vs distorted ⇒ score `100.0` (within float tolerance).
- A clearly different image scores below the identical score. (Metric
  monotonicity is `fast-ssim2`'s responsibility, not the wrapper's — the
  per-format tests verify the FFI plumbing, not the metric curve.)
- `Reference.new` + `Reference.compare` equals one-shot `compare` for the same
  inputs/format.
- `Reference.compare` with a candidate of the wrong size ⇒ `:size_mismatch`.

Cross-cutting:

- Unknown format atom ⇒ `{:error, :unknown_format}` from both `compare` and
  `Reference.new`.
- **Alignment regression**: build a sub-binary (e.g. drop a 1-byte prefix then
  take the real payload) for `:rgb16` and `:linear_rgb` and confirm scoring does
  not panic and returns a sane value.

Vix:

- 16-bit source round-trips through `:rgb16` (a 16-bit-only difference is not
  flattened away).
- 8-bit source still goes through `:rgb888` (unchanged scores).

## Docs

- `Ssimulacra2.@moduledoc`: document the format table, the integer=sRGB /
  float=linear convention, native-endian requirement, and grayscale expansion.
- README: replace the single-format "Usage" framing and update the **Status**
  section (drop "16-bit, linear-f32 … tracked as issues" for the now-supported
  formats; plain-SSIM remains future work).

## Out of scope

- Plain-SSIM metric (separate from input formats; remains future work).
- Vix grayscale / linear auto-detection. Rationale: for SSIMULACRA2 these are an
  optimization, not a fidelity gain — the metric linearizes every input and
  expands grayscale to R=G=B, so `:gray8` scores identically to RGB with three
  equal channels, and `:linear_rgb` scores identically (modulo float rounding) to
  the gamma-RGB form of the same image. The chosen UCHAR-vs-other branch already
  routes float/linear sources through the 16-bit path, capturing the precision
  that actually changes scores. Detection would add a branching matrix over
  `interpretation`/`bands`/`format` plus a gap (no 16-bit grayscale format exists
  in our set) for no perceptible score change.
- RGBA / alpha as a fourth channel (SSIMULACRA2 scores three channels; alpha is
  dropped/flattened, as today).
- Non-native endianness handling.
