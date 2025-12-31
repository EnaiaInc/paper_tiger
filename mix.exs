defmodule PaperTiger.MixProject do
  @moduledoc false
  use Mix.Project

  @version "0.7.0"
  @url "https://github.com/EnaiaInc/paper_tiger"
  @maintainers ["Enaia Inc"]

  def project do
    [
      name: "PaperTiger",
      app: :paper_tiger,
      version: @version,
      elixir: "~> 1.16 or ~> 1.17 or ~> 1.18",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      elixirc_paths: elixirc_paths(Mix.env()),

      # Hex package
      package: package(),
      description: "A stateful mock Stripe server for testing Elixir applications - looks fierce, completely harmless",
      source_url: @url,
      homepage_url: @url,

      # Docs
      docs: docs(),

      # Quality tooling
      dialyzer: [
        ignore_warnings: ".dialyzer_ignore.exs",
        plt_add_apps: [:mix, :ex_unit]
      ],

      # Test coverage
      test_coverage: [tool: ExCoveralls],
      preferred_cli_env: [
        coveralls: :test,
        "coveralls.detail": :test,
        "coveralls.html": :test
      ]
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  def application do
    [
      extra_applications: [:logger, :crypto],
      mod: {PaperTiger.Application, []}
    ]
  end

  defp deps do
    [
      # HTTP server
      {:bandit, "~> 1.6"},
      {:plug, "~> 1.16"},

      # HTTP client for webhooks
      {:req, "~> 0.5"},

      # JSON
      {:jason, "~> 1.4"},

      # Testing/dev
      {:bypass, "~> 2.1", only: :test},
      {:mox, "~> 1.2", only: :test},
      {:stripity_stripe, "~> 3.2", only: :test},

      # Quality tooling
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false},
      {:ex_doc, "~> 0.35", only: :dev, runtime: false},
      {:quokka, "~> 2.7", only: [:dev, :test], runtime: false},
      {:mix_test_watch, "~> 1.2", only: :dev, runtime: false},
      {:excoveralls, "~> 0.18", only: :test}
    ]
  end

  defp package do
    [
      maintainers: @maintainers,
      licenses: ["MIT"],
      links: %{
        "Changelog" => "https://hexdocs.pm/paper_tiger/changelog.html",
        "GitHub" => @url
      },
      files:
        ~w(lib mix.exs README.md CHANGELOG.md LICENSE .formatter.exs) ++
          ~w(examples/getting_started.livemd),
      keywords: [
        "stripe",
        "testing",
        "mock",
        "payments",
        "subscriptions",
        "webhooks",
        "contract-testing",
        "elixir"
      ]
    ]
  end

  defp docs do
    [
      main: "readme",
      source_ref: "v#{@version}",
      source_url: @url,
      extras: [
        "README.md",
        "CHANGELOG.md",
        "examples/getting_started.livemd"
      ],
      extra_section: "GUIDES",
      groups_for_extras: [
        Examples: ~r/examples\/.*/,
        Changelog: ~r/CHANGELOG\.md/
      ],
      groups_for_modules: [
        "Public API": [PaperTiger],
        Resources: ~r/PaperTiger\.Resources\..*/,
        Storage: ~r/PaperTiger\.Store\..*/,
        Webhooks: ~r/PaperTiger\.Webhook.*/,
        Testing: ~r/PaperTiger\.Test.*/,
        Internal: ~r/PaperTiger\.(Clock|Router|Error|Plugs|Resource|Idempotency).*/
      ]
    ]
  end
end
