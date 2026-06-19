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

## Releasing

Precompiled NIFs are built by the GitHub release workflow on a `v*` tag. Before
`mix hex.publish`, generate the checksum file the package references:

    mix rustler_precompiled.download Ssimulacra2.Native --all --print

This writes `checksum-Elixir.Ssimulacra2.Native.exs`, which MUST be included in
the published package (it is already listed in `mix.exs` `:files`). Without it,
precompiled NIF loading fails for consumers.

## License

This wrapper is released under BSD-2-Clause, matching `fast-ssim2`.
