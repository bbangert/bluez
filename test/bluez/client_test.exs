defmodule Bluez.ClientTest do
  # The Client registers under its module name, so tests here must not
  # run alongside anything else starting it (nothing on host does — the
  # Bluetooth subtree is :ignore off-target).
  use ExUnit.Case, async: false

  alias Bluez.Client

  defmodule ConnStub do
    @moduledoc """
    Minimal stand-in for a `Bluez.Rebus.Connection` pid: answers the handler
    registrations `Client.init/1` performs and any other call with `:ok`.
    No D-Bus traffic ever flows in these tests (`setup: false` and an
    injected `apply_mode_fun` keep the Client away from the bus). The
    signal-handler ref is reported to the test pid (`{:sig_ref, ref}`) so
    tests can inject fake org.bluez signals into the Client.
    """
    use GenServer

    def start_link(test_pid \\ nil), do: GenServer.start_link(__MODULE__, test_pid)

    @impl true
    def init(test_pid), do: {:ok, test_pid}

    @impl true
    def handle_call({:add_signal_handler, _pid}, _from, test_pid) do
      ref = make_ref()
      if test_pid, do: send(test_pid, {:sig_ref, ref})
      {:reply, ref, test_pid}
    end

    def handle_call(_other, _from, state), do: {:reply, :ok, state}
  end

  defmodule BusStub do
    @moduledoc """
    A `Bluez.Rebus.Connection` stand-in that answers the setup path's
    D-Bus calls from a fixed org.bluez object tree: `GetManagedObjects`
    returns `objects` whole, `Properties.GetAll` the object's props, and
    every other method call an empty return (so `power_on` etc. succeed).
    """
    use GenServer

    alias Bluez.Rebus.Message

    def start_link(objects), do: GenServer.start_link(__MODULE__, objects)

    @impl true
    def init(objects), do: {:ok, objects}

    @impl true
    def handle_call({:add_signal_handler, _pid}, _from, objects),
      do: {:reply, make_ref(), objects}

    def handle_call({:send, %Message{header_fields: hf}}, _from, objects) do
      body =
        case hf[:member] do
          "GetManagedObjects" ->
            [objects]

          "GetAll" ->
            {_path, [{_iface, props}]} = List.keyfind(objects, hf[:path], 0)
            [props]

          _other ->
            []
        end

      {:reply, method_return(body), objects}
    end

    def handle_call(_other, _from, objects), do: {:reply, :ok, objects}

    defp method_return(body) do
      %Message{
        type: :method_return,
        flags: [],
        version: 1,
        body_length: 0,
        serial: 1,
        header_fields: %{},
        body: body
      }
    end
  end

  # Explicit on_exit kills: Client and ConnStub are only *linked* to the
  # test process, and links don't propagate a :normal exit — without
  # this they'd outlive the test for the rest of the suite run.
  defp start_client(opts) do
    {:ok, conn} = ConnStub.start_link(self())

    {:ok, client} =
      Client.start_link(
        Keyword.merge(
          [connect_fun: fn -> {:ok, conn} end, setup: false],
          opts
        )
      )

    on_exit(fn ->
      for pid <- [client, conn], Process.alive?(pid), do: Process.exit(pid, :kill)
    end)

    {:ok, client}
  end

  defp eventually(fun, tries \\ 50) do
    cond do
      fun.() ->
        true

      tries == 0 ->
        false

      true ->
        Process.sleep(10)
        eventually(fun, tries - 1)
    end
  end

  test "a stopped client does not leave its D-Bus connection behind" do
    alias Bluez.Rebus.{Message, TestServer}

    {:ok, svr} = start_supervised({TestServer, tap: self()})
    {:ok, addr} = TestServer.get_listen_addr(svr)
    test_pid = self()

    connect_fun = fn ->
      {:ok, conn} = Bluez.Rebus.connect(addr)
      send(test_pid, {:conn, conn})
      {:ok, conn}
    end

    # Started unlinked from a task: Client.init/1 blocks on the connection
    # until this test answers the bus Hello below.
    starter =
      Task.async(fn ->
        GenServer.start(Client, [connect_fun: connect_fun, setup: false], name: Client)
      end)

    assert_receive {:conn, conn}
    ref = Process.monitor(conn)
    assert_receive {^svr, %Message{header_fields: %{member: "Hello"}} = hello}

    :ok =
      TestServer.push(
        svr,
        Message.new!(:method_return,
          reply_serial: hello.serial,
          signature: "s",
          flags: [],
          body: [":1.100"]
        )
      )

    {:ok, client} = Task.await(starter)

    # Any client exit (a :no_adapter stop, a supervisor restart) must take
    # its connection with it.
    Process.exit(client, :kill)

    assert_receive {:DOWN, ^ref, :process, ^conn, {:shutdown, :owner_down}}
    # The supervisor handles the child's EXIT asynchronously: poll briefly.
    assert eventually(fn ->
             Bluez.Rebus.ConnectionSupervisor
             |> DynamicSupervisor.which_children()
             |> Enum.all?(fn {_, pid, _, _} -> pid != conn end)
           end)
  end

  test "watchdog stops the client when a transition neither completes nor dies" do
    Process.flag(:trap_exit, true)

    {:ok, client} =
      start_client(
        watchdog_ms: 100,
        apply_mode_fun: fn _conn, _engaged, _target -> Process.sleep(:infinity) end
      )

    # resume_scan starts a transition to the configured (:passive) mode;
    # the injected apply_mode_fun wedges forever, so only the watchdog
    # can unstick the state machine.
    GenServer.cast(client, :resume_scan)

    assert_receive {:EXIT, ^client, {:transition_stuck, :passive}}, 2_000
  end

  test "a killed transition task clears the wedge and the next set_mode proceeds" do
    Process.flag(:trap_exit, true)
    test_pid = self()
    {:ok, counter} = Agent.start_link(fn -> 0 end)

    # First transition wedges (and reports its task pid so we can kill
    # it); later transitions succeed immediately.
    apply_fun = fn _conn, _engaged, _target ->
      n = Agent.get_and_update(counter, fn n -> {n, n + 1} end)

      if n == 0 do
        send(test_pid, {:task_started, self()})
        Process.sleep(:infinity)
      else
        {:ok, :monitor}
      end
    end

    {:ok, client} = start_client(watchdog_ms: 60_000, apply_mode_fun: apply_fun)

    GenServer.cast(client, :resume_scan)
    assert_receive {:task_started, task_pid}, 1_000
    Process.exit(task_pid, :kill)

    # Without the task monitor, `transition` would stay set and this
    # call would park behind it until the watchdog/call timeout. The
    # short timeout proves the :DOWN handler cleared the wedge.
    assert :ok = GenServer.call(client, {:set_mode, :passive}, 2_000)
  end

  test "rssi_heartbeat_ms threads into the cache" do
    {:ok, client} = start_client(rssi_heartbeat_ms: 1_500)
    assert :sys.get_state(client).cache.heartbeat_ms == 1_500
  end

  test "rssi_heartbeat_ms defaults to 10_000 without the opt" do
    {:ok, client} = start_client([])
    assert :sys.get_state(client).cache.heartbeat_ms == 10_000
  end

  test "adverts fan out through the injected on_advertisement fun" do
    test_pid = self()

    {:ok, client} =
      start_client(on_advertisement: fn advert -> send(test_pid, {:advert, advert}) end)

    assert_receive {:sig_ref, sig_ref}

    # A Device1 InterfacesAdded under the (default) hci0 adapter path, in
    # rebus wire shape — drives the real signal → DeviceCache → emit path.
    msg = %Bluez.Rebus.Message{
      type: :signal,
      flags: [],
      version: 1,
      body_length: 0,
      serial: 1,
      header_fields: %{member: "InterfacesAdded"},
      body: [
        "/org/bluez/hci0/dev_AA_BB_CC_DD_EE_FF",
        [
          {"org.bluez.Device1",
           [
             {"Address", {"s", "AA:BB:CC:DD:EE:FF"}},
             {"AddressType", {"s", "public"}},
             {"RSSI", {"n", -50}}
           ]}
        ]
      ]
    }

    send(client, {sig_ref, msg})

    assert_receive {:advert, %{address: 0xAABBCCDDEEFF, rss: -50} = advert}
    assert Map.has_key?(advert, :address_type)
    assert Map.has_key?(advert, :raw_data)
  end

  describe "select_adapter/3" do
    @hci0 %{path: "/org/bluez/hci0", address: "00:00:00:00:00:A0"}
    @hci1 %{path: "/org/bluez/hci1", address: "00:00:00:00:00:A1"}
    @hci2 %{path: "/org/bluez/hci2", address: "00:00:00:00:00:A2"}
    @adapters [@hci2, @hci0, @hci1]

    test "with no exclusions: the desired adapter, else the lowest index" do
      assert Client.select_adapter(@adapters, @hci2.address, []) == {:ok, @hci2}
      assert Client.select_adapter(@adapters, nil, []) == {:ok, @hci0}

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          assert Client.select_adapter(@adapters, "00:00:00:00:00:FF", []) == {:ok, @hci0}
        end)

      assert log =~ "selected radio 00:00:00:00:00:FF not present"
    end

    test "an excluded lowest-index adapter is skipped" do
      assert Client.select_adapter(@adapters, nil, [@hci0.address]) == {:ok, @hci1}
    end

    test "an excluded desired adapter falls back among the rest" do
      log =
        ExUnit.CaptureLog.capture_log(fn ->
          assert Client.select_adapter(@adapters, @hci0.address, [@hci0.address]) ==
                   {:ok, @hci1}
        end)

      assert log =~ "selected radio #{@hci0.address} is excluded"
    end

    test "every adapter excluded is distinct from no adapter at all" do
      excluded = Enum.map(@adapters, & &1.address)
      assert Client.select_adapter(@adapters, nil, excluded) == {:error, :all_excluded}
      assert Client.select_adapter([], nil, excluded) == {:error, :no_adapter}
      assert Client.select_adapter([], nil, []) == {:error, :no_adapter}
    end

    test "exclusion matches a lower-case Address, and a lower-case desired MAC" do
      lower = %{@hci0 | address: "aa:bb:cc:dd:ee:ff"}
      excluded = Bluez.DevicePath.excluded_adapters_key()
      :persistent_term.put(excluded, ["aa:bb:cc:dd:ee:ff"])
      on_exit(fn -> :persistent_term.erase(excluded) end)

      # The read side normalises a host-published lower-case term.
      normalised = Bluez.DevicePath.excluded_adapters()
      assert normalised == ["AA:BB:CC:DD:EE:FF"]

      assert Client.select_adapter([lower, @hci1], nil, normalised) == {:ok, @hci1}

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          assert Client.select_adapter([lower, @hci1], "aa:bb:cc:dd:ee:ff", normalised) ==
                   {:ok, @hci1}
        end)

      assert log =~ "is excluded"
    end

    test "an adapter without an Address is never treated as excluded" do
      nameless = %{@hci0 | address: nil}
      assert Client.select_adapter([nameless], nil, [@hci0.address]) == {:ok, nameless}
    end
  end

  describe "setup claim with exclusions" do
    @describetag :capture_log

    setup do
      keys = [
        Bluez.DevicePath.adapter_path_key(),
        Bluez.DevicePath.resolved_adapter_key(),
        Bluez.DevicePath.desired_adapter_key(),
        Bluez.DevicePath.excluded_adapters_key()
      ]

      saved = for key <- keys, do: {key, :persistent_term.get(key, :unset)}

      on_exit(fn ->
        for {key, value} <- saved do
          if value == :unset,
            do: :persistent_term.erase(key),
            else: :persistent_term.put(key, value)
        end
      end)

      Enum.each(keys, &:persistent_term.erase/1)
    end

    defp adapter_object(index, address) do
      {"/org/bluez/hci#{index}",
       [
         {"org.bluez.Adapter1",
          [
            {"Address", {"s", address}},
            {"Name", {"s", "hci#{index}"}},
            {"Powered", {"b", true}}
          ]}
       ]}
    end

    # A Client wired to a BusStub serving `objects`, with setup deferred:
    # the test triggers the final setup attempt itself ({:setup_retry, 0}),
    # so no-adapter outcomes stop at once instead of after ~10 s of retries.
    defp start_setup_client(objects) do
      {:ok, bus} = BusStub.start_link(objects)

      {:ok, client} =
        Client.start_link(
          connect_fun: fn -> {:ok, bus} end,
          setup: false,
          apply_mode_fun: fn _conn, _engaged, _target -> {:ok, :monitor} end
        )

      on_exit(fn ->
        for pid <- [client, bus], Process.alive?(pid), do: Process.exit(pid, :kill)
      end)

      client
    end

    test "claims the next adapter and still lists the excluded one" do
      :persistent_term.put(Bluez.DevicePath.excluded_adapters_key(), ["aa:bb:cc:dd:ee:00"])

      client =
        start_setup_client([
          adapter_object(0, "AA:BB:CC:DD:EE:00"),
          adapter_object(1, "AA:BB:CC:DD:EE:01")
        ])

      send(client, {:setup_retry, 0})
      _ = :sys.get_state(client)

      assert Bluez.DevicePath.resolved_adapter_path() == {:ok, "/org/bluez/hci1"}
      assert Bluez.DevicePath.adapter_path() == "/org/bluez/hci1"

      # The host's radio list must still show the dedicated controller.
      assert client |> GenServer.call(:adapters_info) |> Enum.map(& &1.path) |> Enum.sort() ==
               ["/org/bluez/hci0", "/org/bluez/hci1"]
    end

    test "stops with :no_adapter, logging why, when every adapter is excluded" do
      Process.flag(:trap_exit, true)

      :persistent_term.put(Bluez.DevicePath.excluded_adapters_key(), ["AA:BB:CC:DD:EE:00"])
      client = start_setup_client([adapter_object(0, "AA:BB:CC:DD:EE:00")])

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          send(client, {:setup_retry, 0})
          assert_receive {:EXIT, ^client, :no_adapter}, 1_000
        end)

      assert log =~
               "all 1 Bluetooth adapter(s) present are excluded: " <>
                 "/org/bluez/hci0 (AA:BB:CC:DD:EE:00)"

      refute log =~ "no Bluetooth adapter appeared"
      assert Bluez.DevicePath.resolved_adapter_path() == :error
    end

    test "with no exclusions the desired adapter is claimed as before" do
      :persistent_term.put(Bluez.DevicePath.desired_adapter_key(), "AA:BB:CC:DD:EE:01")

      client =
        start_setup_client([
          adapter_object(0, "AA:BB:CC:DD:EE:00"),
          adapter_object(1, "AA:BB:CC:DD:EE:01")
        ])

      send(client, {:setup_retry, 0})
      _ = :sys.get_state(client)

      assert Bluez.DevicePath.resolved_adapter_path() == {:ok, "/org/bluez/hci1"}
    end
  end
end
