defmodule Bluez.Agent do
  @moduledoc """
  The `org.bluez.Agent1` pairing agent backing `Bluez.Gatt`'s `pair/1`
  (Phase 2 of the Bluetooth proxy).

  bluetoothd resolves pairing IO through an agent: when `Device1.Pair()`
  is called it uses the agent registered by the *calling* D-Bus
  connection, falling back to the bus-wide **default agent**. The Pair
  call is made on `Bluez.Gatt`'s connection (which registers no agent),
  so this process must be the default agent — `RegisterAgent` alone is
  not enough; `RequestDefaultAgent` is what routes Gatt's pairings here.

  Capability is `NoInputNoOutput`, so bluetoothd negotiates Just Works
  with every peripheral — the same IO posture as an ESP32 ESPHome proxy.
  Just Works pairing normally completes without any agent callback;
  everything below is for the exceptional paths.

  ## Security posture

  A default agent answers for *all* pairing on the adapter, including a
  hypothetical inbound attempt (the adapter is never made discoverable,
  so none is expected). Authorization-style callbacks
  (`RequestConfirmation`, `RequestAuthorization`, `AuthorizeService`)
  are therefore confirmed **only for device paths with an in-flight
  `Device1.Pair()` we initiated** — `Bluez.Gatt` brackets each Pair call
  with `expect_pairing/1` / `pairing_done/1` — and rejected otherwise.
  PIN/passkey callbacks are always rejected: we have no IO to display or
  collect one, and under NoInputNoOutput bluetoothd should never send
  them.

  Like `Bluez.Client`, this is both a D-Bus client (registration calls)
  and a service (bluetoothd calls back into our exported object) on its
  own rebus connection — its failure domain is pairing only; scanning
  and GATT traffic are untouched. If the Agent is down, `Pair()` still
  proceeds for devices that need no interaction; anything needing the
  agent fails cleanly on the BlueZ side.
  """

  use GenServer
  require Logger

  alias Bluez.{DBus, DevicePath}

  @bluez_path "/org/bluez"
  @agent_mgr_iface "org.bluez.AgentManager1"
  @agent_iface "org.bluez.Agent1"
  @introspect_iface "org.freedesktop.DBus.Introspectable"

  @agent_path "/org/exbluez/agent"
  @capability "NoInputNoOutput"

  @rejected "org.bluez.Error.Rejected"

  # bluetoothd may not have claimed org.bluez the instant we start (same
  # window Bluez.Client retries through).
  @setup_retries 20
  @setup_retry_ms 500

  # Backstop for a pair Task that died without calling pairing_done/1
  # (crash, kill, supervisor shutdown): an expectation older than this
  # cannot belong to a live Pair() (Gatt's pair timeout is 35 s) and must
  # not stay authorized.
  @expect_ttl_ms 40_000

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "Object path our Agent1 implementation is exported at."
  @spec agent_path() :: String.t()
  def agent_path, do: @agent_path

  @doc """
  Mark `device_path` as having an in-flight `Device1.Pair()` we initiated,
  so authorization callbacks for it are confirmed.

  Synchronous on purpose: the caller issues `Pair()` right after, and a
  cast could still be in our mailbox when bluetoothd's authorization
  callback arrives — rejecting a pairing we initiated. The return is `:ok`
  even when the Agent isn't running (pairing then degrades to whatever
  BlueZ can do agent-less rather than crashing the pair Task) or the path
  is refused (the pairing fails closed on the BlueZ side).

  Expectations expire after #{@expect_ttl_ms} ms as a backstop for a pair
  Task that died without calling `pairing_done/1`.
  """
  @spec expect_pairing(String.t()) :: :ok
  def expect_pairing(device_path) do
    GenServer.call(__MODULE__, {:expect, device_path})
  catch
    # Not running / registration-window timeout — degrade, don't crash.
    :exit, _reason -> :ok
  end

  @doc "Remove `device_path` from the in-flight pairing set."
  @spec pairing_done(String.t()) :: :ok
  def pairing_done(device_path), do: GenServer.cast(__MODULE__, {:done, device_path})

  @doc """
  Decide the reply for an inbound `org.bluez.Agent1` call. Pure — exposed
  for tests.

  Returns `:ack` (empty success reply), `{:reject, error_name}`, or
  `:unknown` (not an Agent1 member we implement). `expected` is the
  in-flight pairing map (`device_path => expiry ref`).
  """
  @spec decide(String.t(), list(), %{optional(String.t()) => reference()}) ::
          :ack | {:reject, String.t()} | :unknown
  def decide(member, body, expected) do
    case member do
      # bluetoothd released or aborted us — nothing to answer beyond an ack.
      "Release" ->
        :ack

      "Cancel" ->
        :ack

      # Authorization family: confirm only pairings we initiated.
      "RequestConfirmation" ->
        authorize(body, expected)

      "RequestAuthorization" ->
        authorize(body, expected)

      "AuthorizeService" ->
        authorize(body, expected)

      # PIN/passkey family: no IO to satisfy these, ever.
      m when m in ~w(RequestPinCode DisplayPinCode RequestPasskey DisplayPasskey) ->
        {:reject, @rejected}

      _other ->
        :unknown
    end
  end

  defp authorize([device_path | _rest], expected) when is_binary(device_path) do
    if Map.has_key?(expected, device_path),
      do: :ack,
      else: {:reject, @rejected}
  end

  defp authorize(_bad_body, _expected), do: {:reject, @rejected}

  # ── GenServer ─────────────────────────────────────────────────────────────

  @impl GenServer
  def init(_opts) do
    case Rebus.connect(:system) do
      {:ok, conn} ->
        Rebus.set_method_handler(conn, self())
        conn_ref = Process.monitor(conn)

        state = %{conn: conn, conn_ref: conn_ref, expected: %{}}
        {:ok, state, {:continue, {:register, @setup_retries}}}

      {:error, reason} ->
        {:stop, {:dbus_connect_failed, reason}}
    end
  end

  @impl GenServer
  def handle_continue({:register, retries}, state), do: attempt_register(state, retries)

  @impl GenServer
  def handle_call({:expect, device_path}, _from, state) do
    # Only paths we could have built ourselves (DevicePath.from_address on a
    # validated MAC) are authorizable — keeps the trust boundary explicit
    # even if a future caller passes an attacker-influenced string. Refusal
    # still replies :ok: the caller can't act on it, and the pairing simply
    # fails closed at the agent.
    case DevicePath.to_address(device_path) do
      {:ok, _address} ->
        ref = make_ref()
        Process.send_after(self(), {:expire, device_path, ref}, @expect_ttl_ms)
        {:reply, :ok, put_in(state.expected[device_path], ref)}

      :error ->
        Logger.warning("Bluez.Agent: refused to expect non-device path #{inspect(device_path)}")
        {:reply, :ok, state}
    end
  end

  @impl GenServer
  def handle_cast({:done, device_path}, state),
    do: {:noreply, update_in(state.expected, &Map.delete(&1, device_path))}

  @impl GenServer
  def handle_info({:setup_retry, retries}, state), do: attempt_register(state, retries)

  # TTL backstop: only clear the expectation if it's still the same one we
  # armed the timer for (a re-pair meanwhile installed a fresh ref).
  def handle_info({:expire, device_path, ref}, state) do
    case state.expected[device_path] do
      ^ref ->
        Logger.warning("Bluez.Agent: pairing expectation for #{device_path} expired unanswered")
        {:noreply, update_in(state.expected, &Map.delete(&1, device_path))}

      _other ->
        {:noreply, state}
    end
  end

  # Inbound method calls from bluetoothd into our exported agent object.
  def handle_info({:dbus_call, %Rebus.Message{} = msg}, state) do
    dispatch_method_call(msg, state)
    {:noreply, state}
  end

  # Connection died — stop so the supervisor restarts and re-registers us.
  def handle_info({:DOWN, ref, :process, _pid, reason}, %{conn_ref: ref} = state) do
    {:stop, {:dbus_connection_down, reason}, state}
  end

  def handle_info(_other, state), do: {:noreply, state}

  # ── registration ──────────────────────────────────────────────────────────

  # RegisterAgent + RequestDefaultAgent never call back into the agent, so
  # (unlike Client's RegisterMonitor) they are safe to run in the GenServer
  # loop; both are bounded by DBus.call's timeout.
  defp attempt_register(state, retries) do
    case register(state.conn) do
      :ok ->
        Logger.info("Bluez.Agent: registered as default pairing agent (#{@capability})")
        {:noreply, state}

      {:error, reason} when retries > 0 ->
        Logger.debug("Bluez.Agent: registration not ready (#{inspect(reason)}), retrying")
        Process.send_after(self(), {:setup_retry, retries - 1}, @setup_retry_ms)
        {:noreply, state}

      {:error, reason} ->
        # bluetoothd is up for everyone else in this subtree, so a persistent
        # refusal means something is genuinely wrong — restart-with-subtree.
        Logger.error("Bluez.Agent: agent registration failed: #{inspect(reason)}")
        {:stop, {:agent_registration_failed, reason}, state}
    end
  end

  defp register(conn) do
    with {:ok, _} <-
           register_call(conn, "RegisterAgent", "os", [@agent_path, @capability]),
         # Device1.Pair() runs on Gatt's connection, which has no agent of
         # its own — only default-agent status routes its pairings to us.
         {:ok, _} <- register_call(conn, "RequestDefaultAgent", "o", [@agent_path]) do
      :ok
    end
  end

  defp register_call(conn, member, signature, body) do
    case DBus.call(conn, @bluez_path, @agent_mgr_iface, member, signature, body) do
      # Leftover registration from a half-torn-down predecessor — goal reached.
      {:error, "org.bluez.Error.AlreadyExists"} -> {:ok, []}
      other -> other
    end
  end

  # ── inbound method-call dispatch ──────────────────────────────────────────

  defp dispatch_method_call(%Rebus.Message{header_fields: hf} = msg, state) do
    conn = state.conn

    case hf[:interface] do
      @agent_iface ->
        case decide(hf[:member], msg.body, state.expected) do
          :ack ->
            Rebus.reply(conn, msg)

          {:reject, error_name} ->
            Logger.info("Bluez.Agent: rejected #{hf[:member]} #{inspect(msg.body)}")
            Rebus.reply_error(conn, msg, error_name, hf[:member])

          :unknown ->
            unknown_method(conn, msg, hf)
        end

      @introspect_iface ->
        Rebus.reply(conn, msg, [introspect_xml(hf[:path])], "s")

      _other ->
        unknown_method(conn, msg, hf)
    end
  rescue
    e ->
      Logger.warning("Bluez.Agent: inbound call handling raised #{inspect(e)}")
      # Always answer a reply-expecting call so bluetoothd doesn't block on
      # its timeout; reply_error/4 no-ops for NO_REPLY_EXPECTED notifications.
      Rebus.reply_error(
        state.conn,
        msg,
        "org.freedesktop.DBus.Error.Failed",
        Exception.message(e)
      )
  end

  defp unknown_method(conn, msg, hf) do
    Rebus.reply_error(
      conn,
      msg,
      "org.freedesktop.DBus.Error.UnknownMethod",
      "#{hf[:interface]}.#{hf[:member]}"
    )
  end

  defp introspect_xml(path) do
    interfaces = if path == @agent_path, do: ~s(<interface name="#{@agent_iface}"/>), else: ""

    ~s(<!DOCTYPE node PUBLIC "-//freedesktop//DTD D-BUS Object Introspection 1.0//EN" "http://www.freedesktop.org/standards/dbus/1.0/introspect.dtd">\n<node>#{interfaces}</node>)
  end
end
