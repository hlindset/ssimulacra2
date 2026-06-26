defmodule Ssimulacra2 do
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

  ## Cancellation

  `compare/5` and `Ssimulacra2.Reference.compare/3` accept `cancel:` (an
  `Ssimulacra2.CancelRef`) and `timeout:` (milliseconds) to abort a long
  comparison mid-computation, returning `{:error, :cancelled}` or
  `{:error, :timeout}`. Create a ref with `Ssimulacra2.CancelRef.new/0` and trip
  it with `cancel/1`.
  """

  alias Ssimulacra2.{Cancellation, CancelRef, Native, Validate}

  @type image_data :: binary()
  @type reason ::
          :invalid_dimensions
          | :size_mismatch
          | :dimension_mismatch
          | :unknown_format
          | :invalid_cancel
          | :invalid_timeout
          | :cancelled
          | :timeout
          | {:ssimulacra2, String.t()}

  @doc """
  Compare a reference and distorted image of the same dimensions.

  Pass `format:` to select the packed pixel layout; it defaults to `:rgb888`
  (packed 8-bit sRGB, `byte_size == width * height * 3`). Other supported
  formats are `:rgb16`, `:linear_rgb`, `:gray8`, and `:linear_gray`.

  Returns `{:ok, score}` or `{:error, reason}`.

  ## Cancellation

  Pass `cancel:` an `Ssimulacra2.CancelRef` to abort the comparison from
  another process (e.g. on client disconnect) — the call returns
  `{:error, :cancelled}`. Pass `timeout:` a positive integer of milliseconds to
  bound the wall-clock time — the call returns `{:error, :timeout}` if it
  exceeds that. Both may be combined; cancellation is checked at strip
  boundaries, so the CPU is freed promptly without leaving the dirty scheduler.

  Invalid options return `{:error, :invalid_cancel}` / `{:error, :invalid_timeout}`.
  """
  @spec compare(image_data(), image_data(), pos_integer(), pos_integer(), keyword()) ::
          {:ok, float()} | {:error, reason()}
  def compare(reference, distorted, width, height, opts \\ [])
      when is_binary(reference) and is_binary(distorted) do
    format = Keyword.get(opts, :format, :rgb888)
    cancel = Keyword.get(opts, :cancel)
    timeout = Keyword.get(opts, :timeout)

    with :ok <- Validate.format(format),
         :ok <- Validate.dims(width, height),
         :ok <- Validate.size(reference, width, height, format),
         :ok <- Validate.size(distorted, width, height, format),
         :ok <- Validate.cancel(cancel),
         :ok <- Validate.timeout(timeout) do
      Cancellation.run(cancel, timeout, fn resource ->
        Native.compare(reference, distorted, width, height, format, resource)
      end)
    end
  end

  @doc """
  Like `compare/5` but returns the bare score and raises `Ssimulacra2.Error`
  on failure. Accepts the same `format:` option, defaulting to `:rgb888`.
  """
  @spec compare!(image_data(), image_data(), pos_integer(), pos_integer(), keyword()) :: float()
  def compare!(reference, distorted, width, height, opts \\ []) do
    case compare(reference, distorted, width, height, opts) do
      {:ok, score} -> score
      {:error, reason} -> raise Ssimulacra2.Error, reason: reason
    end
  end

  @doc """
  Trip an `Ssimulacra2.CancelRef`, aborting any comparison that uses it.

  Call from any process to cancel an in-flight `compare/5` or
  `Ssimulacra2.Reference.compare/3` that was passed this ref as `cancel:`.
  Returns `:ok` and is safe to call more than once.
  """
  @spec cancel(CancelRef.t()) :: :ok
  def cancel(%CancelRef{resource: r}), do: Native.token_cancel(r)
end
