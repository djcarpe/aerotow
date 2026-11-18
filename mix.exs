defmodule Aerotow.MixProject do
  use Mix.Project

  @version "0.1.0"
  @source_url "https://github.com/djcarpe/aerotow"

  def project do
    [
      app: :aerotow,
      version: @version,
      elixir: "~> 1.18",
      start_permanent: Mix.env() == :prod,
      elixirc_paths: elixirc_paths(Mix.env()),
      deps: deps(),
      description:
        "One interface over many glider graphs: a catalog of metadata, and stores (files, directories, S3, other aerotows) the graphs are launched from.",
      package: package(),
      docs: docs(),
      name: "Aerotow",
      source_url: @source_url
    ]
  end

  def application do
    [extra_applications: [:logger, :xmerl]]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      # The glider engine and its NIF, from their repositories. glider is a
      # Rust crate, not a Mix project: it is fetched only because glider_ex's
      # NIF crate depends on it by path (`../../../glider`, which from
      # deps/glider_ex/native/glider_nif is deps/glider). Move both refs together.
      {:glider,
       github: "djcarpe/glider",
       ref: "7aed28154eae65f2e0f00c8a1c491a18ef7a8378",
       app: false,
       compile: false},
      {:glider_ex, github: "djcarpe/glider_ex", ref: "5c5db82568bcbd9b0e2f0e226c6650e8422b9d4d"},
      # Cards, flight records and peers travel over HTTP; Req signs S3 requests itself.
      {:req, "~> 0.5"},
      {:telemetry, "~> 1.1"},
      # Only for Aerotow.Plug, the HTTP surface another aerotow tows from.
      {:plug, "~> 1.16", optional: true},
      {:bandit, "~> 1.5", only: :test},
      {:ex_doc, "~> 0.34", only: :dev, runtime: false}
    ]
  end

  defp package do
    [
      licenses: ["MIT"],
      links: %{"GitHub" => @source_url},
      files: ~w(lib docs mix.exs README.md LICENSE)
    ]
  end

  defp docs do
    [main: "Aerotow", extras: ["README.md", "docs/DESIGN.md"]]
  end
end
