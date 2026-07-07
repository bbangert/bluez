defmodule Bluez do
  @moduledoc """
  Brings up the Linux BlueZ stack — `dbus-daemon`, `bluetoothd`, and
  (optionally) bluez-alsa — under one supervisor, with Elixir clients for
  BLE scanning (`Bluez.Client`), active GATT connections (`Bluez.Gatt`),
  pairing (`Bluez.Agent`), and A2DP audio PCM discovery (`Bluez.BlueAlsa`).

  Built for Nerves devices (read-only rootfs, `MuonTrap`-supervised
  daemons) but has no Nerves dependency; any Linux host where the calling
  application may own the system D-Bus instance works.

  Children, started `:rest_for_one`:

    1. `dbus-daemon --system` (`MuonTrap.Daemon`) — owns the system bus at
       `/run/dbus/system_bus_socket`.
    2. `Bluez.BusReady` — a one-line gate that blocks until the bus socket
       exists, so `bluetoothd` never races the bus. `:rest_for_one` re-runs
       it (and `bluetoothd`) if `dbus-daemon` restarts.
    3. `bluetoothd` (`MuonTrap.Daemon`) — claims `org.bluez`, drives the
       adapter via the kernel mgmt socket. Run with `-E` (experimental) —
       required for `AdvertisementMonitorManager1` passive scanning and the
       GATT `MTU` property.
    4. `Bluez.Client` — persistent `rebus` client owning the discovery
       session; adverts fan out through its `on_advertisement:` fun.
    5. `Bluez.Agent` — default NoInputNoOutput pairing agent.
    6. `Bluez.Gatt` (+ its `Task.Supervisor`) — active connections + GATT
       client; results flow through its `on_gatt_event:` fun.
    7. With `audio: true` (the default): `bluealsad` (`MuonTrap.Daemon`,
       A2DP source) and `Bluez.BlueAlsa` (org.bluealsa client). Placed
       after the scanning/GATT clients so an audio-daemon fault never
       restarts the scanning stack — the children that follow *do* restart
       with it under `:rest_for_one`, which is intended (same audio path).
    8. `extra_children:` — host-supplied child specs, appended last.

  ## Options

  All are optional; pass them to `start_link/1` (usually via a child spec
  `{Bluez, opts}`):

    * `client:` — keyword opts for `Bluez.Client` (`on_advertisement:`,
      `pubsub:`).
    * `gatt:` — keyword opts for `Bluez.Gatt` (`on_gatt_event:`,
      `on_connections_changed:`).
    * `audio:` — boolean (default `true`): start the `bluealsad` daemon +
      `Bluez.BlueAlsa` client. Requires bluez-alsa (v4 recommended) on the
      device.
    * `blue_alsa:` — keyword opts for `Bluez.BlueAlsa` (`pubsub:`).
    * `extra_children:` — host child specs appended at the end of the tree.
      Under `:rest_for_one` they restart with the audio path, and a fault
      there never disturbs the scanning/GATT stack above them. Ordering
      within the slot is the caller's contract.
    * `desired_adapter:` — MAC string (`"AA:BB:CC:DD:EE:FF"`) of the radio
      to drive, or `nil` (auto: lowest-index adapter). Written to
      `:persistent_term` before the children start. Hosts that switch
      radios at runtime may instead publish the term themselves under
      `Bluez.DevicePath.desired_adapter_key/0` BEFORE (re)starting this
      supervisor — the opt and the pre-published term coexist (the opt,
      when present, wins by writing last).
    * `dbus_daemon_path:` — dbus-daemon binary (default
      `/usr/bin/dbus-daemon`).
    * `bluetoothd_path:` — bluetoothd binary (default
      `/usr/libexec/bluetooth/bluetoothd`).
    * `bluealsad_paths:` — candidate bluez-alsa daemon binaries, first
      existing wins (default `["/usr/bin/bluealsad", "/usr/bin/bluealsa"]`
      — the daemon was renamed in bluez-alsa v4).

  ## Runtime requirements

    * BlueZ ≥ 5.66 (`bluetoothd -E`), dbus, and — for `audio: true` —
      bluez-alsa v4.
    * Writable `/run/dbus` and `/data/bluetooth` (`prepare_runtime/0`
      creates both and a machine-id before the daemons launch; on a
      read-only rootfs, point `/var/lib/bluetooth` at `/data/bluetooth`
      via an overlay symlink so `bluetoothd` can persist adapter state).
    * This supervisor OWNS the system bus: don't run it next to a distro
      dbus/bluetoothd.

  ## Public-API `catch :exit` idiom

  The synchronous read APIs (`Bluez.Client.adapters_info/0`,
  `Bluez.BlueAlsa.pcms/0`, `Bluez.Gatt.connections_free/0`, …) are meant
  to be wrapped by hosts in `catch :exit` so callers work while the stack
  is down. Be aware what that swallows: it converts BOTH the
  process-not-running exit AND a call timeout into the same "subsystem
  off" default — a wedged server renders as a disabled subsystem rather
  than raising. Accept that tradeoff knowingly, or catch only
  `:exit, {:timeout, _}` separately where the distinction matters.
  """

  use Supervisor

  @default_dbus_daemon "/usr/bin/dbus-daemon"
  @default_bluetoothd "/usr/libexec/bluetooth/bluetoothd"
  # bluez-alsa renamed the daemon `bluealsa` -> `bluealsad` in v4.0; resolve
  # at start, preferring the v4 name.
  @default_bluealsad_candidates ["/usr/bin/bluealsad", "/usr/bin/bluealsa"]
  @run_dir "/run/dbus"
  @socket_path "/run/dbus/system_bus_socket"
  @machine_id_path "/run/dbus/machine-id"
  # On a read-only rootfs, point /var/lib/bluetooth here via an overlay
  # symlink (see the moduledoc).
  @bluetooth_state_dir "/data/bluetooth"

  @doc "System-bus socket path the rebus clients connect to."
  @spec socket_path() :: String.t()
  def socket_path, do: @socket_path

  def start_link(opts \\ []) do
    Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl Supervisor
  def init(opts) do
    prepare_runtime()

    # Publish the desired radio before any child can resolve it (see the
    # `desired_adapter:` opt doc; Keyword.fetch so an explicit nil = auto
    # is also written, clearing a stale earlier selection).
    case Keyword.fetch(opts, :desired_adapter) do
      {:ok, mac} -> :persistent_term.put(Bluez.DevicePath.desired_adapter_key(), mac)
      :error -> :ok
    end

    # Explicit restart budget so the documented "benign endless retry
    # loop" (Client `{:stop, :no_adapter}` while the controller is absent)
    # is benign by configuration, not by cycle timing: an observed ~10 s
    # :no_adapter cycle (6/min) and a faster :dbus_connect_failed cycle
    # both fit in 10-per-60 s, while a genuinely hot crash loop still
    # escalates to the host's supervisor within a minute.
    Supervisor.init(children(opts), strategy: :rest_for_one, max_restarts: 10, max_seconds: 60)
  end

  @doc """
  The child list `init/1` supervises, exposed for child-order tests. See
  the moduledoc for the supported opts.
  """
  @spec children(keyword()) :: [Supervisor.child_spec() | {module(), term()} | module()]
  def children(opts) do
    [
      # System bus. --nofork so MuonTrap's port owns the process; --nopidfile
      # because /var/run may be read-only and we don't read a pidfile anyway.
      # The daemons are all MuonTrap.Daemon, so each needs a distinct child
      # :id (the default id is the module, which collides).
      Supervisor.child_spec(
        {MuonTrap.Daemon,
         [
           Keyword.get(opts, :dbus_daemon_path, @default_dbus_daemon),
           ["--system", "--nofork", "--nopidfile"],
           [name: __MODULE__.Dbus, log_output: :info, log_prefix: "dbus-daemon: "]
         ]},
        id: :dbus_daemon
      ),

      # Gate: bluetoothd must not start before the bus socket exists.
      __MODULE__.BusReady,

      # The BlueZ daemon. -n keeps it in the foreground (MuonTrap tracks it);
      # -E enables experimental interfaces, required for
      # org.bluez.AdvertisementMonitorManager1 (passive scanning). stderr
      # carries its logs.
      Supervisor.child_spec(
        {MuonTrap.Daemon,
         [
           Keyword.get(opts, :bluetoothd_path, @default_bluetoothd),
           ["-n", "-E"],
           [
             name: __MODULE__.Bluetoothd,
             env: [{"DBUS_SYSTEM_BUS_ADDRESS", "unix:path=#{@socket_path}"}],
             stderr_to_stdout: true,
             log_output: :info,
             log_prefix: "bluetoothd: "
           ]
         ]},
        id: :bluetoothd
      ),

      # Persistent rebus client: owns the discovery session and turns BlueZ
      # device signals into advertisements, fanned out via its
      # `on_advertisement:` opt. After bluetoothd in rest_for_one order so
      # it (re)connects only once bluetoothd is up.
      {__MODULE__.Client, Keyword.get(opts, :client, [])},

      # Default org.bluez pairing agent: bluetoothd routes the IO for
      # Gatt's Device1.Pair() calls here. Before Gatt in rest_for_one
      # order — Gatt depends on it (weakly: its casts no-op when the Agent
      # is down), never the other way around.
      __MODULE__.Agent,

      # Every BlueZ call the GATT client makes runs under this
      # Task.Supervisor so its GenServer loop never blocks on D-Bus
      # (Device1.Connect alone can take ~25 s).
      {Task.Supervisor, name: __MODULE__.Gatt.task_supervisor()},

      # The GATT client itself (its own rebus connection, separate from
      # Client). Last so a bluetoothd/Client restart also rebuilds it —
      # its device objects and connection state die with bluetoothd.
      {__MODULE__.Gatt, Keyword.get(opts, :gatt, [])}
    ] ++
      audio_children(opts) ++
      Keyword.get(opts, :extra_children, [])
  end

  # bluez-alsa A2DP-source daemon + the org.bluealsa client, gated on the
  # `audio:` opt. No `-i`: bluealsad manages all controllers; role
  # separation (which adapter may pair/connect headsets) is the host's
  # concern. Placed after the scanning/GATT clients: a crash here never
  # restarts the scanning stack (only the children that follow restart
  # with it under :rest_for_one). See the moduledoc.
  defp audio_children(opts) do
    if Keyword.get(opts, :audio, true) do
      [
        Supervisor.child_spec(
          {MuonTrap.Daemon,
           [
             bluealsad_path(opts),
             ["-p", "a2dp-source"],
             [
               name: __MODULE__.BlueAlsad,
               env: [{"DBUS_SYSTEM_BUS_ADDRESS", "unix:path=#{@socket_path}"}],
               stderr_to_stdout: true,
               log_output: :info,
               log_prefix: "bluealsad: "
             ]
           ]},
          id: :bluealsad
        ),

        # org.bluealsa D-Bus client: learns which A2DP-playback PCMs are
        # ready to open. Connects to the system bus (dbus-daemon), not to
        # bluealsad, so it tolerates bluealsad being down.
        {__MODULE__.BlueAlsa, Keyword.get(opts, :blue_alsa, [])}
      ]
    else
      []
    end
  end

  @doc """
  Create the writable dirs the daemons need before they launch. Idempotent;
  safe to call on every (re)start of this supervisor (`init/1` does).
  """
  @spec prepare_runtime() :: :ok
  def prepare_runtime do
    File.mkdir_p!(@run_dir)
    # A previous incarnation's socket file survives its dbus-daemon
    # (runtime stop/start by the host) — and a stale file makes BusReady
    # wave clients through to ECONNREFUSED before the NEW daemon has bound
    # it. Hardware-found on the first enable→disable→enable round-trip.
    # Remove it so socket existence again implies a listener.
    _ = File.rm(@socket_path)
    File.mkdir_p!(@bluetooth_state_dir)
    # bluetoothd stores pairing/link keys + the adapter identity here; keep it
    # owner-only rather than the default world-readable 0755.
    File.chmod!(@bluetooth_state_dir, 0o700)
    ensure_machine_id()
    :ok
  end

  # dbus tolerates a generated/ephemeral machine-id, but write a stable one to
  # the writable run dir so every component on the bus agrees. 32 lowercase hex
  # chars, no dashes — the D-Bus machine-id format.
  defp ensure_machine_id do
    unless File.exists?(@machine_id_path) do
      id = :crypto.strong_rand_bytes(16) |> Base.encode16(case: :lower)
      File.write!(@machine_id_path, id <> "\n")
    end
  end

  # Resolve the bluez-alsa daemon binary from the candidates: first existing
  # wins; when none exists the first candidate is returned so the child spec
  # is still well-formed — MuonTrap surfaces the missing-binary error at
  # start.
  defp bluealsad_path(opts) do
    candidates = Keyword.get(opts, :bluealsad_paths, @default_bluealsad_candidates)
    Enum.find(candidates, &File.exists?/1) || hd(candidates)
  end
end
