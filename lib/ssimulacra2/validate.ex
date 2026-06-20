defmodule Ssimulacra2.Validate do
  @moduledoc false

  # atom => {channels, bytes_per_element}
  @formats %{
    rgb888: {3, 1},
    rgb16: {3, 2},
    linear_rgb: {3, 4},
    gray8: {1, 1},
    linear_gray: {1, 4}
  }

  @doc "Returns :ok or {:error, :invalid_dimensions}."
  def dims(width, height)
      when is_integer(width) and is_integer(height) and width > 0 and height > 0,
      do: :ok

  def dims(_, _), do: {:error, :invalid_dimensions}

  @doc "Returns :ok or {:error, :unknown_format}."
  def format(fmt) when is_map_key(@formats, fmt), do: :ok
  def format(_), do: {:error, :unknown_format}

  @doc "Returns :ok or {:error, :invalid_cancel}."
  def cancel(nil), do: :ok
  def cancel(%Ssimulacra2.CancellationToken{}), do: :ok
  def cancel(_), do: {:error, :invalid_cancel}

  @doc "Returns :ok or {:error, :invalid_timeout}."
  def timeout(nil), do: :ok
  def timeout(ms) when is_integer(ms) and ms > 0, do: :ok
  def timeout(_), do: {:error, :invalid_timeout}

  @doc """
  Returns :ok or {:error, :size_mismatch} for a packed binary of the given
  format. The format MUST be valid (call `format/1` first).
  """
  def size(bin, width, height, format) do
    {channels, elem_bytes} = Map.fetch!(@formats, format)

    if byte_size(bin) == width * height * channels * elem_bytes,
      do: :ok,
      else: {:error, :size_mismatch}
  end
end
