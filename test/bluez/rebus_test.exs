# Vendored from bbangert/rebus @ c6f7b64 (branch dbus-service, a fork of
# ausimian/rebus adding the service-side API), namespaced Rebus -> Bluez.Rebus
# so it can never collide with a hex rebus in a host app. MIT licensed —
# see lib/bluez/rebus/VENDORED.md. Upstreaming: ausimian/rebus#9.
defmodule Bluez.RebusTest do
  use ExUnit.Case
  doctest Bluez.Rebus

  alias Bluez.Rebus.Connection
  alias Bluez.Rebus.Message
  alias Bluez.Rebus.TestServer

  describe "Connections" do
    setup [:server_setup]

    test "can be established with inet socket", %{svr: svr} do
      {:ok, addr} = TestServer.get_listen_addr(svr)
      {:ok, _cli} = Bluez.Rebus.connect(addr)

      assert_receive {^svr, %Message{header_fields: %{member: "Hello"}}}
    end

    test "closes when its owner exits", %{svr: svr} do
      {:ok, addr} = TestServer.get_listen_addr(svr)
      test_pid = self()

      owner =
        spawn(fn ->
          send(test_pid, {:conn, Bluez.Rebus.connect(addr)})

          receive do
            :stop -> :ok
          end
        end)

      assert_receive {:conn, {:ok, conn}}
      assert_receive {^svr, %Message{header_fields: %{member: "Hello"}} = hello}
      handle_hello(hello, svr)
      ref = Process.monitor(conn)
      send(owner, :stop)

      assert_receive {:DOWN, ^ref, :process, ^conn, {:shutdown, :owner_down}}
    end

    test "an explicit :owner, not the creator, bounds the connection", %{svr: svr} do
      {:ok, addr} = TestServer.get_listen_addr(svr)
      test_pid = self()

      owner =
        spawn(fn ->
          receive do
            :stop -> :ok
          end
        end)

      # The creator connects on the owner's behalf, then exits.
      creator =
        spawn(fn -> send(test_pid, {:conn, Bluez.Rebus.connect(addr, owner: owner)}) end)

      creator_ref = Process.monitor(creator)
      assert_receive {:conn, {:ok, conn}}
      assert_receive {^svr, %Message{header_fields: %{member: "Hello"}} = hello}
      handle_hello(hello, svr)
      ref = Process.monitor(conn)

      assert_receive {:DOWN, ^creator_ref, :process, ^creator, _}
      refute_receive {:DOWN, ^ref, :process, ^conn, _}, 200
      assert Process.alive?(conn)

      send(owner, :stop)
      assert_receive {:DOWN, ^ref, :process, ^conn, {:shutdown, :owner_down}}
    end

    test "a bus that accepts but never answers AUTH times out cleanly" do
      {:ok, lsock} = :gen_tcp.listen(0, [:binary, active: false, ip: {127, 0, 0, 1}])
      {:ok, port} = :inet.port(lsock)
      test_pid = self()

      # Accept, swallow the AUTH line, never reply; report when the client
      # side closes the socket.
      spawn_link(fn ->
        {:ok, s} = :gen_tcp.accept(lsock)
        drain = fn drain -> if match?({:ok, _}, :gen_tcp.recv(s, 0)), do: drain.(drain) end
        drain.(drain)
        send(test_pid, :client_closed)
      end)

      baseline = DynamicSupervisor.count_children(Bluez.Rebus.ConnectionSupervisor).active
      started = System.monotonic_time(:millisecond)

      assert {:error, :timeout} =
               Bluez.Rebus.connect(%{family: :inet, addr: {127, 0, 0, 1}, port: port},
                 timeout: 200
               )

      assert System.monotonic_time(:millisecond) - started < 1_000
      assert_receive :client_closed, 1_000
      assert DynamicSupervisor.count_children(Bluez.Rebus.ConnectionSupervisor).active == baseline
    end

    test "connect! returns pid on success", %{svr: svr} do
      {:ok, addr} = TestServer.get_listen_addr(svr)
      pid = Bluez.Rebus.connect!(addr)

      assert is_pid(pid)
      assert_receive {^svr, %Message{header_fields: %{member: "Hello"}}}
    end

    test "connect! raises on failure" do
      # Try to connect to non-existent socket
      assert_raise RuntimeError, ~r/Failed to connect to D-Bus/, fn ->
        Bluez.Rebus.connect!(%{family: :inet, addr: {{127, 0, 0, 1}, 9999}})
      end
    end
  end

  describe "Unix socket connections" do
    test "can be established with unix socket" do
      # Use a short path to avoid Unix socket path length limit (108 bytes)
      socket_path =
        "/tmp/rebus_test_#{System.pid()}_#{:erlang.unique_integer([:positive])}.sock"

      # TestServer only unlinks the socket file when it traps exits, so
      # clean up here; a stale file from an earlier run is :eaddrinuse.
      File.rm(socket_path)
      on_exit(fn -> File.rm(socket_path) end)

      {:ok, svr} =
        start_supervised({Bluez.Rebus.TestServer, tap: self(), family: :local, path: socket_path})

      {:ok, _cli} = Bluez.Rebus.connect(%{family: :local, path: socket_path})

      assert_receive {^svr, %Message{header_fields: %{member: "Hello"}}}
    end
  end

  describe "Connection address parsing" do
    test ":system parses unix:path= format" do
      # Test with a non-existent path to verify parsing works
      Application.put_env(
        :rebus,
        :system_bus_address,
        "unix:path=/tmp/nonexistent-test-system-bus"
      )

      # This will fail to connect but tests address parsing
      result = Bluez.Rebus.connect(:system)

      # Should get a connection error, not a parsing error
      assert {:error, reason} = result
      assert reason != :no_system_bus_address

      # Clean up
      Application.delete_env(:rebus, :system_bus_address)
    end

    test ":system returns error when address is nil" do
      # Temporarily set address to nil
      Application.put_env(:rebus, :system_bus_address, nil)

      assert {:error, :no_system_bus_address} = Bluez.Rebus.connect(:system)

      # Clean up
      Application.delete_env(:rebus, :system_bus_address)
    end

    test ":session parses unix:path= format" do
      # Test with a non-existent path to verify parsing works
      System.put_env("DBUS_SESSION_BUS_ADDRESS", "unix:path=/tmp/nonexistent-test-session-bus")

      # This will fail to connect but tests address parsing
      result = Bluez.Rebus.connect(:session)

      # Should get a connection error, not a parsing error
      assert {:error, reason} = result
      assert reason != :no_session_bus_address

      # Clean up
      System.delete_env("DBUS_SESSION_BUS_ADDRESS")
    end

    test ":session returns error when DBUS_SESSION_BUS_ADDRESS is not set" do
      # Ensure the environment variable is not set
      original_value = System.get_env("DBUS_SESSION_BUS_ADDRESS")
      System.delete_env("DBUS_SESSION_BUS_ADDRESS")

      assert {:error, :no_session_bus_address} = Bluez.Rebus.connect(:session)

      # Restore original value if it existed
      if original_value do
        System.put_env("DBUS_SESSION_BUS_ADDRESS", original_value)
      end
    end
  end

  describe "Methods" do
    setup [:server_setup, :client_setup]

    test "block when called", %{cli: cli, svr: svr} do
      method =
        Message.new!(
          :method_call,
          path: "/org/freedesktop/DBus",
          member: "FakeMethod",
          signature: "s",
          flags: [],
          body: ["foobar"]
        )

      # Call the method (in a task to avoid blocking the test)
      task = Task.async(fn -> Connection.send(cli, method) end)
      # Confirm the server received it
      assert_receive {^svr, %Message{} = rcvd}
      assert rcvd.body == ["foobar"]

      # Reply to the method call to unblock the caller
      reply =
        Message.new!(
          :method_return,
          reply_serial: rcvd.serial,
          signature: "s",
          flags: [],
          body: ["response"]
        )

      TestServer.push(svr, reply)

      resp = Task.await(task)
      assert resp.body == ["response"]
    end
  end

  describe "Signals" do
    setup [:server_setup, :client_setup]

    test "are received", %{cli: cli, svr: svr} do
      # add a remove a signal handler to test that works
      ref = Bluez.Rebus.add_signal_handler(cli)
      Bluez.Rebus.delete_signal_handler(cli, ref)

      # Add one back
      ref = Bluez.Rebus.add_signal_handler(cli)

      # Send the NameAcquired signal
      signal =
        Message.new!(
          :signal,
          path: "/org/freedesktop/DBus",
          interface: "org.freedesktop.DBus",
          member: "FakeSignal",
          destination: ":1.100",
          signature: "s",
          flags: [],
          body: ["foobar"]
        )

      :ok = TestServer.push(svr, signal)

      assert_receive {^ref, %Message{body: ["foobar"]}}
    end

    test "emit_signal/2 emits a fire-and-forget signal", %{cli: cli, svr: svr} do
      # A realistic GATT notification body (PropertiesChanged with an `ay` Value).
      # emit_signal returns :ok synchronously: if the :signal were treated like a
      # method_call it would land in the pending-reply table and block until a
      # reply that never comes. Returning :ok proves it skips that table.
      assert :ok =
               Bluez.Rebus.emit_signal(cli,
                 path: "/up/improv/service0/char0",
                 interface: "org.freedesktop.DBus.Properties",
                 member: "PropertiesChanged",
                 signature: "sa{sv}as",
                 body: [
                   "org.bluez.GattCharacteristic1",
                   [{"Value", {"ay", [1, 2, 3]}}],
                   []
                 ]
               )

      assert_receive {^svr, %Message{type: :signal} = rcvd}
      assert rcvd.header_fields[:path] == "/up/improv/service0/char0"
      assert rcvd.header_fields[:interface] == "org.freedesktop.DBus.Properties"
      assert rcvd.header_fields[:member] == "PropertiesChanged"

      assert [
               "org.bluez.GattCharacteristic1",
               [{"Value", {"ay", [1, 2, 3]}}],
               []
             ] = rcvd.body
    end
  end

  defp server_setup(_) do
    # The 'tap' process will receive all messages received by the test server.
    # The server does not respond to any messages unless instructed to do so.
    {:ok, svr} = start_supervised({Bluez.Rebus.TestServer, tap: self()})
    %{svr: svr}
  end

  defp client_setup(%{svr: svr}) do
    {:ok, addr} = TestServer.get_listen_addr(svr)
    {:ok, cli} = Bluez.Rebus.connect(addr)

    assert_receive {^svr, %Message{header_fields: %{member: "Hello"}} = msg}
    handle_hello(msg, svr)

    %{cli: cli}
  end

  defp handle_hello(%Message{} = msg, svr) do
    reply =
      Message.new!(
        :method_return,
        reply_serial: msg.serial,
        signature: "s",
        flags: [],
        body: [":1.100"]
      )

    :ok = TestServer.push(svr, reply)

    signal =
      Message.new!(
        :signal,
        path: "/org/freedesktop/DBus",
        interface: "org.freedesktop.DBus",
        member: "NameAcquired",
        destination: ":1.100",
        signature: "s",
        flags: [],
        body: [":1.100"]
      )

    :ok = TestServer.push(svr, signal)
  end
end
