defmodule Ssimulacra2.Native do
  @moduledoc false

  version = Mix.Project.config()[:version]

  use RustlerPrecompiled,
    otp_app: :ssimulacra2,
    crate: "ssimulacra2_nif",
    base_url: "https://github.com/hlindset/ssimulacra2/releases/download/v#{version}",
    version: version,
    force_build:
      System.get_env("SSIMULACRA2_BUILD") in ["1", "true"] or
        Application.compile_env(:ssimulacra2, :force_build, false),
    nif_versions: ["2.15", "2.16", "2.17"],
    targets: ~w(
      aarch64-apple-darwin
      x86_64-apple-darwin
      x86_64-unknown-linux-gnu
      aarch64-unknown-linux-gnu
      x86_64-unknown-linux-musl
      aarch64-unknown-linux-musl
      x86_64-pc-windows-msvc
    )

  def nif_loaded, do: :erlang.nif_error(:nif_not_loaded)

  def compare(_reference, _distorted, _width, _height),
    do: :erlang.nif_error(:nif_not_loaded)

  def reference_new(_source, _width, _height),
    do: :erlang.nif_error(:nif_not_loaded)

  def reference_compare(_reference, _distorted, _width, _height),
    do: :erlang.nif_error(:nif_not_loaded)
end
