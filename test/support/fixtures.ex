defmodule Ssimulacra2.Fixtures do
  @moduledoc false

  @doc "A solid-color RGB888 binary of the given size."
  def solid(width, height, {r, g, b}) do
    :binary.copy(<<r, g, b>>, width * height)
  end

  @doc "A deterministic gradient RGB888 binary (varies per pixel)."
  def gradient(width, height) do
    for y <- 0..(height - 1), x <- 0..(width - 1), into: <<>> do
      <<rem(x, 256), rem(y, 256), rem(x + y, 256)>>
    end
  end
end
