# ssimulacra2 — Design

**Date:** 2026-06-19
**Status:** Approved (brainstorming)
**Repo:** `hlindset/ssimulacra2` (standalone Hex library)

## Summary

`ssimulacra2` is a standalone Elixir/Hex library (module `Ssimulacra2`) that wraps
the Rust crate [`fast-ssim2`](https://github.com/imazen/fast-ssim2) (Imazen,
BSD-2-Clause) via Rustler, exposing the **SSIMULACRA2** full-reference perceptual
image-quality metric to Elixir. It fills a real ecosystem gap: there is currently no
SSIM / SSIMULACRA2 / DSSIM library for Elixir.

Motivating consumer: **ImagePipe** (`/Users/hlindset/src/image_plug`, an
imgproxy-compatible image library), issue **#344** (`autoquality`), whose `dssim`
method needs a perceptual full-reference metric computed in Elixir, run once per
quality-search iteration.

## Settled decisions

These were decided during brainstorming and are not to be re-litigated:

- **Crate choice:** `fast-ssim2` (BSD-2-Clause, SIMD ~3× faster at 1080p, actively
  maintained v0.8.2). Rejected: Kornel's `dssim` (AGPL-3.0, network-copyleft would
  infect hosts embedding ImagePipe); `rust-av/ssimulacra2` (BSD-2 but stale).
- **Repository:** standalone Hex library, repo `hlindset/ssimulacra2`. ImagePipe will
  depend on it. Not vendored into ImagePipe.
- **Score output:** native SSIMULACRA2 score only, `f64` on a 0–100 scale
  (100 = identical, 90+ ≈ visually lossless, can go negative). No DSSIM-style
  conversion — #344 converts units itself.
- **Input at the core:** raw packed RGB888 binary + width + height. No hard Vix
  dependency in the library.
- **Optional Vix helper:** `Ssimulacra2.Vix`, compiled only when `:vix` is available
  (optional dep), converting a `Vix.Vips.Image` to a packed RGB888 binary and
  delegating to the core.
- **v1 metric/format:** SSIMULACRA2 only, **8-bit sRGB** input.
- **v1 compute paths:** both one-shot compare AND the reused-reference batch path
  (`fast-ssim2`'s `Ssimulacra2Reference`, surfaced via a Rustler `ResourceArc`), for
  the autoquality loop (same reference, many candidates → ~2× faster per compare).
- **Deferred to GitHub issues:** u16 input, f32 (linear) input, plain SSIM.

## Verified facts (2026-06-19)

- Name `ssimulacra2` is free on hex.pm.
- Toolchain on dev machine: Elixir 1.19.3 / Erlang OTP 28, Rust 1.85.1.
- Latest versions: **rustler 0.38.0**, **rustler_precompiled 0.9.0**,
  **fast-ssim2 0.8.2**. crates.io versions are immutable → pin in `Cargo.toml`, commit
  `Cargo.lock`, no vendoring needed. (Escape hatch if upstream ever blocks a fix: git
  dependency on a fork or `[patch.crates-io]`.)
- `fast-ssim2` public API: `compute_ssimulacra2(source, distorted) -> Result<f64,
  Ssimulacra2Error>`; inputs (with `imgref` feature) `ImgRef<[u8;3]>` (sRGB),
  `ImgRef<[u16;3]>` (sRGB16), `ImgRef<[f32;3]>` (linear), plus grayscale;
  `Ssimulacra2Reference::new(src)` + `.compare(dist)` for batch (~2×);
  `compute_ssimulacra2_strip` for large images; `*_with_stop` cancellable variants.
  `ImgRef` carries a pixel slice + width/height/stride. Runtime SIMD CPU detection.

## Public API

```elixir
# One-shot — packed RGB888 binaries, byte_size must == w*h*3
{:ok, score} = Ssimulacra2.compare(ref_rgb, dist_rgb, width, height)
score        = Ssimulacra2.compare!(ref_rgb, dist_rgb, width, height)   # raises on error

# Batch — precompute reference once, compare many candidates (autoquality loop)
{:ok, ref}   = Ssimulacra2.Reference.new(ref_rgb, width, height)
{:ok, s1}    = Ssimulacra2.Reference.compare(ref, candidate1_rgb)        # dims carried by ref
{:ok, s2}    = Ssimulacra2.Reference.compare(ref, candidate2_rgb)

# Optional convenience (only compiled if :vix is available)
{:ok, score} = Ssimulacra2.Vix.compare(ref_image, dist_image)
```

- Score is the native `f64`, 0–100.
- `%Ssimulacra2.Reference{}` is opaque, wrapping a `ResourceArc` plus stored
  width/height. `Reference.compare/2` carries dims from the stored reference; the
  candidate binary must match (`byte_size == w*h*3`) — chosen over passing dims again
  to remove a way to pass a mismatched pair.

## Architecture / components

| Unit | Responsibility | Depends on |
|---|---|---|
| `Ssimulacra2` | Public API, arg validation (binary size == w·h·3, positive dims), error tuples, `compare!/4` | `Ssimulacra2.Native` |
| `Ssimulacra2.Reference` | Opaque reference struct + `new/3`, `compare/2` | `Ssimulacra2.Native` |
| `Ssimulacra2.Native` | Rustler NIF boundary; thin Elixir stubs + `rustler_precompiled` load config | `rustler_precompiled` |
| `native/ssimulacra2_nif` (Rust) | Borrow binary → `ImgRef<[u8;3]>`, call `fast-ssim2`, map `Result`/errors to terms; `ResourceArc<RefHandle>` for batch | `fast-ssim2`, `rustler`, `imgref` |
| `Ssimulacra2.Vix` | Optional: `Vix.Vips.Image` → packed RGB888 binary, delegate to core | `vix` (optional) |

**Data flow (one-shot):** Elixir binary → Rust borrows bytes as `&[u8]`, reinterprets
as `&[[u8; 3]]`, wraps in `ImgRef` with `stride = width` → `compute_ssimulacra2` →
`f64` → Elixir float. No extra pixel copy beyond the NIF argument hand-off.

**Vix → RGB:** `Vix.Vips.Image.write_to_binary/1` on an sRGB, 3-band, 8-bit,
no-alpha image yields exactly packed RGB888. The helper enforces those properties
(flatten alpha, cast/colourspace to sRGB) before extracting, so the hand-off is a
single buffer with no per-pixel Elixir work.

## NIF concurrency

SSIMULACRA2 on a 1080p pair takes several ms — too long for a normal NIF (would block
a scheduler > 1 ms). The compute NIFs run on a **dirty CPU scheduler**
(`schedule = "DirtyCpu"`). Argument validation (size/dims) happens in Elixir before
entering the NIF, so the dirty path does compute only.

## Error handling

- Elixir guard clauses + `{:error, reason}`:
  - `:size_mismatch` — binary `byte_size` ≠ `w*h*3`
  - `:dimension_mismatch` — candidate binary size vs stored reference dims
  - `:invalid_dimensions` — width or height ≤ 0
- Rust `Ssimulacra2Error` (e.g. image too small) → `{:error, {:ssimulacra2, message}}`.
- `compare!/4` raises `Ssimulacra2.Error`.

## Distribution (`rustler_precompiled`)

- Precompile NIFs in CI (GitHub Actions) across the standard target matrix; consumers
  download prebuilt artifacts — **no Rust toolchain required**.
  `RUSTLER_PRECOMPILED_FORCE_BUILD` escape hatch for unlisted targets.
- `fast-ssim2` pinned in `Cargo.toml`; `Cargo.lock` committed.
- `fast-ssim2` does runtime SIMD CPU detection, so one prebuilt artifact per OS/arch
  still adapts to the host CPU.

## Testing & conformance

1. **Unit:** arg validation, error tuples, identical-image sanity (score ≈ 100),
   `Reference` path == one-shot for the same pair.
2. **Conformance (gating task):** validate against
   [`cloudinary/ssimulacra2`](https://github.com/cloudinary/ssimulacra2) reference
   vectors — assemble a small set of (ref, dist, expected-score) cases, assert output
   within a tolerance **determined empirically** in this task (not a guessed `1e-5`).
   This is the external-parity check the crate's internal ~1e-5 claim (strip vs full
   path) does not cover. Parity outside a reasonable tolerance is a finding to surface,
   not silently accept.
3. **CI:** `mix test` + the precompile matrix.

## This session's deliverable

1. Scaffold the project (`mix new` + Rustler NIF crate, deps wired).
2. **Trivial NIF building end-to-end** — a smoke NIF compiling and callable from `iex`,
   then the real `compare/4`.
3. Conformance-check **plan** documented (vectors sourced; tolerance to be measured).
4. File GitHub issues for deferred u16 / f32 / plain-SSIM.
5. Initial commit + push to `origin`.

## Out of scope (v1)

- u16 / f32 (linear) inputs — deferred, tracked as issues.
- Plain SSIM — `fast-ssim2` is SSIMULACRA2-specific; would require a different
  implementation. Deferred, tracked as an issue.
- DSSIM-style score conversion.
- `compute_ssimulacra2_strip` (large-image bounded-memory path) and `*_with_stop`
  cancellable variants — revisit if a real need appears.
