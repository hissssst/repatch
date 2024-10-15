defmodule Repatch.MixProject do
  use Mix.Project

  def project do
    [
      app: :repatch,
      version: version(),
      elixir: "~> 1.12",
      elixirc_paths: elixirc_paths(),
      name: "Repatch",
      description: description(),
      package: package(),
      start_permanent: Mix.env() == :prod,
      source_url: "https://github.com/hissssst/repatch",
      docs: docs(),
      deps: deps()
    ]
  end

  def version do
    "0.0.1"
  end

  def description do
    "Tool for mocking in tests"
  end

  defp package do
    [
      description: description(),
      licenses: ["BSD-2-Clause"],
      files: [
        "lib",
        "mix.exs",
        "README.md",
        ".formatter.exs"
      ],
      maintainers: [
        "Georgy Sychev"
      ],
      links: %{
        GitHub: "https://github.com/hissssst/repatch",
        Changelog: "https://github.com/hissssst/repatch/blob/main/CHANGELOG.md"
      }
    ]
  end

  defp docs do
    [
      source_ref: version(),
      main: "readme",
      extras: ["README.md", "CHANGELOG.md"]
    ]
  end

  def application do
    []
  end

  defp deps do
    [
      # # Uncomment for development
      {:dialyxir, "~> 1.0", only: :dev, runtime: false},
      {:credo, "~> 1.5", only: :dev, runtime: false},
      {:ex_doc, "~> 0.28", only: :dev, runtime: false}
    ]
  end

  defp elixirc_paths(env \\ Mix.env())
  defp elixirc_paths(:test), do: elixirc_paths(:prod) ++ ["test/support"]
  defp elixirc_paths(_), do: ["lib"]
end
