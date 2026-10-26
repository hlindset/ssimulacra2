# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Changed

- Bumped `fast-ssim2` from a git revision (0.8.2 + cancellation) to the
  crates.io release 0.9.0. 0.9 scores through a bit-exact port of the official
  SSIMULACRA2 implementation, so scores shift slightly: typically 1e-3–1e-2,
  up to ~0.12 on small grayscale images. Identical images now score exactly
  100 at every size, and `Ssimulacra2.Reference` scores match one-shot
  `compare/5` exactly.
- Lower peak memory per comparison: `:rgb888`, `:rgb16` and `:gray8`
  candidates are converted to linear RGB one strip at a time instead of for
  the whole frame, and aligned `:rgb16`, `:linear_rgb` and `:linear_gray`
  binaries are read in place rather than copied.
- Require `rustler_precompiled ~> 0.10.1`. Earlier versions fail to download
  the precompiled NIFs from GitHub Releases with
  `{:header_too_long, {:max, 10240}}`.

## [0.1.0] - 2026-06-26

### Added

- `Ssimulacra2.compare/5` and `compare!/5` — compute the SSIMULACRA2 score
  between two packed-binary images. Scores are on the native 0–100 scale.
- `Ssimulacra2.Reference` — `new/4`, `new!/4`, `compare/3`, `compare!/3` for
  reusing one prepared reference across many candidates (~2× faster per compare
  in a quality-search loop).
- Input formats selectable via the `:format` option: `:rgb888` (default),
  `:rgb16`, `:linear_rgb`, `:gray8`, `:linear_gray`.
- Cooperative cancellation: `Ssimulacra2.CancelRef.new/0` and
  `Ssimulacra2.cancel/1`. The metric runs on a dirty scheduler and polls the
  cancel ref at strip boundaries, freeing the CPU promptly. A cancel ref is
  single-use.
- Wall-clock timeouts via the `:timeout` option, returning `{:error, :timeout}`.
- Optional Vix integration (`Ssimulacra2.Vix.compare/2`), available when `:vix`
  is a dependency.
- Precompiled NIFs via `rustler_precompiled` for `aarch64`/`x86_64` macOS,
  `gnu`/`musl` Linux, and `x86_64` Windows, across NIF versions 2.15–2.17, so
  the Rust toolchain is not required on covered targets.

### Notes

- `fast-ssim2` is pinned to a git revision because the cooperative-cancellation
  API (`*_with_stop`) has not yet landed in a crates.io release. This will move
  to a versioned dependency once available.
- Scores are "SSIMULACRA2 as computed by `fast-ssim2`" and have not been
  bit-exactly validated against the canonical Cloudinary/libjxl reference.

[Unreleased]: https://github.com/hlindset/ssimulacra2/compare/v0.1.0...HEAD
[0.1.0]: https://github.com/hlindset/ssimulacra2/releases/tag/v0.1.0
