defmodule Bluez.MixProject do
  use Mix.Project

  @version "0.1.0"
  @source_url "https://github.com/bbangert/bluez"

  def project do
    [
      app: :bluez,
      version: @version,
      elixir: "~> 1.15",
      start_permanent: Mix.env() == :prod,
      elixirc_paths: elixirc_paths(Mix.env()),
      deps: deps(),
      dialyzer: [
        plt_local_path: "priv/plts",
        plt_core_path: "priv/plts",
        plt_add_apps: [:phoenix_pubsub]
      ],
      description:
        "BlueZ-over-D-Bus client for Elixir: BLE scanning, GATT, pairing, and bluez-alsa audio",
      package: package(),
      docs: docs(),
      source_url: @source_url
    ]
  end

  def application do
    [
      extra_applications: [:logger, :crypto]
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      # Vendored fork (bbangert/rebus @ dbus-service) until the service-side
      # API lands upstream — pins the exact commit, keeps the lib
      # self-contained. Swapped for hex rebus before `mix hex.publish`.
      {:rebus, path: "deps_local/rebus"},
      {:muontrap, "~> 1.8"},
      {:phoenix_pubsub, "~> 2.1", optional: true},
      {:ex_doc, "~> 0.34", only: :dev, runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false}
    ]
  end

  defp package do
    [
      licenses: ["Apache-2.0"],
      links: %{"GitHub" => @source_url},
      files: ~w(lib guides .formatter.exs mix.exs README.md CHANGELOG.md LICENSE)
    ]
  end

  defp docs do
    [
      main: "readme",
      source_url: @source_url,
      source_ref: "v#{@version}",
      extras: [
        "README.md",
        "CHANGELOG.md",
        "guides/architecture.md",
        "guides/host_integration.md"
      ],
      groups_for_extras: [
        Guides: ~r"guides/.*"
      ],
      groups_for_modules: [
        Supervision: [Bluez, Bluez.BusReady],
        Scanning: [Bluez.Client, Bluez.DeviceCache, Bluez.Advert],
        GATT: [
          Bluez.Gatt,
          Bluez.GattTree,
          Bluez.Gatt.Service,
          Bluez.Gatt.Characteristic,
          Bluez.Gatt.Descriptor
        ],
        Pairing: [Bluez.Agent],
        Audio: [Bluez.BlueAlsa],
        "D-Bus plumbing": [Bluez.DBus, Bluez.DevicePath, Bluez.Variant]
      ]
    ]
  end
end
