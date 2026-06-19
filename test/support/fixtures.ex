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

  @doc "A deterministic 16-bit sRGB gradient (native-endian, w*h*6 bytes)."
  def gradient_rgb16(width, height) do
    for y <- 0..(height - 1), x <- 0..(width - 1), into: <<>> do
      <<rem(x * 257, 65_536)::native-16, rem(y * 257, 65_536)::native-16,
        rem((x + y) * 257, 65_536)::native-16>>
    end
  end

  @doc "A solid-color 16-bit sRGB binary."
  def solid_rgb16(width, height, {r, g, b}) do
    :binary.copy(<<r::native-16, g::native-16, b::native-16>>, width * height)
  end

  @doc "A deterministic linear-RGB f32 gradient in [0,1] (native-endian, w*h*12 bytes)."
  def gradient_linear_rgb(width, height) do
    for y <- 0..(height - 1), x <- 0..(width - 1), into: <<>> do
      <<(rem(x, 256) / 255)::native-float-32, (rem(y, 256) / 255)::native-float-32,
        (rem(x + y, 256) / 255)::native-float-32>>
    end
  end

  @doc "A solid linear-RGB f32 binary (each channel = v)."
  def solid_linear_rgb(width, height, v) do
    :binary.copy(<<v::native-float-32, v::native-float-32, v::native-float-32>>, width * height)
  end

  @doc "A deterministic 8-bit grayscale gradient (w*h bytes)."
  def gradient_gray8(width, height) do
    for y <- 0..(height - 1), x <- 0..(width - 1), into: <<>> do
      <<rem(x + y, 256)>>
    end
  end

  @doc "A solid 8-bit grayscale binary."
  def solid_gray8(width, height, v) do
    :binary.copy(<<v>>, width * height)
  end

  @doc "A deterministic linear grayscale f32 gradient in [0,1] (w*h*4 bytes)."
  def gradient_linear_gray(width, height) do
    for y <- 0..(height - 1), x <- 0..(width - 1), into: <<>> do
      <<(rem(x + y, 256) / 255)::native-float-32>>
    end
  end

  @doc "A solid linear grayscale f32 binary."
  def solid_linear_gray(width, height, v) do
    :binary.copy(<<v::native-float-32>>, width * height)
  end
end
