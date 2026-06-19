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

Requires **Erlang/OTP 27+** (the test parses `expected.json` with the built-in
`:json` module) and the optional `:vix` dependency (to decode the PNG fixtures).
