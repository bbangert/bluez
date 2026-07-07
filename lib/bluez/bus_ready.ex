defmodule Bluez.BusReady do
  @moduledoc """
  A supervised gate that blocks in `init/1` until the D-Bus system-bus socket
  exists, so the next `:rest_for_one` sibling (`bluetoothd`) never starts
  before `dbus-daemon` is listening. Stays alive afterwards as an idle
  GenServer so `:rest_for_one` re-runs it whenever `dbus-daemon` restarts.
  """

  use GenServer
  require Logger

  @poll_interval_ms 100
  @timeout_ms 5_000

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl GenServer
  def init(_opts) do
    socket = Bluez.socket_path()

    case wait_for_socket(socket, @timeout_ms) do
      :ok ->
        Logger.info("Bluez: system bus socket ready at #{socket}")

      :timeout ->
        # Don't crash the boot — let bluetoothd start and MuonTrap retry it if
        # the bus is genuinely down. A warning is enough to flag the race.
        Logger.warning("Bluez: timed out waiting for #{socket}; starting bluetoothd anyway")
    end

    {:ok, %{}}
  end

  defp wait_for_socket(_socket, remaining) when remaining <= 0, do: :timeout

  defp wait_for_socket(socket, remaining) do
    if File.exists?(socket) do
      :ok
    else
      Process.sleep(@poll_interval_ms)
      wait_for_socket(socket, remaining - @poll_interval_ms)
    end
  end
end
