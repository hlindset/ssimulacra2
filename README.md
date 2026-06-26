# ssimulacra2

SSIMULACRA2 perceptual image-quality metric for Elixir, backed by the
[`fast-ssim2`](https://github.com/imazen/fast-ssim2) Rust crate (BSD-2-Clause)
via Rustler. Published with precompiled NIFs, so the Rust toolchain is not
required if you're on a covered architecture + platform.

> **Note:** this binding currently pins `fast-ssim2` to a git revision
> because the cooperative-cancellation API (`*_with_stop`) has not yet landed
> in a crates.io release. We will switch to a proper versioned dependency as
> soon as possible.

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

### Cancellation & timeouts

`Ssimulacra2.compare/5` and `Ssimulacra2.Reference.compare/3` can be aborted mid-computation. The metric
runs on a dirty scheduler and polls a cancel ref at strip boundaries, so the CPU
is freed promptly.

```elixir
# Wall-clock timeout — returns {:error, :timeout} if it overruns.
Ssimulacra2.compare(ref, dist, w, h, timeout: 3_000)

# External cancellation — the ref is tripped from another process, because the
# calling process is blocked in the NIF until it returns.
tok = Ssimulacra2.CancelRef.new()
task = Task.async(fn -> Ssimulacra2.compare(ref, dist, w, h, cancel: tok) end)
# ... on client disconnect / shutdown:
Ssimulacra2.cancel(tok)
Task.await(task)  #=> {:error, :cancelled}
```

A quality-search loop can share one ref across probes for an overall deadline
(or disconnect). Tripping it aborts the in-flight probe and makes every later
probe return `{:error, :cancelled}` at once:

```elixir
{:ok, ref} = Ssimulacra2.Reference.new(original, w, h)
tok = Ssimulacra2.CancelRef.new()

# Watchdog trips the shared ref on the search deadline (a disconnect monitor
# can call Ssimulacra2.cancel/1 too).
spawn(fn -> Process.sleep(5_000); Ssimulacra2.cancel(tok) end)

case Ssimulacra2.Reference.compare(ref, candidate, cancel: tok) do
  {:ok, score}         -> score
  {:error, :cancelled} -> :deadline_or_disconnect
end
```

A cancel ref is single-use: once cancelled it stays cancelled.

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

## LLM Development Notice

This library was developed with help from LLMs.

## License

This wrapper is released under BSD-2-Clause, matching `fast-ssim2`.
