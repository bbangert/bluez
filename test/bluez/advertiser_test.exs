defmodule Bluez.AdvertiserTest do
  use ExUnit.Case, async: true

  alias Bluez.{AdData, Advertiser, Radio, TestLeaseHolder}
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
      radio = start_supervised!({Radio, name: nil})

      # init/1 blocks on the bus Hello until this test answers it.
      starter =
        Task.async(fn ->
          GenServer.start(Advertiser, connect_fun: connect_fun, radio: radio, retry_ms: 20)
        end)

      assert_receive {^svr, %Message{header_fields: %{member: "Hello"}} = hello}, 1_000
      reply(svr, hello, "s", [":1.100"])
      {:ok, adv} = Task.await(starter)
      on_exit(fn -> Process.exit(adv, :kill) end)

      # Sends go through a process holding hci0's (@adapter's) lease.
      {holder, lease} = TestLeaseHolder.start(radio)

      %{svr: svr, adv: adv, radio: radio, holder: holder, lease: lease}
    end

    test "registers, serves GetAll while registering, and unregisters after duration_ms",
         %{svr: svr} = ctx do
      uuids = AdData.uuid16_strings(<<1, 2, 1, 2>>)
      spec = %{type: :broadcast, service_uuids: uuids}
      ref = advertise_async(ctx, spec, duration_ms: 50)

      assert_receive {^svr,
                      %Message{
                        header_fields: %{member: "RegisterAdvertisement", path: @adapter},
                        body: [path, []]
                      } = register},
                     1_000

      # bluetoothd reads the properties back before answering. GetAll is
      # the only call in flight, so its reply is the only property list.
      method_call(svr, path, "org.freedesktop.DBus.Properties", "GetAll", "s", [
        "org.bluez.LEAdvertisement1"
      ])

      assert_receive {^svr, %Message{type: :method_return, body: [props]}}, 1_000
      assert {"ServiceUUIDs", {"as", ^uuids}} = List.keyfind(props, "ServiceUUIDs", 0)

      reply(svr, register)
      assert TestLeaseHolder.await(ref) == {:ok, 1}

      assert_receive {^svr,
                      %Message{
                        header_fields: %{member: "UnregisterAdvertisement"},
                        body: [^path]
                      }},
                     1_000
    end

    test "stop/3 returns only once BlueZ has answered the unregister", %{svr: svr} = ctx do
      {id, path} = registered(ctx)

      ref = stop_async(ctx, id)
      unreg = assert_unregister(svr, path)
      refute_receive {^ref, _}, 100
      reply(svr, unreg)
      assert TestLeaseHolder.await(ref) == :ok
    end

    test "a stop during an expiry's unregistration waits for it", %{svr: svr, adv: adv} = ctx do
      {id, path} = registered(ctx, duration_ms: 20)
      unreg = assert_unregister(svr, path)

      ref = stop_async(ctx, id)
      wait_until(fn -> match?(%{^id => %{waiters: [_]}}, :sys.get_state(adv).ads) end)
      reply(svr, unreg)
      assert TestLeaseHolder.await(ref) == :ok
    end

    test "a refused unregister keeps the advertisement tracked and stop/3 retryable",
         %{svr: svr, adv: adv} = ctx do
      {id, path} = registered(ctx)

      ref = stop_async(ctx, id)
      error(svr, assert_unregister(svr, path), "org.bluez.Error.Failed")
      assert TestLeaseHolder.await(ref) == {:error, "org.bluez.Error.Failed"}
      assert %{^id => %{status: :active}} = :sys.get_state(adv).ads

      ref = stop_async(ctx, id)
      reply(svr, assert_unregister(svr, path))
      assert TestLeaseHolder.await(ref) == :ok
      assert :sys.get_state(adv).ads == %{}
    end

    test "DoesNotExist from BlueZ counts as unregistered", %{svr: svr} = ctx do
      {id, path} = registered(ctx)
      ref = stop_async(ctx, id)
      error(svr, assert_unregister(svr, path), "org.bluez.Error.DoesNotExist")
      assert TestLeaseHolder.await(ref) == :ok
    end

    test "refuses while Bluez.Mgmt holds an instance bluetoothd would hand out next",
         %{svr: svr} = ctx do
      # Mgmt on hci0 (the adapter these tests advertise on) holds instance 1:
      # bluetoothd, unaware of it, would allocate 1 for our first advert.
      mgmt = mgmt_holding(ctx, 1)

      assert ctx |> advertise_async(%{type: :broadcast}, mgmt: mgmt) |> TestLeaseHolder.await() ==
               {:error, :instance_conflict}

      refute_receive {^svr, %Message{header_fields: %{member: "RegisterAdvertisement"}}}, 50
    end

    test "registers alongside a Bluez.Mgmt instance bluetoothd can't reach", %{svr: svr} = ctx do
      mgmt = mgmt_holding(ctx, 5)
      ref = advertise_async(ctx, %{type: :broadcast}, mgmt: mgmt)

      assert_receive {^svr, %Message{header_fields: %{member: "RegisterAdvertisement"}} = reg},
                     1_000

      reply(svr, reg)
      assert {:ok, _id} = TestLeaseHolder.await(ref)
    end

    test "Release mid-registration still unregisters if BlueZ then accepts it",
         %{svr: svr, adv: adv} = ctx do
      ref = advertise_async(ctx, %{type: :broadcast})

      assert_receive {^svr,
                      %Message{
                        header_fields: %{member: "RegisterAdvertisement"},
                        body: [path, []]
                      } = reg},
                     1_000

      method_call(svr, path, "org.bluez.LEAdvertisement1", "Release", nil, [])
      assert_receive {^svr, %Message{type: :method_return}}, 1_000

      reply(svr, reg)
      assert TestLeaseHolder.await(ref) == {:error, :stopped}
      reply(svr, assert_unregister(svr, path))
      assert wait_until(fn -> :sys.get_state(adv).ads == %{} end) == :ok
    end

    test "a BlueZ error is returned and the object is dropped", %{svr: svr, adv: adv} = ctx do
      ref = advertise_async(ctx, %{type: :broadcast})

      assert_receive {^svr, %Message{header_fields: %{member: "RegisterAdvertisement"}} = reg},
                     1_000

      error(svr, reg, "org.bluez.Error.NotPermitted")
      assert TestLeaseHolder.await(ref) == {:error, "org.bluez.Error.NotPermitted"}
      assert :sys.get_state(adv).ads == %{}
    end

    test "the holder's exit unregisters everything sent under its lease",
         %{svr: svr, holder: holder} = ctx do
      {_id, path} = registered(ctx)

      TestLeaseHolder.stop(holder)
      assert_unregister(svr, path)
    end

    test "releasing the lease unregisters", %{svr: svr, holder: holder} = ctx do
      {_id, path} = registered(ctx)

      assert TestLeaseHolder.call(holder, &Radio.release/1) == :ok
      assert_unregister(svr, path)
    end

    test "an advertisement registered after its lease ended is reported expired and unregistered",
         %{svr: svr, lease: lease} = ctx do
      ref = advertise_async(ctx, %{type: :broadcast})

      assert_receive {^svr,
                      %Message{
                        header_fields: %{member: "RegisterAdvertisement"},
                        body: [path, []]
                      } = reg},
                     1_000

      # The lease is revoked mid-registration.
      :ok = Radio.release(lease)
      reply(svr, reg)
      assert TestLeaseHolder.await(ref) == {:error, :lease_expired}
      assert_unregister(svr, path)
    end

    test "the controller isn't handed on while the old lease's registration is pending",
         %{svr: svr, radio: radio, lease: lease} = ctx do
      _ref = advertise_async(ctx, %{type: :broadcast})

      assert_receive {^svr,
                      %Message{
                        header_fields: %{member: "RegisterAdvertisement"},
                        body: [path, []]
                      } = reg},
                     1_000

      # The lease ends mid-registration. Were the controller handed on
      # now, a successor's Bluez.Mgmt instance 1 could be overwritten by
      # this registration (bluetoothd doesn't see it) and then removed by
      # its cancellation.
      :ok = Radio.release(lease)
      assert Radio.acquire(server: radio, adapter_index: 0, wait: 0) == {:error, :draining}

      reply(svr, reg)
      unreg = assert_unregister(svr, path)
      assert Radio.acquire(server: radio, adapter_index: 0, wait: 0) == {:error, :draining}

      reply(svr, unreg)
      assert {:ok, _lease} = Radio.acquire(server: radio, adapter_index: 0, wait: 1_000)
    end

    test "an unregister refused after its lease ended is retried",
         %{svr: svr, adv: adv, lease: lease} = ctx do
      {_id, path} = registered(ctx)

      :ok = Radio.release(lease)
      error(svr, assert_unregister(svr, path), "org.bluez.Error.Failed")

      # No holder is left to retry it: the server does.
      reply(svr, assert_unregister(svr, path))
      assert wait_until(fn -> :sys.get_state(adv).ads == %{} end) == :ok
    end

    test "the Radio stopping ends every lease", %{svr: svr} = ctx do
      {_id, path} = registered(ctx)

      :ok = stop_supervised(Radio)
      assert_unregister(svr, path)
    end

    test "a lease from another Radio is refused", %{svr: svr, adv: adv} do
      other = start_supervised!({Radio, name: nil}, id: :other_radio)
      {holder, _lease} = TestLeaseHolder.start(other, 1)

      assert TestLeaseHolder.call(
               holder,
               &Advertiser.advertise(&1, %{type: :broadcast}, server: adv)
             ) ==
               {:error, :lease_expired}

      refute_receive {^svr, %Message{header_fields: %{member: "RegisterAdvertisement"}}}, 50
    end

    test "a lease can't stop another lease's advertisement",
         %{adv: adv, radio: radio} = ctx do
      {id, _path} = registered(ctx)
      {other, _lease} = TestLeaseHolder.start(radio, 1)

      assert TestLeaseHolder.call(other, &Advertiser.stop(&1, id, adv)) ==
               {:error, :unknown_advertisement}

      assert %{^id => %{status: :active}} = :sys.get_state(adv).ads
    end

    test "only the lease holder may send, and only while the lease lasts",
         %{svr: svr, adv: adv, holder: holder, lease: lease} do
      assert Advertiser.advertise(lease, %{type: :broadcast}, server: adv) ==
               {:error, :not_lease_holder}

      assert Advertiser.stop(lease, 1, adv) == {:error, :not_lease_holder}

      assert TestLeaseHolder.call(holder, fn lease ->
               :ok = Radio.release(lease)
               Advertiser.advertise(lease, %{type: :broadcast}, server: adv)
             end) == {:error, :lease_expired}

      refute_receive {^svr, %Message{header_fields: %{member: "RegisterAdvertisement"}}}, 50
    end
  end

  test "rejects bad options in the caller, before reaching the server" do
    {:ok, lease} = Radio.acquire(server: start_supervised!({Radio, name: nil}), adapter_index: 0)

    assert {:error, {:invalid_spec, _}} = Advertiser.advertise(lease, %{type: :scanner})
    assert {:error, {:invalid_spec, _}} = Advertiser.advertise(lease, %{})
    assert {:error, {:invalid_spec, _}} = Advertiser.advertise(lease, %{type: "broadcast"})
    assert {:error, {:invalid_spec, _}} = Advertiser.advertise(lease, :broadcast)

    assert Advertiser.advertise(lease, %{type: :broadcast}, duration_ms: 0) ==
             {:error, {:invalid, "duration_ms"}}

    assert {:error, {:invalid_spec, _}} =
             Advertiser.properties(%{type: :broadcast, min_interval_ms: 4_294_967_316})
  end

  test "public API degrades when not running" do
    {:ok, lease} = Radio.acquire(server: start_supervised!({Radio, name: nil}), adapter_index: 0)

    assert Advertiser.advertise(lease, %{type: :broadcast}, server: :no_such_adv) ==
             {:error, :not_running}

    assert Advertiser.stop(lease, 1, :no_such_adv) == :ok
  end

  defp advertise_async(%{adv: adv, holder: holder}, spec, opts \\ []),
    do: TestLeaseHolder.run(holder, &Advertiser.advertise(&1, spec, [server: adv] ++ opts))

  defp stop_async(%{adv: adv, holder: holder}, id),
    do: TestLeaseHolder.run(holder, &Advertiser.stop(&1, id, adv))

  # A Bluez.Mgmt (against a scripted kernel) holding `instance` on hci0,
  # sent by the same lease holder.
  defp mgmt_holding(%{radio: radio, holder: holder}, instance) do
    test_pid = self()

    open = fn ->
      {proc, kernel} = Bluez.TestSocketPair.open()
      :ok = :socket.setopt(kernel, :otp, :controlling_process, test_pid)
      send(test_pid, {:kernel, kernel})
      {:ok, proc}
    end

    mgmt = start_supervised!({Bluez.Mgmt, name: nil, radio: radio, open: open})
    assert_receive {:kernel, kernel}, 1_000

    ref =
      TestLeaseHolder.run(
        holder,
        &Bluez.Mgmt.advertise(&1, <<2, 1, 6>>, server: mgmt, instance: instance)
      )

    # Read Advertising Features (hardware offload, nothing else registered),
    # then the parameters and data commands.
    features = <<Bitwise.bsl(1, 11)::little-32, 31, 31, 5, 0>>

    for {opcode, rp} <- [
          {0x003D, features},
          {0x0054, <<instance, 0, 31, 31>>},
          {0x0055, <<instance>>}
        ] do
      {:ok, <<^opcode::little-16, _::binary>>} = :socket.recv(kernel, 0, 1_000)
      reply = <<opcode::little-16, 0, rp::binary>>

      :ok =
        :socket.send(
          kernel,
          <<1::little-16, 0::little-16, byte_size(reply)::little-16, reply::binary>>
        )
    end

    assert TestLeaseHolder.await(ref) == {:ok, instance}
    assert Bluez.Mgmt.held_instances(mgmt) == [{0, instance}]
    mgmt
  end

  defp wait_until(fun, tries \\ 200) do
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

  # Register an advertisement through the lease holder; {id, path}.
  defp registered(%{svr: svr} = ctx, opts \\ []) do
    ref = advertise_async(ctx, %{type: :broadcast}, opts)

    assert_receive {^svr, %Message{header_fields: %{member: "RegisterAdvertisement"}} = reg},
                   1_000

    reply(svr, reg)
    assert {:ok, id} = TestLeaseHolder.await(ref)
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

  # Push a method call from "bluetoothd".
  defp method_call(svr, path, iface, member, signature, body) do
    opts = [sender: ":1.1", path: path, interface: iface, member: member, body: body]
    opts = if signature, do: Keyword.put(opts, :signature, signature), else: opts
    TestServer.push(svr, Message.new!(:method_call, opts))
  end
end
