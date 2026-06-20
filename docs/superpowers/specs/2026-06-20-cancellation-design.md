# Cooperative Cancellation for the SSIMULACRA2 NIF

**Date:** 2026-06-20
**Status:** Approved design — ready for implementation planning

## Problem

`Ssimulacra2` is the metric behind ImagePipe's autoquality quality search. Each
search probe is a full-res encode → decode → SSIMULACRA2, and the metric
dominates wall-clock (≈3.3 s on a 36 MP image). Today the compute NIFs run on a
dirty CPU scheduler and always run to completion — a running dirty-scheduler NIF
cannot be preempted by the BEAM. That causes two problems:

1. **Deadline overshoot.** A wall-clock deadline on the search can only be
   checked *between* probes, so it overshoots by up to a full probe (~3.3 s).
2. **Wasted work on disconnect.** When the client disconnects, the in-flight
   metric still runs to completion, burning CPU on a result nobody receives.

`fast-ssim2` already supports cooperative cancellation via `*_with_stop`
variants (polled at strip boundaries). The NIF simply doesn't expose it. This
design wires that cancellation through to Elixir so an in-flight `compare` /
`Reference.compare` can be aborted promptly, freeing the CPU.

## Goals

- Cancel an in-flight comparison from another process (client disconnect).
- A wall-clock `:timeout` that returns a tagged `{:error, :timeout}`.
- Cancelled / timed-out calls return tagged results, never crash.
- Prompt CPU release on cancel (size-independent latency ceiling), still on the
  dirty scheduler.

## Non-goals

- Cancelling `Reference` construction (`reference_new`). Upstream exposes no
  `new_with_stop`; building one reference's pyramid is the cheap half and is done
  once per search. Out of scope.
- Exposing `strip_height` as a public option (YAGNI — internal constant for now).
- Progress reporting / partial scores.

## No behavior change for small images

The size-dispatch (decision 3) deliberately preserves the current `<8px`
behavior: those inputs still reflect-pad to 8px and score, because they take the
non-strip `*_with_stop` path. No regression. A test locks this (a `<8px`
comparison still returns `{:ok, score}`).

## Key constraint

A running `DirtyCpu` NIF blocks its scheduler thread until it returns, so the
process that invoked the metric cannot also trip the cancellation token. The
token must be cancellable from **another** process via a cheap *regular* NIF
(runs on a normal scheduler, instantly, while the dirty compare blocks).

## Upstream API (grounded at the pinned SHA)

Repo `imazen/fast-ssim2`, rev `093aa6f15a0826b20dc94c249c33e14c0a68bf67`
(workspace crate still labelled `0.8.2`, unreleased — published 0.8.2 differs):

- `compute_ssimulacra2_strip_with_stop(source, distorted, strip_height: u32, stop)`
  → `Result<f64, Ssimulacra2Error>`, polls `stop.check()` per strip.
- `Ssimulacra2Reference::compare_strip_with_stop(&self, distorted, strip_height, stop)`
  → same, for the precomputed-reference hot path.
- Token is `&dyn enough::Stop`. `enough::Unstoppable` = never-cancel (cost
  identical to the plain function). `almost_enough::Stopper` /
  `almost_enough::SyncStopper` = concrete, clonable (8-byte `Arc<AtomicBool>`)
  handles cancellable from any thread; `SyncStopper` uses Acquire/Release.
- Error: `Ssimulacra2Error::Cancelled(enough::StopReason)`. `Ssimulacra2Error`
  is `#[non_exhaustive]` → match arms need a `_` wildcard.
- Exported: `MIN_STRIP_HEIGHT`, `HALO_ROWS_DEFAULT`.

Strip processing also bounds peak working memory (a bonus on 36 MP images).

## Design decisions (resolved)

1. **API shape:** a neutral cancellation **token** primitive plus a `:timeout`
   convenience built on it. The token carries no meaning — the caller assigns it
   (disconnect monitor trips it; search deadline trips it).
2. **`:timeout` implementation:** a pure-Elixir canceller process. No Rust timer
   threads; the NIF stays minimal (one optional token arg).
3. **Strip policy:** use the strip-with-stop variants for images `≥8px` on both
   sides (tight latency + lower peak memory on the 36 MP hot path), and the
   non-strip `*_with_stop` variants for `<8px` (which reflect-pad and score them,
   exactly as today, and are still cancellable). This avoids a regression: the
   strip path *rejects* sub-8px images, the non-strip path does not. A
   score-identity test gates the `≥8px` strip path against the pre-strip scores.
4. **Default strip height:** `256` (upstream's documented memory sweet spot;
   ~150 ms cancellation latency at scale 0 on a 36 MP image). Internal constant.

## Architecture

### Dependency & build/release strategy

`native/ssimulacra2_nif/Cargo.toml`:

```toml
fast-ssim2 = { git = "https://github.com/imazen/fast-ssim2", rev = "093aa6f15a0826b20dc94c249c33e14c0a68bf67", features = ["imgref"] }
enough = "0.4.4"
almost-enough = "0.4.4"
```

Regenerate `Cargo.lock` (pins the exact SHA → reproducible).

This stays on a feature branch / PR. While git-pinned, the crate cannot go
through the `RustlerPrecompiled` download path, so **consumers build from
source** during this window (`SSIMULACRA2_BUILD=1` or `force_build: true`). Exit
step when upstream cuts a release: swap `git` → `version`, regenerate the lock,
cut a normal precompiled release.

### Rust / NIF layer (`native/ssimulacra2_nif/src/lib.rs`)

- `StopResource` — a `rustler::Resource` wrapping `almost_enough::SyncStopper`.
- `token_new() -> ResourceArc<StopResource>` — **regular** NIF.
- `token_cancel(ResourceArc<StopResource>) -> Atom` (`:ok`) — **regular** NIF;
  trips the stopper (atomic store) instantly while a dirty compare blocks.
- `compare` / `reference_compare` gain a trailing
  `cancel: Option<ResourceArc<StopResource>>` arg (Elixir `nil` → `None`).
  Resolve `&dyn enough::Stop` = the token's `SyncStopper`, else
  `&enough::Unstoppable`. **Size-dispatch** the compute call (both branches are
  cancellable):
  - `width < 8 || height < 8` → the non-strip `compute_ssimulacra2_with_stop` /
    `compare_with_stop` (these reflect-pad sub-8px inputs up to 8px and score
    them — exactly today's behavior; polling is per-scale, which is irrelevant
    for a tiny image).
  - otherwise → the strip variant with the internal `STRIP_HEIGHT` constant
    (256) — tight per-strip latency and bounded peak memory on large images.
- Error mapping via a `rustler::NifTaggedEnum`:

  ```rust
  #[derive(rustler::NifTaggedEnum)]
  enum CompareError { Cancelled, Failed(String) }
  ```

  `Ssimulacra2Error::Cancelled(_)` → `CompareError::Cancelled` (encodes to atom
  `:cancelled`); any other error → `CompareError::Failed(e.to_string())`
  (encodes to `{:failed, msg}`). NIFs return `Result<f64, CompareError>`, so
  Elixir sees `{:error, :cancelled}` or `{:error, {:failed, msg}}`.

`native.ex` stubs updated: new `token_new/0`, `token_cancel/1`; `compare/6` and
`reference_compare/6` (added `cancel` arg).

### Elixir layer

**`Ssimulacra2.CancellationToken`** — the neutral primitive (named after the
well-known .NET `CancellationToken` so its purpose is obvious at a glance):

```elixir
defmodule Ssimulacra2.CancellationToken do
  defstruct [:resource]
  @type t :: %__MODULE__{resource: reference()}
  def new(), do: %__MODULE__{resource: Native.token_new()}
  def cancel(%__MODULE__{resource: r}), do: Native.token_cancel(r)
end
```

A token is single-use: once cancelled it stays cancelled (one-shot
`AtomicBool`). For a search, one token can cover the whole run — tripping it
aborts the in-flight probe and makes all subsequent probes return `:cancelled`
immediately.

**`Ssimulacra2.compare/5`** and **`Ssimulacra2.Reference.compare/3`** accept two
new opts (no arity break — `compare/5` already takes opts; `Reference.compare/2`
grows a `/3`):

- `:cancel` — a `%Ssimulacra2.CancellationToken{}` (or absent).
- `:timeout` — positive integer milliseconds (or absent).

**`Ssimulacra2.Cancellation`** (private) — shared timeout orchestration so both
call sites are identical:

```elixir
# run(cancel :: CancellationToken.t() | nil, timeout :: pos_integer() | nil, invoke)
# invoke.(token_resource_or_nil) -> {:ok, score}
#                                 | {:error, :cancelled}
#                                 | {:error, {:failed, msg}}
# returns {:ok, score} | {:error, :cancelled | :timeout | {:ssimulacra2, msg}}
```

Timeout orchestration (deterministic, pure Elixir):

1. `token = cancel || CancellationToken.new()`.
2. Spawn a canceller process:
   - `receive {:done, ref} -> send(parent, {:status, ref, :not_timed_out})`
   - `after timeout -> CancellationToken.cancel(token); send(parent, {:status, ref, :timed_out})`
3. Parent runs the NIF (blocks on the dirty scheduler), then
   `send(canceller, {:done, ref})` and reads `{:status, ref, s}`.
4. Map:
   - `{:ok, score}` → `{:ok, score}`.
   - `{:error, :cancelled}` and `s == :timed_out` → `{:error, :timeout}`.
   - `{:error, :cancelled}` otherwise → `{:error, :cancelled}`.
   - `{:error, {:failed, m}}` → `{:error, {:ssimulacra2, m}}`.

When only `:cancel` is given (no `:timeout`), skip the canceller: pass the
token's resource straight through and map `:cancelled` → `:cancelled`. When
neither is given, pass `nil`.

If both `:cancel` and `:timeout` are given, the timer trips the user's token. The
result is `:timeout` only when the *timer* fired; a token tripped externally
before the timer yields `:cancelled` (whichever cause the canceller observed
wins — the mapping is deterministic given that observation).

Validation: `:timeout`, when present, must be a positive integer; `:cancel`, when
present, must be a `%CancellationToken{}`. Reuse the existing `Validate` module
conventions.

`@type reason` gains `:cancelled | :timeout`. `compare!`, `Reference.compare!`
raise `Ssimulacra2.Error` on these as on any other reason.

## Data flow (cancel-from-another-process)

```
caller proc ──compare(.., cancel: tok)──▶ dirty scheduler thread (blocked, polling stop.check per strip)
   │
other proc ──CancellationToken.cancel(tok)──▶ token_cancel NIF (normal scheduler) ──▶ SyncStopper store=true
   │
dirty thread sees stop at next strip boundary ──▶ Err(Cancelled) ──▶ {:error, :cancelled} ──▶ caller unblocks
```

## Error handling

- Native cancellation → `{:error, :cancelled}`.
- Elixir-detected timeout → `{:error, :timeout}`.
- Other native errors → `{:error, {:ssimulacra2, msg}}` (unchanged).
- Invalid opts → existing validation reasons (plus `:invalid_timeout` if needed).
- No new crash paths; `compare!` / `compare!`-style raise on error as today.

## Testing (TDD)

- **Token basics:** `CancellationToken.new/0` returns a struct; `cancel/1`
  returns `:ok`.
- **Deterministic `:cancelled`:** pre-cancel a token, then `compare` returns
  `{:error, :cancelled}` quickly (first strip-boundary check).
- **Cross-process cancel:** run `compare` on a large fixture in a `Task`, cancel
  from the test process, assert `{:error, :cancelled}` and that it returned well
  before full completion.
- **`:timeout`:** large synthetic image + `timeout: 1` → `{:error, :timeout}`.
- **Score-identity gate (≥8px):** strip-with-stop (Unstoppable) score == the
  current non-strip golden. This is what makes the strip switch safe for the
  `≥8px` path (rgb888 is a sound proxy — all formats convert to linear RGB before
  the strip walk). Investigate any drift before accepting it.
- **Small-image no-regression:** a `<8px` comparison still returns `{:ok, score}`
  (it takes the non-strip cancellable path).
- **Completed-with-timeout:** generous `:timeout` returns `{:ok, score}` equal to
  the no-timeout score.
- **Reference mirrors:** all of the above for `Reference.compare/3`.

## Documentation

- Module docs for `Ssimulacra2` and `Ssimulacra2.Reference`: `:cancel` /
  `:timeout` opts, the `:cancelled` / `:timeout` reasons.
- `Ssimulacra2.CancellationToken` moduledoc: the neutral-primitive model, one-shot
  semantics, cancel-from-another-process pattern.
- README: cancellation usage example + the build-from-source note for the
  git-pin window.

## Open risks

- **Strip vs non-strip score identity (≥8px).** Expected identical (strip is a
  streaming reorganization of the same math with halo rows), but must be proven
  by the score-identity gate before the strip switch is accepted. Fallback if it
  drifts: use strip only when cancellation is requested (the size-dispatch shape
  already separates the two paths cleanly).
- **`SyncStopper` API surface.** Confirm `new()`, `cancel()`, and `enough::Stop`
  impl at the pinned SHA during implementation (docs assert all three).
```
