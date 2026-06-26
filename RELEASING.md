# Releasing

This package ships **precompiled NIFs** via
[`rustler_precompiled`](https://hexdocs.pm/rustler_precompiled). The binaries are
built by GitHub Actions and attached to a GitHub Release, then a checksum file is
generated and bundled into the Hex package. **Order matters**: the release
artifacts must exist on GitHub *before* you can generate checksums and publish.

The trap to remember: tag **first** → CI builds artifacts → **then** checksums →
**then** publish. Running `mix hex.publish` before the GitHub Release artifacts
exist leaves the checksum step with nothing to download, and consumers won't be
able to load the NIF.

## Prerequisites (one-time)

- A Hex account that owns (or co-owns) the `ssimulacra2` package.
  Authenticate locally: `mix hex.user auth` (or set `HEX_API_KEY`).
- The pinned toolchain installed (`mise install` reads [mise.toml](mise.toml):
  Erlang 29, Elixir 1.20, Rust 1.96). Run mix tasks via `mise exec -- ...`.

## Per-release checklist

1. **Decide the version** and confirm `fast-ssim2` is still pinned where you want
   it ([native/ssimulacra2_nif/Cargo.toml](native/ssimulacra2_nif/Cargo.toml) —
   currently a git rev, by design).

2. **Bump the version in both places** (keep them in lockstep):
   - [mix.exs](mix.exs) — `version:`
   - [native/ssimulacra2_nif/Cargo.toml](native/ssimulacra2_nif/Cargo.toml) — `version`

   `lib/ssimulacra2/native.ex` derives the release download URL
   (`.../releases/download/v#{version}`) from the mix version, so the git tag
   below **must** be `v<version>`.

3. **Update [CHANGELOG.md](CHANGELOG.md)**: rename the `## [Unreleased]` section
   to `## [<version>] - <YYYY-MM-DD>`, add a fresh empty `## [Unreleased]` above
   it, and update the link references at the bottom.

4. **Verify the build is clean** (mirrors [CI](.github/workflows/ci.yml)):

   ```bash
   mise exec -- mix deps.get
   mise exec -- cargo fmt --manifest-path native/ssimulacra2_nif/Cargo.toml --check
   mise exec -- mix format --check-formatted
   SSIMULACRA2_BUILD=1 mise exec -- mix compile --warnings-as-errors --force
   mise exec -- mix test --include vix
   ```

   The `--include vix` run needs `libvips` installed locally; drop it (run plain
   `mise exec -- mix test`) if you don't have libvips and are confident the Vix
   helper is untouched.

5. **Commit, tag, and push the tag** — the tag triggers the precompile workflow:

   ```bash
   git commit -am "Release v<version>"
   git tag v<version>
   git push origin main --tags
   ```

6. **Wait for the release workflow.**
   [.github/workflows/release.yml](.github/workflows/release.yml) fires on `v*`
   tags and builds NIFs for all 7 targets × 3 NIF versions, attaching the
   tarballs to the GitHub Release. Confirm **every matrix job succeeded** and the
   artifacts are on the release before continuing.

7. **Generate the checksum file** (downloads and hashes every artifact):

   ```bash
   mise exec -- mix rustler_precompiled.download Ssimulacra2.Native --all --print
   ```

   This writes `checksum-Elixir.Ssimulacra2.Native.exs`. It is listed in the
   `:files` of [mix.exs](mix.exs) and **must** be present at publish time —
   without it, precompiled NIF loading fails for consumers. (It is a build
   artifact, not committed to git; it just needs to exist locally when you
   publish.)

8. **Publish to Hex:**

   ```bash
   mise exec -- mix hex.publish
   ```

   Review the printed file list — confirm `checksum-*.exs`,
   `native/ssimulacra2_nif/Cargo.lock`, `lib`, `README.md`, and `CHANGELOG.md`
   are all included — then confirm. Docs are built and pushed automatically (`ex_doc`).

9. **Verify the release:** check the package page on hex.pm and that
   `mix deps.get` in a fresh project pulls a precompiled binary without invoking
   a Rust toolchain.

## If you need to re-cut a release

Hex versions are immutable. If something is wrong after publishing, bump to the
next patch version and start over from step 1. (`mix hex.publish --revert
<version>` exists for emergencies but is best avoided once people have fetched.)
