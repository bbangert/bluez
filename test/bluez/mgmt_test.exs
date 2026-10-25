defmodule Bluez.MgmtTest do
  use ExUnit.Case, async: true

  alias Bluez.{AdData, Mgmt, Radio, TestLeaseHolder, TestSocketPair}

  @read_features 0x003D
  @remove 0x003F
  @params 0x0054
  @data 0x0055

  # The test plays the kernel on the other end of the MGMT socket, and
  # sends through a process holding hci0's transmit lease.
  setup ctx do
    test_pid = self()

    open = fn ->
      {proc, kernel} = TestSocketPair.open()
      # The test owns the kernel side, so it outlives the server.
      :ok = :socket.setopt(kernel, :otp, :controlling_process, test_pid)
      send(test_pid, {:kernel, kernel})
      {:ok, proc}
    end

    radio = start_supervised!({Radio, name: nil})
    opts = [name: nil, radio: radio, open: open] ++ Map.get(ctx, :mgmt_opts, [])
    mgmt = start_supervised!({Mgmt, opts})
    assert_receive {:kernel, kernel}, 1_000
    {holder, lease} = TestLeaseHolder.start(radio)

    %{mgmt: mgmt, kernel: kernel, radio: radio, holder: holder, lease: lease}
  end

  # Datagrams on the kernel socket are processed in order, so once a later
  # command round-trip has completed every earlier packet has been handled.
  defp sync(mgmt, kernel) do
    task = Task.async(fn -> Mgmt.read_advertising_features(0, mgmt) end)
    expect_command(kernel, @read_features)
    complete(kernel, @read_features, 0, features(5))
    assert {:ok, _} = Task.await(task)
  end

  defp expect_command(kernel, opcode) do
    {:ok, <<^opcode::little-16, 0::little-16, len::little-16, params::binary-size(len)>>} =
      :socket.recv(kernel, 0, 1_000)

    params
  end

  defp complete(kernel, opcode, status, params \\ <<>>) do
    rp = <<opcode::little-16, status, params::binary>>

    :ok =
      :socket.send(kernel, <<1::little-16, 0::little-16, byte_size(rp)::little-16, rp::binary>>)
  end

  # MGMT_ADV_FLAG_HW_OFFLOAD: concurrent hardware sets, no software
  # rotation (so finite durations are never refused as :rotation_busy).
  @hw_offload Bitwise.bsl(1, 11)

  defp features(max_instances, in_use \\ [1], flags \\ @hw_offload),
    do: <<flags::little-32, 31, 31, max_instances, length(in_use)>> <> :binary.list_to_bin(in_use)

  # Every advertise starts with Read Advertising Features.
  defp answer_features(kernel, max \\ 5, in_use \\ [1], flags \\ @hw_offload) do
    assert expect_command(kernel, @read_features) == <<>>
    complete(kernel, @read_features, 0, features(max, in_use, flags))
  end

  # Sends go through the lease holder; returns a ref for await/1.
  defp advertise_async(%{mgmt: mgmt, holder: holder}, data, opts),
    do: TestLeaseHolder.run(holder, &Mgmt.advertise(&1, data, [server: mgmt] ++ opts))

  defp stop_async(%{mgmt: mgmt, holder: holder}, instance),
    do: TestLeaseHolder.run(holder, &Mgmt.stop_advertising(&1, instance, mgmt))

  defp await(ref), do: TestLeaseHolder.await(ref)

  test "advertise/3 sends ext params + data on the highest instance, then removes after duration",
       %{kernel: kernel} = ctx do
    data =
      Mgmt.legacy_adv_data([AdData.local_name("ABCDEFGH"), AdData.uuid128_list([<<1::128>>])])

    ref = advertise_async(ctx, data, duration_ms: 50)

    # No instance given: ask the controller how many it has.
    assert expect_command(kernel, @read_features) == <<>>
    complete(kernel, @read_features, 0, features(5))

    assert <<5, flags::little-32, _::binary>> = expect_command(kernel, @params)
    # Intervals default to 20-30 ms (PARAM_INTERVALS set), non-connectable.
    assert Bitwise.band(flags, 0x4001) == 0x4000
    complete(kernel, @params, 0, <<5, 0, 31, 31>>)

    assert expect_command(kernel, @data) == <<5, byte_size(data), 0, data::binary>>
    complete(kernel, @data, 0, <<5>>)

    assert await(ref) == {:ok, 5}

    # duration_ms elapses → Remove Advertising for exactly our instance.
    assert expect_command(kernel, @remove) == <<5>>
    complete(kernel, @remove, 0, <<5>>)
    assert {:error, :timeout} = :socket.recv(kernel, 0, 100)
  end

  test "a refused data step reports the status and removes the half-made instance",
       %{kernel: kernel} = ctx do
    ref = advertise_async(ctx, <<2, 1, 6>>, instance: 3)

    answer_features(kernel)

    expect_command(kernel, @params)
    complete(kernel, @params, 0, <<3, 0, 31, 31>>)
    expect_command(kernel, @data)
    complete(kernel, @data, 0x0D)

    assert await(ref) == {:error, :invalid_params}
    assert expect_command(kernel, @remove) == <<3>>
  end

  test "a half-made instance whose rollback fails stays tracked and removable",
       %{mgmt: mgmt, kernel: kernel} = ctx do
    ref = advertise_async(ctx, <<2, 1, 6>>, instance: 3)
    answer_features(kernel)
    expect_command(kernel, @params)
    complete(kernel, @params, 0, <<3, 0, 31, 31>>)
    expect_command(kernel, @data)
    complete(kernel, @data, 0x0D)
    assert await(ref) == {:error, :invalid_params}

    assert expect_command(kernel, @remove) == <<3>>
    complete(kernel, @remove, 0x0A)

    assert eventually(fn ->
             match?(%{{0, 3} => %{removing: false}}, :sys.get_state(mgmt).instances)
           end)

    ref = stop_async(ctx, 3)
    assert expect_command(kernel, @remove) == <<3>>
    complete(kernel, @remove, 0, <<3>>)
    assert await(ref) == :ok
    assert :sys.get_state(mgmt).instances == %{}
  end

  test "a refused params step reports the status and sends nothing more",
       %{kernel: kernel} = ctx do
    ref = advertise_async(ctx, <<2, 1, 6>>, instance: 3)

    answer_features(kernel)

    expect_command(kernel, @params)
    complete(kernel, @params, 0x0B)

    assert await(ref) == {:error, :rejected}
    assert {:error, :timeout} = :socket.recv(kernel, 0, 100)
  end

  test "the holder's exit ends its lease and removes its instances",
       %{kernel: kernel, holder: holder} = ctx do
    advertise_ok(ctx, 2)
    advertise_ok(ctx, 4)

    TestLeaseHolder.stop(holder)
    first = expect_command(kernel, @remove)
    complete(kernel, @remove, 0, first)
    second = expect_command(kernel, @remove)
    assert Enum.sort([first, second]) == [<<2>>, <<4>>]
  end

  test "releasing the lease removes its instances", %{kernel: kernel, holder: holder} = ctx do
    advertise_ok(ctx, 2)

    assert TestLeaseHolder.call(holder, &Radio.release/1) == :ok
    assert expect_command(kernel, @remove) == <<2>>
  end

  test "an instance landing after its lease ended is reported expired and taken back off air",
       %{kernel: kernel, lease: lease} = ctx do
    ref = advertise_async(ctx, <<2, 1, 6>>, instance: 2)
    answer_features(kernel)
    expect_command(kernel, @params)

    # The lease is revoked with the send in flight; the lease end finds
    # nothing tracked yet.
    :ok = Radio.release(lease)
    complete(kernel, @params, 0, <<2, 0, 31, 31>>)
    expect_command(kernel, @data)
    complete(kernel, @data, 0, <<2>>)

    assert await(ref) == {:error, :lease_expired}
    assert expect_command(kernel, @remove) == <<2>>
  end

  test "the Radio stopping ends every lease", %{kernel: kernel} = ctx do
    advertise_ok(ctx, 2)

    :ok = stop_supervised(Radio)
    assert expect_command(kernel, @remove) == <<2>>
  end

  test "the same instance number on two controllers is tracked separately",
       %{mgmt: mgmt, kernel: kernel, radio: radio} = ctx do
    advertise_ok(ctx, 5)

    # Instance 5 on hci1, under hci1's lease.
    {other, _lease} = TestLeaseHolder.start(radio, 1)
    ref = TestLeaseHolder.run(other, &Mgmt.advertise(&1, <<2, 1, 6>>, server: mgmt, instance: 5))
    assert {:ok, <<0x3D, 0, 1, 0, _::binary>>} = :socket.recv(kernel, 0, 1_000)
    complete(kernel, @read_features, 0, features(5))
    assert {:ok, <<0x54, 0, 1, 0, _::binary>>} = :socket.recv(kernel, 0, 1_000)
    complete(kernel, @params, 0, <<5, 0, 31, 31>>)
    assert {:ok, <<0x55, 0, 1, 0, _::binary>>} = :socket.recv(kernel, 0, 1_000)
    complete(kernel, @data, 0, <<5>>)
    assert await(ref) == {:ok, 5}

    assert :sys.get_state(mgmt).instances |> Map.keys() |> Enum.sort() == [{0, 5}, {1, 5}]

    # Ending hci1's lease removes only hci1's instance 5.
    TestLeaseHolder.stop(other)

    assert {:ok, <<0x3F, 0, 1, 0, 1, 0, 5>>} = :socket.recv(kernel, 0, 1_000)
    complete(kernel, @remove, 0, <<5>>)
    assert eventually(fn -> Map.keys(:sys.get_state(mgmt).instances) == [{0, 5}] end)
  end

  test "a lease from another Radio is refused", %{mgmt: mgmt, kernel: kernel} do
    other = start_supervised!({Radio, name: nil}, id: :other_radio)
    {holder, _lease} = TestLeaseHolder.start(other, 1)

    assert TestLeaseHolder.call(holder, &Mgmt.advertise(&1, <<2, 1, 6>>, server: mgmt)) ==
             {:error, :lease_expired}

    assert {:error, :timeout} = :socket.recv(kernel, 0, 50)
  end

  test "a lease of another mode is refused in the caller", %{mgmt: mgmt, radio: radio} do
    # Only :mgmt exists so far; acquire a future-mode lease on the server.
    {:ok, lease} = GenServer.call(radio, {:acquire, 2, :dbus, self()})
    assert Mgmt.advertise(lease, <<2, 1, 6>>, server: mgmt) == {:error, {:mode, :dbus}}
    assert Mgmt.stop_advertising(lease, 1, mgmt) == {:error, {:mode, :dbus}}
  end

  test "a lease can't stop another lease's instance", %{mgmt: mgmt, radio: radio} = ctx do
    advertise_ok(ctx, 4)
    {other, _lease} = TestLeaseHolder.start(radio, 1)

    assert TestLeaseHolder.call(other, &Mgmt.stop_advertising(&1, 4, mgmt)) ==
             {:error, :unknown_instance}

    assert %{{0, 4} => %{removing: false}} = :sys.get_state(mgmt).instances
  end

  test "only the lease holder may send, and only while the lease lasts",
       %{mgmt: mgmt, kernel: kernel, holder: holder, lease: lease} do
    # The lease struct alone is not enough: the caller must be its holder.
    assert Mgmt.advertise(lease, <<2, 1, 6>>, server: mgmt) == {:error, :not_lease_holder}
    assert Mgmt.stop_advertising(lease, 1, mgmt) == {:error, :not_lease_holder}

    # A released lease is refused by the server.
    assert TestLeaseHolder.call(holder, fn lease ->
             :ok = Radio.release(lease)
             Mgmt.advertise(lease, <<2, 1, 6>>, server: mgmt)
           end) == {:error, :lease_expired}

    assert {:error, :timeout} = :socket.recv(kernel, 0, 50)
  end

  test "stop_advertising/3 removes a tracked instance and refuses unknown ones",
       %{mgmt: mgmt, kernel: kernel, holder: holder} = ctx do
    advertise_ok(ctx, 4)

    ref = stop_async(ctx, 4)
    assert expect_command(kernel, @remove) == <<4>>
    complete(kernel, @remove, 0, <<4>>)
    assert await(ref) == :ok

    assert TestLeaseHolder.call(holder, &Mgmt.stop_advertising(&1, 4, mgmt)) ==
             {:error, :unknown_instance}
  end

  test "commands queue behind the one in flight", %{mgmt: mgmt, kernel: kernel} do
    first = Task.async(fn -> Mgmt.read_advertising_features(0, mgmt) end)
    expect_command(kernel, @read_features)
    second = Task.async(fn -> Mgmt.read_advertising_features(0, mgmt) end)

    # Nothing else goes out until the first reply.
    assert {:error, :timeout} = :socket.recv(kernel, 0, 50)
    complete(kernel, @read_features, 0, features(5))
    assert {:ok, %{max_instances: 5, instances: [1]}} = Task.await(first)

    expect_command(kernel, @read_features)
    complete(kernel, @read_features, 0, features(4))
    assert {:ok, %{max_instances: 4}} = Task.await(second)
  end

  test "an instance removed by someone else is no longer tracked",
       %{mgmt: mgmt, kernel: kernel} = ctx do
    advertise_ok(ctx, 6)

    # MGMT Advertising Removed event (bluetoothd restart cleared it).
    :ok = :socket.send(kernel, <<0x24, 0, 0, 0, 1, 0, 6>>)
    assert eventually(fn -> :sys.get_state(mgmt).instances == %{} end)
  end

  # Accept an advertisement on `instance` end to end.
  defp advertise_ok(%{kernel: kernel} = ctx, instance, opts \\ []) do
    ref = advertise_async(ctx, <<2, 1, 6>>, [instance: instance] ++ opts)
    answer_features(kernel)
    expect_command(kernel, @params)
    complete(kernel, @params, 0, <<instance, 0, 31, 31>>)
    expect_command(kernel, @data)
    complete(kernel, @data, 0, <<instance>>)
    assert await(ref) == {:ok, instance}
  end

  test "an expiry racing a replacement on the same instance doesn't remove the replacement",
       %{mgmt: mgmt, kernel: kernel} = ctx do
    # A duration that can't elapse on its own during the test: the expiry
    # is fired by hand below, exactly while the replacement is in flight.
    advertise_ok(ctx, 5, duration_ms: 60_000)
    %{{0, 5} => %{timer: timer}} = :sys.get_state(mgmt).instances

    # Re-advertise instance 5, hold the kernel's reply, and let the old
    # advertisement's expiry fire meanwhile (its removal queues behind).
    ref = advertise_async(ctx, <<2, 1, 6>>, instance: 5)
    answer_features(kernel)
    expect_command(kernel, @params)
    send(mgmt, {:expire, {0, 5}, timer})
    assert %{{0, 5} => %{removing: true}} = :sys.get_state(mgmt).instances
    assert :queue.len(:sys.get_state(mgmt).queue) == 1
    complete(kernel, @params, 0, <<5, 0, 31, 31>>)
    expect_command(kernel, @data)
    complete(kernel, @data, 0, <<5>>)
    assert await(ref) == {:ok, 5}

    # The stale removal is skipped: nothing else goes to the kernel, and the
    # replacement is still tracked.
    assert {:error, :timeout} = :socket.recv(kernel, 0, 100)
    assert %{{0, 5} => %{removing: false}} = :sys.get_state(mgmt).instances
  end

  test "stop_advertising/3 during a pending expiry removal waits for it instead of refusing",
       %{mgmt: mgmt, kernel: kernel} = ctx do
    advertise_ok(ctx, 4, duration_ms: 60_000)
    %{{0, 4} => %{timer: timer}} = :sys.get_state(mgmt).instances

    # The expiry's removal is in flight when the holder stops it too.
    send(mgmt, {:expire, {0, 4}, timer})
    assert expect_command(kernel, @remove) == <<4>>
    ref = stop_async(ctx, 4)
    assert eventually(fn -> :queue.len(:sys.get_state(mgmt).queue) == 1 end)

    # The expiry's removal succeeds; the stop's is then stale and skipped.
    complete(kernel, @remove, 0, <<4>>)
    assert await(ref) == :ok
    assert {:error, :timeout} = :socket.recv(kernel, 0, 100)
    assert :sys.get_state(mgmt).instances == %{}
  end

  test "a failed removal keeps the instance tracked so it can be retried",
       %{mgmt: mgmt, kernel: kernel} = ctx do
    advertise_ok(ctx, 4)

    ref = stop_async(ctx, 4)
    expect_command(kernel, @remove)
    complete(kernel, @remove, 0x0A)
    assert await(ref) == {:error, :busy}

    ref = stop_async(ctx, 4)
    assert expect_command(kernel, @remove) == <<4>>
    complete(kernel, @remove, 0, <<4>>)
    assert await(ref) == :ok
    assert :sys.get_state(mgmt).instances == %{}
  end

  test "removing an instance the kernel no longer has counts as removed",
       %{mgmt: mgmt, kernel: kernel} = ctx do
    advertise_ok(ctx, 4)

    ref = stop_async(ctx, 4)
    expect_command(kernel, @remove)
    complete(kernel, @remove, 0x0D)
    assert await(ref) == :ok
    assert :sys.get_state(mgmt).instances == %{}
  end

  test "an unplugged controller's instances are forgotten, so a reused index starts clean",
       %{mgmt: mgmt, kernel: kernel} = ctx do
    advertise_ok(ctx, 5)

    # MGMT Index Removed for hci0 (a USB dongle unplugged).
    :ok = :socket.send(kernel, <<0x05, 0, 0, 0, 0, 0>>)
    assert eventually(fn -> :sys.get_state(mgmt).instances == %{} end)

    # Replugged as hci0, where someone else now holds instance 5: the
    # default pick no longer treats 5 as ours.
    ref = advertise_async(ctx, <<2, 1, 6>>, [])
    expect_command(kernel, @read_features)
    complete(kernel, @read_features, 0, <<0::little-32, 31, 31, 5, 1, 5>>)
    assert <<4, _::binary>> = expect_command(kernel, @params)
    complete(kernel, @params, 0, <<4, 0, 31, 31>>)
    expect_command(kernel, @data)
    complete(kernel, @data, 0, <<4>>)
    assert await(ref) == {:ok, 4}
  end

  test "an Advertising Removed event for another controller is ignored",
       %{mgmt: mgmt, kernel: kernel} = ctx do
    advertise_ok(ctx, 6)

    # Instance 6 removed on hci1; ours is on hci0. The sync round-trip
    # proves the event was processed (not merely still in flight).
    :ok = :socket.send(kernel, <<0x24, 0, 1, 0, 1, 0, 6>>)
    sync(mgmt, kernel)
    assert %{{0, 6} => _} = :sys.get_state(mgmt).instances

    # ...whereas the same event for hci0 does drop it.
    :ok = :socket.send(kernel, <<0x24, 0, 0, 0, 1, 0, 6>>)
    sync(mgmt, kernel)
    assert :sys.get_state(mgmt).instances == %{}
  end

  test "shutdown also removes an instance whose data command is still in flight",
       %{mgmt: mgmt, kernel: kernel} = ctx do
    # Shutdown cuts the holder's call off; the holder sees :not_running.
    ref = advertise_async(ctx, <<2, 1, 6>>, instance: 7)

    answer_features(kernel)

    expect_command(kernel, @params)
    complete(kernel, @params, 0, <<7, 0, 31, 31>>)
    expect_command(kernel, @data)

    # Through the supervisor (as in production), which also keeps it from
    # restarting the child under the test.
    :ok = stop_supervised(Mgmt)
    refute Process.alive?(mgmt)
    assert expect_command(kernel, @remove) == <<7>>
    assert await(ref) == {:error, :not_running}
  end

  @tag mgmt_opts: [command_timeout: 250]
  test "a command the kernel never answers restarts the server; the caller gets an error",
       %{mgmt: mgmt, kernel: kernel} = ctx do
    mon = Process.monitor(mgmt)
    ref = advertise_async(ctx, <<2, 1, 6>>, instance: 2)
    answer_features(kernel)
    expect_command(kernel, @params)

    assert_receive {:DOWN, ^mon, :process, ^mgmt, :mgmt_command_timeout}, 1_000
    assert await(ref) == {:error, :not_running}
  end

  test "an aborted socket select stops the server instead of leaving it deaf", %{mgmt: mgmt} do
    ref = Process.monitor(mgmt)
    sock = :sys.get_state(mgmt).sock

    send(mgmt, {:"$socket", sock, :abort, {make_ref(), :closed}})
    assert_receive {:DOWN, ^ref, :process, ^mgmt, {:mgmt_socket_abort, :closed}}, 1_000
  end

  test "the default instance skips one held by someone else", %{kernel: kernel} = ctx do
    ref = advertise_async(ctx, <<2, 1, 6>>, [])

    expect_command(kernel, @read_features)
    # Max 5; instance 5 is occupied (e.g. bluetoothd on a small controller).
    complete(kernel, @read_features, 0, <<0::little-32, 31, 31, 5, 1, 5>>)

    assert <<4, _::binary>> = expect_command(kernel, @params)
    complete(kernel, @params, 0, <<4, 0, 31, 31>>)
    expect_command(kernel, @data)
    complete(kernel, @data, 0, <<4>>)
    assert await(ref) == {:ok, 4}
  end

  test "the default instance reuses our own, even though the kernel lists it",
       %{kernel: kernel} = ctx do
    advertise_ok(ctx, 5)

    ref = advertise_async(ctx, <<2, 1, 6>>, [])
    expect_command(kernel, @read_features)
    complete(kernel, @read_features, 0, <<0::little-32, 31, 31, 5, 1, 5>>)
    assert <<5, _::binary>> = expect_command(kernel, @params)
    complete(kernel, @params, 0, <<5, 0, 31, 31>>)
    expect_command(kernel, @data)
    complete(kernel, @data, 0, <<5>>)
    assert await(ref) == {:ok, 5}
  end

  test "no free instance is an error, not a takeover", %{kernel: kernel} = ctx do
    ref = advertise_async(ctx, <<2, 1, 6>>, [])
    expect_command(kernel, @read_features)
    complete(kernel, @read_features, 0, <<0::little-32, 31, 31, 1, 1, 1>>)
    assert await(ref) == {:error, :no_free_instance}
    assert {:error, :timeout} = :socket.recv(kernel, 0, 100)
  end

  test "a finite advertisement is refused while a software-rotating controller has another instance",
       %{kernel: kernel} = ctx do
    ref = advertise_async(ctx, <<2, 1, 6>>, instance: 5, duration_ms: 300)

    # No hardware offload, and instance 1 (bluetoothd's) is registered: the
    # kernel would rotate ours in ~2 s slots, so 300 ms may never air.
    answer_features(kernel, 5, [1], 0)
    assert await(ref) == {:error, :rotation_busy}
    assert {:error, :timeout} = :socket.recv(kernel, 0, 100)
  end

  test "software rotation doesn't block an unbounded advert, or one alone on the controller",
       %{kernel: kernel} = ctx do
    # No duration: it will get its rotation slot eventually.
    ref = advertise_async(ctx, <<2, 1, 6>>, instance: 5)
    answer_features(kernel, 5, [1], 0)
    expect_command(kernel, @params)
    complete(kernel, @params, 0, <<5, 0, 31, 31>>)
    expect_command(kernel, @data)
    complete(kernel, @data, 0, <<5>>)
    assert await(ref) == {:ok, 5}

    # Replacing our own instance with nothing else registered: no rotation.
    ref = advertise_async(ctx, <<2, 1, 6>>, instance: 5, duration_ms: 300)
    answer_features(kernel, 5, [5], 0)
    expect_command(kernel, @params)
    complete(kernel, @params, 0, <<5, 0, 31, 31>>)
    expect_command(kernel, @data)
    complete(kernel, @data, 0, <<5>>)
    assert await(ref) == {:ok, 5}
  end

  test "rejects bad input in the caller, before reaching the server", %{holder: holder} do
    results =
      TestLeaseHolder.call(holder, fn lease ->
        [
          Mgmt.advertise(lease, :binary.copy(<<0>>, 256)),
          Mgmt.advertise(lease, <<>>, instance: 0),
          Mgmt.advertise(lease, <<>>, duration_ms: -1),
          Mgmt.advertise(lease, <<>>, flags: [:bogus]),
          Mgmt.advertise(lease, <<>>, min_interval_ms: 5),
          Mgmt.advertise(lease, <<>>, tx_power: :loud)
        ]
      end)

    assert [
             {:error, :too_long},
             {:error, {:invalid, "instance"}},
             {:error, {:invalid, "duration_ms"}},
             {:error, {:invalid, _}},
             {:error, {:invalid, _}},
             {:error, {:invalid, _}}
           ] = results
  end

  test "legacy_adv_data/2 builds the exact Flags + Local Name + UUID128 PDU (Tuya P1 shape)" do
    block = <<0::8, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15>>

    # Flags (3) + Local Name (10) + one UUID128 (18): exactly the 31-byte
    # legacy advertising PDU.
    assert Mgmt.legacy_adv_data([AdData.local_name("ABCDEFGH"), AdData.uuid128_list([block])]) ==
             <<2, 1, 6>> <> <<9, 9, "ABCDEFGH">> <> <<17, 7, block::binary>>
  end

  test "legacy_adv_data/2 prepends Flags and enforces 31 bytes" do
    assert Mgmt.legacy_adv_data([AdData.local_name("x")]) == <<2, 1, 6, 2, 9, ?x>>

    assert_raise ArgumentError, fn ->
      Mgmt.legacy_adv_data([AdData.local_name(String.duplicate("x", 27))])
    end
  end

  test "is :ignore'd (not crash-looping) when the MGMT socket can't be opened" do
    assert Mgmt.start_link(name: nil, open: fn -> {:error, :eafnosupport} end) == :ignore
  end

  test "public API degrades to :not_running", %{holder: holder} do
    assert Mgmt.read_advertising_features(0, :no_such_mgmt) == {:error, :not_running}

    assert TestLeaseHolder.call(holder, &Mgmt.advertise(&1, <<>>, server: :no_such_mgmt)) ==
             {:error, :not_running}
  end

  defp eventually(fun, tries \\ 200) do
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
end
