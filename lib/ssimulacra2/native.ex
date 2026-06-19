defmodule Ssimulacra2.Native do
  @moduledoc false

  version = Mix.Project.config()[:version]

  use RustlerPrecompiled,
    otp_app: :ssimulacra2,
    crate: "ssimulacra2_nif",
    base_url: "https://github.com/hlindset/ssimulacra2/releases/download/v#{version}",
    version: version,
    # Build locally for now; flip to a release-gated condition once artifacts are published (later task).
    force_build: true,
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
end
