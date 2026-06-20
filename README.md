# ssimulacra2

SSIMULACRA2 perceptual image-quality metric for Elixir, backed by the
[`fast-ssim2`](https://github.com/imazen/fast-ssim2) Rust crate (BSD-2-Clause)
via Rustler. Published with precompiled NIFs, so the Rust toolchain is not
required if you're on a covered architecture + platform.

## Installation

```elixir
def deps do
  [{:ssimulacra2, "~> 0.1"}]
end
```

## Usage

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

Convention: integer = sRGB gamma, float = linear. Grayscale is expanded to RGB
(R=G=B). Multi-byte elements are native-endian.

```elixir
{:ok, score} = Ssimulacra2.compare(ref_rgb, dist_rgb, width, height)
{:ok, score} = Ssimulacra2.compare(ref16, dist16, width, height, format: :rgb16)
```

For a quality-search loop comparing many candidates against one original, reuse
the reference (~2× faster per compare):

```elixir
{:ok, ref} = Ssimulacra2.Reference.new(original_rgb, width, height)
{:ok, s1} = Ssimulacra2.Reference.compare(ref, candidate1_rgb)
{:ok, s2} = Ssimulacra2.Reference.compare(ref, candidate2_rgb)
```

### With Vix

If `:vix` is a dependency, pass images directly:

```elixir
{:ok, score} = Ssimulacra2.Vix.compare(ref_image, dist_image)
```

## Accuracy

Scores come from [`fast-ssim2`](https://github.com/imazen/fast-ssim2), a maintained
SIMD implementation of SSIMULACRA2. This library has **not** been bit-exactly
validated against the canonical Cloudinary/libjxl reference, so treat the absolute
value as "SSIMULACRA2 as computed by `fast-ssim2`" rather than guaranteed parity
with that reference. The metric is well-behaved and monotonic (identical images
score 100; perceptual degradation lowers the score, into the negatives for large
differences), which is what matters for relative use such as a quality-search loop.
If you need a specific target score, calibrate the threshold against this
implementation rather than against externally published numbers.

## Status

v0.1 supports 8-bit sRGB, 16-bit sRGB, linear-f32, and grayscale input for the
SSIMULACRA2 metric.

## Releasing

Precompiled NIFs are built by the GitHub release workflow on a `v*` tag. Before
`mix hex.publish`, generate the checksum file the package references:

```bash
mix rustler_precompiled.download Ssimulacra2.Native --all --print
```

This writes `checksum-Elixir.Ssimulacra2.Native.exs`, which MUST be included in
the published package (it is already listed in `mix.exs` `:files`). Without it,
precompiled NIF loading fails for consumers.

### Building from source

A Rust toolchain is only needed if you build the NIF locally instead of using a
precompiled artifact — i.e. on a target not covered by the release matrix, or
when forcing a build with `SSIMULACRA2_BUILD=1`. In that case `fast-ssim2`
requires **Rust ≥ 1.89** (the crate pins that MSRV).

## License

This wrapper is released under BSD-2-Clause, matching `fast-ssim2`.
