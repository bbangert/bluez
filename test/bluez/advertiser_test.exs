defmodule Bluez.AdvertiserTest do
  use ExUnit.Case, async: true

  alias Bluez.{AdData, Advertiser}
  alias Bluez.Rebus.{Message, TestServer}

  @adapter "/org/bluez/hci0"

  describe "properties/1" do
    test "keeps ServiceUUIDs in order with duplicates (the payload-in-UUIDs case)" do
      payload = <<0x01, 0x02, 0x01, 0x02, 0x03, 0x04>>
      uuids = AdData.uuid16_strings(payload)

      assert {:ok, props} = Advertiser.properties(%{type: :broadcast, service_uuids: uuids})
      assert {"Type", {"s", "broadcast"}} in props
      assert {"ServiceUUIDs", {"as", ^uuids}} = List.keyfind(props, "ServiceUUIDs", 0)
      assert length(uuids) == 3
    end

    test "encodes byte maps as ay lists and scalar options with their D-Bus types" do
      {:ok, props} =
        Advertiser.properties(%{
          type: :peripheral,
          manufacturer_data: %{0x07D0 => <<1, 2>>},
          service_data: %{"fcd2" => <<3>>},
          data: %{0x2A => <<4>>},
          local_name: "lamp",
          discoverable: true,
          min_interval_ms: 20,
          max_interval_ms: 30,
          tx_power: -4
        })

      assert List.keyfind(props, "ManufacturerData", 0) ==
               {"ManufacturerData", {"a{qv}", [{0x07D0, {"ay", [1, 2]}}]}}

      assert List.keyfind(props, "ServiceData", 0) ==
               {"ServiceData", {"a{sv}", [{"fcd2", {"ay", [3]}}]}}

      assert List.keyfind(props, "Data", 0) == {"Data", {"a{yv}", [{0x2A, {"ay", [4]}}]}}
      assert {"MinInterval", {"u", 20}} in props
      assert {"TxPower", {"n", -4}} in props
    end

    test "rejects invalid map keys instead of silently dropping them" do
      for spec <- [
            %{type: :broadcast, manufacturer_data: %{65_536 => <<1>>}},
            %{type: :broadcast, service_data: %{0xFCD2 => <<1>>}},
            %{type: :broadcast, data: %{256 => <<1>>}}
          ] do
        assert {:error, {:invalid_spec, _}} = Advertiser.properties(spec)
      end
    end

    test "rejects unknown or ill-typed fields" do
      assert {:error, {:invalid_spec, _}} = Advertiser.properties(%{type: :broadcast, bogus: 1})

      assert {:error, {:invalid_spec, _}} =
               Advertiser.properties(%{type: :broadcast, service_uuids: [1]})

      assert {:error, {:invalid_spec, _}} =
               Advertiser.properties(%{type: :broadcast, tx_power: 99})
    end
  end

  describe "against a scripted bus" do
    setup do
      {:ok, svr} = start_supervised({TestServer, tap: self()})
      {:ok, addr} = TestServer.get_listen_addr(svr)
      connect_fun = fn -> Bluez.Rebus.connect(addr) end

      # init/1 blocks on the bus Hello until this test answers it.
      starter =
        Task.async(fn ->
          GenServer.start(Advertiser, connect_fun: connect_fun, adapter_path: @adapter)
        end)

      assert_receive {^svr, %Message{header_fields: %{member: "Hello"}} = hello}, 1_000
      reply(svr, hello, "s", [":1.100"])
      {:ok, adv} = Task.await(starter)
      on_exit(fn -> Process.exit(adv, :kill) end)

      %{svr: svr, adv: adv}
    end

    test "registers, serves GetAll while registering, and unregisters after duration_ms",
         %{svr: svr, adv: adv} do
      uuids = AdData.uuid16_strings(<<1, 2, 1, 2>>)
      spec = %{type: :broadcast, service_uuids: uuids}
      # Owned by the test process: with the default (the Task) owner-exit
      # cleanup would unregister it and mask a broken duration_ms.
      owner = self()

      task =
        Task.async(fn ->
          Advertiser.advertise(spec, server: adv, duration_ms: 50, owner: owner)
        end)

      assert_receive {^svr,
                      %Message{
                        header_fields: %{member: "RegisterAdvertisement", path: @adapter},
                        body: [path, []]
                      } = register},
                     1_000

      # bluetoothd reads the properties back before answering.
      get_all =
        method_call(svr, path, "org.freedesktop.DBus.Properties", "GetAll", "s", [
          "org.bluez.LEAdvertisement1"
        ])

      assert_receive {^svr, %Message{type: :method_return, body: [props]} = rp}, 1_000
      assert rp.header_fields.reply_serial == get_all
      assert {"ServiceUUIDs", {"as", ^uuids}} = List.keyfind(props, "ServiceUUIDs", 0)

      reply(svr, register)
      assert Task.await(task) == {:ok, 1}

      assert_receive {^svr,
                      %Message{
                        header_fields: %{member: "UnregisterAdvertisement"},
                        body: [^path]
                      }},
                     1_000
    end

    test "stop/2 returns only once BlueZ has answered the unregister", %{svr: svr, adv: adv} do
      owner = self()

      task =
        Task.async(fn -> Advertiser.advertise(%{type: :broadcast}, server: adv, owner: owner) end)

      assert_receive {^svr, %Message{header_fields: %{member: "RegisterAdvertisement"}} = reg},
                     1_000

      reply(svr, reg)
      assert {:ok, id} = Task.await(task)

      stopper = Task.async(fn -> Advertiser.stop(id, adv) end)

      assert_receive {^svr,
                      %Message{header_fields: %{member: "UnregisterAdvertisement"}} = unreg},
                     1_000

      refute Task.yield(stopper, 100)
      reply(svr, unreg)
      assert Task.await(stopper) == :ok
    end

    test "a refused unregister keeps the advertisement tracked and stop/2 retryable",
         %{svr: svr, adv: adv} do
      {id, path} = registered(svr, adv)

      first = Task.async(fn -> Advertiser.stop(id, adv) end)
      unreg = assert_unregister(svr, path)
      # A concurrent stop waits on the same unregistration.
      second = Task.async(fn -> Advertiser.stop(id, adv) end)
      wait_until(fn -> match?(%{^id => %{waiters: [_, _]}}, :sys.get_state(adv).ads) end)
      error(svr, unreg, "org.bluez.Error.Failed")

      assert Task.await(first) == {:error, "org.bluez.Error.Failed"}
      assert Task.await(second) == {:error, "org.bluez.Error.Failed"}
      assert %{^id => %{status: :active}} = :sys.get_state(adv).ads

      retry = Task.async(fn -> Advertiser.stop(id, adv) end)
      reply(svr, assert_unregister(svr, path))
      assert Task.await(retry) == :ok
      assert :sys.get_state(adv).ads == %{}
    end

    test "DoesNotExist from BlueZ counts as unregistered", %{svr: svr, adv: adv} do
      {id, path} = registered(svr, adv)
      stopper = Task.async(fn -> Advertiser.stop(id, adv) end)
      error(svr, assert_unregister(svr, path), "org.bluez.Error.DoesNotExist")
      assert Task.await(stopper) == :ok
    end

    test "refuses while Bluez.Mgmt holds an instance bluetoothd would hand out next",
         %{svr: svr, adv: adv} do
      # Mgmt on hci0 (the adapter these tests advertise on) holds instance 1:
      # bluetoothd, unaware of it, would allocate 1 for our first advert.
      mgmt = mgmt_holding(1)

      assert Advertiser.advertise(%{type: :broadcast}, server: adv, mgmt: mgmt) ==
               {:error, :instance_conflict}

      refute_receive {^svr, %Message{header_fields: %{member: "RegisterAdvertisement"}}}, 50
    end

    test "registers alongside a Bluez.Mgmt instance bluetoothd can't reach",
         %{svr: svr, adv: adv} do
      mgmt = mgmt_holding(5)
      owner = self()

      task =
        Task.async(fn ->
          Advertiser.advertise(%{type: :broadcast}, server: adv, mgmt: mgmt, owner: owner)
        end)

      assert_receive {^svr, %Message{header_fields: %{member: "RegisterAdvertisement"}} = reg},
                     1_000

      reply(svr, reg)
      assert {:ok, _id} = Task.await(task)
    end

    test "Release mid-registration still unregisters if BlueZ then accepts it",
         %{svr: svr, adv: adv} do
      owner = self()

      task =
        Task.async(fn -> Advertiser.advertise(%{type: :broadcast}, server: adv, owner: owner) end)

      assert_receive {^svr,
                      %Message{
                        header_fields: %{member: "RegisterAdvertisement"},
                        body: [path, []]
                      } = reg},
                     1_000

      method_call(svr, path, "org.bluez.LEAdvertisement1", "Release", nil, [])
      assert_receive {^svr, %Message{type: :method_return}}, 1_000

      reply(svr, reg)
      assert Task.await(task) == {:error, :stopped}
      reply(svr, assert_unregister(svr, path))
      assert wait_until(fn -> :sys.get_state(adv).ads == %{} end) == :ok
    end

    test "a BlueZ error is returned and the object is dropped", %{svr: svr, adv: adv} do
      task = Task.async(fn -> Advertiser.advertise(%{type: :broadcast}, server: adv) end)

      assert_receive {^svr, %Message{header_fields: %{member: "RegisterAdvertisement"}} = reg},
                     1_000

      TestServer.push(
        svr,
        Message.new!(:error,
          reply_serial: reg.serial,
          error_name: "org.bluez.Error.NotPermitted",
          flags: []
        )
      )

      assert Task.await(task) == {:error, "org.bluez.Error.NotPermitted"}
      assert :sys.get_state(adv).ads == %{}
    end

    test "the owner's exit unregisters", %{svr: svr, adv: adv} do
      owner = spawn(fn -> Process.sleep(:infinity) end)

      task =
        Task.async(fn -> Advertiser.advertise(%{type: :broadcast}, server: adv, owner: owner) end)

      assert_receive {^svr, %Message{header_fields: %{member: "RegisterAdvertisement"}} = reg},
                     1_000

      reply(svr, reg)
      assert {:ok, id} = Task.await(task)

      Process.exit(owner, :kill)
      path = "/org/exbluez/advertiser/adv#{id}"

      assert_receive {^svr,
                      %Message{
                        header_fields: %{member: "UnregisterAdvertisement"},
                        body: [^path]
                      }},
                     1_000
    end
  end

  test "rejects bad options in the caller, before reaching the server" do
    assert {:error, {:invalid_spec, _}} = Advertiser.advertise(%{type: :scanner})
    assert {:error, {:invalid_spec, _}} = Advertiser.advertise(%{})

    spec = %{type: :broadcast}
    assert Advertiser.advertise(spec, owner: :worker) == {:error, {:invalid, "owner"}}
    assert Advertiser.advertise(spec, duration_ms: 0) == {:error, {:invalid, "duration_ms"}}

    assert {:error, {:invalid_spec, _}} =
             Advertiser.properties(%{type: :broadcast, min_interval_ms: 4_294_967_316})
  end

  test "public API degrades when not running" do
    assert Advertiser.advertise(%{type: :broadcast}, server: :no_such_adv) ==
             {:error, :not_running}

    assert Advertiser.stop(1, :no_such_adv) == :ok
  end

  # A Bluez.Mgmt (against a scripted kernel) holding `instance` on hci0.
  defp mgmt_holding(instance) do
    test_pid = self()

    open = fn ->
      {proc, kernel} = Bluez.TestSocketPair.open()
      :ok = :socket.setopt(kernel, :otp, :controlling_process, test_pid)
      send(test_pid, {:kernel, kernel})
      {:ok, proc}
    end

    mgmt = start_supervised!({Bluez.Mgmt, name: nil, adapter_index: 0, open: open})
    assert_receive {:kernel, kernel}, 1_000

    task =
      Task.async(fn ->
        Bluez.Mgmt.advertise(<<2, 1, 6>>, server: mgmt, instance: instance, owner: test_pid)
      end)

    for {opcode, rp} <- [{0x0054, <<instance, 0, 31, 31>>}, {0x0055, <<instance>>}] do
      {:ok, <<^opcode::little-16, _::binary>>} = :socket.recv(kernel, 0, 1_000)
      reply = <<opcode::little-16, 0, rp::binary>>

      :ok =
        :socket.send(
          kernel,
          <<1::little-16, 0::little-16, byte_size(reply)::little-16, reply::binary>>
        )
    end

    assert Task.await(task) == {:ok, instance}
    assert Bluez.Mgmt.held_instances(mgmt) == [{0, instance}]
    mgmt
  end

  defp wait_until(fun, tries \\ 50) do
    cond do
      fun.() ->
        :ok

      tries == 0 ->
        flunk("condition never held")

      true ->
        Process.sleep(10)
        wait_until(fun, tries - 1)
    end
  end

  # Register an advertisement owned by the test process; {id, path}.
  defp registered(svr, adv) do
    owner = self()

    task =
      Task.async(fn -> Advertiser.advertise(%{type: :broadcast}, server: adv, owner: owner) end)

    assert_receive {^svr, %Message{header_fields: %{member: "RegisterAdvertisement"}} = reg},
                   1_000

    reply(svr, reg)
    assert {:ok, id} = Task.await(task)
    {id, "/org/exbluez/advertiser/adv#{id}"}
  end

  defp assert_unregister(svr, path) do
    assert_receive {^svr,
                    %Message{header_fields: %{member: "UnregisterAdvertisement"}, body: [^path]} =
                      msg},
                   1_000

    msg
  end

  defp error(svr, %Message{serial: serial}, name) do
    TestServer.push(
      svr,
      Message.new!(:error, reply_serial: serial, error_name: name, flags: [])
    )
  end

  defp reply(svr, %Message{serial: serial}, signature \\ nil, body \\ []) do
    opts = [reply_serial: serial, flags: [], body: body]
    opts = if signature, do: Keyword.put(opts, :signature, signature), else: opts
    TestServer.push(svr, Message.new!(:method_return, opts))
  end

  # Push a method call from "bluetoothd"; returns the serial TestServer
  # assigned so the reply can be matched.
  defp method_call(svr, path, iface, member, signature, body) do
    serial = :sys.get_state(svr).serial

    opts = [sender: ":1.1", path: path, interface: iface, member: member, body: body]
    opts = if signature, do: Keyword.put(opts, :signature, signature), else: opts
    TestServer.push(svr, Message.new!(:method_call, opts))

    serial
  end
end
