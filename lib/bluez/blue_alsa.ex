defmodule Bluez.BlueAlsa do
  @moduledoc """
  Persistent `rebus` D-Bus client to `org.bluealsa` (the bluez-alsa
  `bluealsad` daemon), used to learn which A2DP-playback PCMs are *ready to
  open* right now. This is the control-plane half of the Bluetooth-headphone
  audio path; the data plane is sendspin opening the ALSA PCM string directly.

  `pcms/0` returns, for every connected A2DP headset, what a host needs
  to open (or surface) its playback PCM:

      %{
        mac: "AA:BB:CC:DD:EE:FF",
        pcm_path: "/org/bluealsa/hci0/dev_.../a2dpsrc/sink",
        alsa_string: "bluealsa:DEV=AA:BB:CC:DD:EE:FF,PROFILE=a2dp",
        alias: "WH-1000XM4"   # org.bluez Device1.Alias, falls back to the MAC
      }

  ## Connection, not the daemon

  This client connects to the **system bus** (owned by `dbus-daemon`, the first
  child of `Bluez`), not to `bluealsad`. So it comes up whether
  or not `bluealsad` has claimed `org.bluealsa` yet; the `GetManagedObjects`
  call simply errors (→ `[]`) until the daemon is up, and starts returning PCMs
  once a headset connects. It survives a `bluealsad` restart without reconnecting.

  ## PCM enumeration (bluez-alsa v4 API)

  PCMs are discovered via the freedesktop `ObjectManager` at `/org/bluealsa`
  (each connected A2DP playback PCM is an `org.bluealsa.PCM1` object), **not**
  the v3 `org.bluealsa.Manager1.GetPCMs` method — buildroot ships bluez-alsa
  4.x, where that method no longer exists (it returns `UnknownMethod`, which the
  error path would silently swallow into `[]`).

  ## Inert off-target / when not started

  The `Bluez` subtree only runs on the BT targets, so on
  host/CI this GenServer isn't started. `pcms/0` catches the `:exit` from
  calling a non-existent process and returns `[]`, mirroring the exit-safe
  pattern used elsewhere in the Bluez layer — callers stay inert.

  Enrichment with the device `Alias` is a best-effort `org.bluez`
  `Properties.Get` on the same connection (BlueAlsa already proves D-Bus is
  reachable); a failed Alias lookup falls back to the MAC, never raises.
  """

  use GenServer
  require Logger

  alias Bluez.{DBus, Variant}

  @bluealsa "org.bluealsa"
  # bluez-alsa 4.x has NO `org.bluealsa.Manager1.GetPCMs` (that was the v3 API,
  # and calling it returns `UnknownMethod`). v4 exposes each PCM as an
  # `org.bluealsa.PCM1` object under `/org/bluealsa`, enumerated through the
  # standard freedesktop `ObjectManager` — the same pattern as `org.bluez`.
  @manager_path "/org/bluealsa"
  @object_manager_iface "org.freedesktop.DBus.ObjectManager"
  @pcm_iface "org.bluealsa.PCM1"
  @bluez_device_iface "org.bluez.Device1"
  @props_iface "org.freedesktop.DBus.Properties"

  # PubSub topic announcing that the BlueALSA PCM set changed (a headset
  # connected/disconnected, so a PCM appeared/vanished). `Audio.Server`
  # subscribes and re-enumerates — this is the authoritative trigger for the
  # audio side, because a BlueALSA PCM emits no kernel `sound` uevent and a
  # device can (re)connect via bluetoothd auto-reconnect *without* going through
  # `AudioManager` (so no `bluetooth:audio` event fires), and even an
  # AudioManager-driven `Device1.Connect` returns *before* the PCM exists.
  @pcms_topic "bluealsa:pcms"

  # GetManagedObjects is a local round-trip; keep a tight budget because
  # Audio.Server calls pcms/0 synchronously inside its 5 s refresh and must not
  # stall if bluealsad wedges.
  @call_timeout 2_000

  # Device path tail: `.../dev_AA_BB_CC_DD_EE_FF` (under any hciX). We pull the
  # MAC from the org.bluealsa PCM's Device path rather than the (adapter-scoped)
  # DevicePath helper so it works regardless of which adapter owns the headset.
  @dev_mac_re ~r"/dev_([0-9A-Fa-f_]{17})$"

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Connected A2DP-playback PCMs as a list of maps (see the moduledoc). `[]` when
  the daemon is down, no headset is connected, or this client isn't running.
  """
  @spec pcms() :: [
          %{mac: String.t(), pcm_path: String.t(), alsa_string: String.t(), alias: String.t()}
        ]
  def pcms do
    GenServer.call(__MODULE__, :pcms, @call_timeout + 1_000)
  catch
    :exit, _ -> []
  end

  @doc "PubSub topic broadcast when the BlueALSA PCM set changes."
  @spec pcms_topic() :: String.t()
  def pcms_topic, do: @pcms_topic

  @impl GenServer
  def init(opts) do
    case Rebus.connect(:system) do
      {:ok, conn} ->
        conn_ref = Process.monitor(conn)
        # Watch org.bluealsa's ObjectManager so we learn the instant a PCM
        # object is added/removed (headset (dis)connect). The match is on the
        # bus daemon, so it installs even before bluealsad owns the name;
        # signals start flowing once it emits them.
        sig_ref = Rebus.add_signal_handler(conn)

        DBus.add_match(
          conn,
          "type='signal',sender='#{@bluealsa}',interface='#{@object_manager_iface}'"
        )

        {:ok,
         %{
           conn: conn,
           conn_ref: conn_ref,
           sig_ref: sig_ref,
           # Phoenix.PubSub for {:bluealsa_pcms_changed} broadcasts; nil =
           # no-op (broadcast only when the host wires a PubSub).
           pubsub: Keyword.get(opts, :pubsub)
         }}

      {:error, reason} ->
        {:stop, {:dbus_connect_failed, reason}}
    end
  end

  @impl GenServer
  def handle_call(:pcms, _from, state) do
    {:reply, list_pcms(state.conn), state}
  end

  @impl GenServer
  def handle_info({:DOWN, ref, :process, _pid, reason}, %{conn_ref: ref} = state) do
    # The bus connection died (e.g. a malformed frame stopped it). Stop so the
    # Bluez supervisor restarts us with a fresh connection.
    {:stop, {:dbus_connection_down, reason}, state}
  end

  # A PCM object appeared/vanished. Don't bother inspecting the body — any
  # org.bluealsa ObjectManager change means re-checking the PCM set is due;
  # the downstream re-enumeration is cheap and debounced.
  def handle_info(
        {ref, %Rebus.Message{type: :signal, header_fields: %{member: member}}},
        %{sig_ref: ref} = state
      )
      when member in ["InterfacesAdded", "InterfacesRemoved"] do
    if state.pubsub do
      Phoenix.PubSub.broadcast(state.pubsub, @pcms_topic, {:bluealsa_pcms_changed})
    end

    {:noreply, state}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  # -- internals --

  defp list_pcms(conn) do
    case DBus.call_to(
           conn,
           @bluealsa,
           @manager_path,
           @object_manager_iface,
           "GetManagedObjects",
           "",
           [],
           @call_timeout
         ) do
      {:ok, [objects]} when is_list(objects) ->
        objects
        |> Enum.flat_map(&pcm_entry/1)
        |> Enum.flat_map(&playback_pcm(&1, conn))

      {:ok, other} ->
        Logger.warning("BlueAlsa GetManagedObjects unexpected reply: #{inspect(other)}")
        []

      {:error, _reason} ->
        # bluealsad not up yet / no org.bluealsa owner — inert until it is.
        []
    end
  end

  # A managed object is `{object_path, [{interface, props}]}`. Keep only the
  # ones carrying the `org.bluealsa.PCM1` interface, projecting to the
  # `{pcm_path, props_list}` shape `playback_pcm/2` consumes (so the parsing/
  # filtering below is unchanged from the old GetPCMs reply shape).
  defp pcm_entry({pcm_path, ifaces}) when is_binary(pcm_path) and is_list(ifaces) do
    case List.keyfind(ifaces, @pcm_iface, 0) do
      {_iface, props_list} -> [{pcm_path, props_list}]
      nil -> []
    end
  end

  defp pcm_entry(_other), do: []

  # Each entry is `{pcm_path, props_list}` (a{oa{sv}}). Keep only A2DP PCMs the
  # daemon is *sending* to a headset: Transport ~ "A2DP" and Mode == "sink"
  # (the client writes into a sink PCM; that audio is encoded out to the BT
  # device). HFP/SCO and the capture (source) direction are dropped.
  defp playback_pcm({pcm_path, props_list}, conn) when is_binary(pcm_path) do
    props = Variant.unwrap_props(props_list)
    transport = props["Transport"] || ""
    mode = props["Mode"]
    device_path = props["Device"]

    with true <- is_binary(device_path),
         true <- String.contains?(transport, "A2DP"),
         "sink" <- mode,
         {:ok, mac} <- mac_from_device_path(device_path) do
      [
        %{
          mac: mac,
          pcm_path: pcm_path,
          alsa_string: "bluealsa:DEV=#{mac},PROFILE=a2dp",
          alias: device_alias(conn, device_path, mac)
        }
      ]
    else
      _ -> []
    end
  end

  defp playback_pcm(_other, _conn), do: []

  defp mac_from_device_path(path) do
    case Regex.run(@dev_mac_re, path) do
      [_, dev] -> {:ok, dev |> String.replace("_", ":") |> String.upcase()}
      _ -> :error
    end
  end

  # Best-effort org.bluez Device1.Alias for a friendly card name; MAC on any
  # failure so a card always has a usable name.
  defp device_alias(conn, device_path, mac) do
    # Properties.Get returns a single variant `{signature, value}`.
    case DBus.call(
           conn,
           device_path,
           @props_iface,
           "Get",
           "ss",
           [@bluez_device_iface, "Alias"],
           @call_timeout
         ) do
      {:ok, [{_sig, name}]} when is_binary(name) and name != "" -> name
      _ -> mac
    end
  end
end
