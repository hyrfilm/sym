defmodule Symd.MixProject do
  use Mix.Project

  def project do
    [
      app: :symd,
      version: "0.1.0",
      elixir: "~> 1.20",
      escript: [main_module: Symd.CLI, path: "../bin/symd"],
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
  end

  def application do
    [
      extra_applications: [:logger]
    ]
  end

  defp deps do
    [
      {:toml_elixir, "~> 3.2"}
    ]
  end
end
