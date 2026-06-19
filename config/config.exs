import Config
if config_env() in [:dev, :test], do: config(:ssimulacra2, force_build: true)
