defmodule Ssimulacra2.MixProject do
  use Mix.Project

  def project do
    [
      app: :ssimulacra2,
      version: "0.1.0",
      elixir: "~> 1.17",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      description: "SSIMULACRA2 perceptual image-quality metric for Elixir (fast-ssim2 NIF)",
      package: package(),
      name: "Ssimulacra2",
      source_url: "https://github.com/hlindset/ssimulacra2"
    ]
  end

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      extra_applications: [:logger]
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  # Filled in fully in a later task (Task 9). Placeholder so project/0 compiles now.
  defp package, do: []

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      {:rustler_precompiled, "~> 0.9"},
      {:rustler, ">= 0.0.0", optional: true},
      {:vix, "~> 0.31", optional: true},
      {:ex_doc, "~> 0.34", only: :dev, runtime: false}
    ]
  end
end
