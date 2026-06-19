defmodule Ssimulacra2.Validate do
  @moduledoc false

  @doc "Returns :ok or {:error, :invalid_dimensions}."
  def dims(width, height)
      when is_integer(width) and is_integer(height) and width > 0 and height > 0,
      do: :ok

  def dims(_, _), do: {:error, :invalid_dimensions}

  @doc "Returns :ok or {:error, :size_mismatch} for a packed RGB888 binary."
  def size(bin, width, height) do
    if byte_size(bin) == width * height * 3, do: :ok, else: {:error, :size_mismatch}
  end
end
