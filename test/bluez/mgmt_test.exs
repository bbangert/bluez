defmodule Bluez.MgmtTest do
  use ExUnit.Case, async: true

  alias Bluez.{AdData, Mgmt, TestSocketPair}

  @read_features 0x003D
  @remove 0x003F
  @params 0x0054
  @data 0x0055

  # The test plays the kernel on the other end of the MGMT socket.
  defp start_mgmt(opts \\ []) do
    test_pid = self()

    open = fn ->
      {proc, kernel} = TestSocketPair.open()
      # The test owns the kernel side, so it outlives the server.
      :ok = :socket.setopt(kernel, :otp, :controlling_process, test_pid)
      send(test_pid, {:kernel, kernel})
      {:ok, proc}
    end

    mgmt = start_supervised!({Mgmt, [name: nil, adapter_index: 0, open: open] ++ opts})
    assert_receive {:kernel, kernel}
    {mgmt, kernel}
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

  defp features(max_instances),
    do: <<0::little-32, 31, 31, max_instances, 1, 1>>

  # The owner defaults to the caller — here the short-lived Task — so pin
  # it to the test process unless a test is about ownership.
  defp advertise_async(mgmt, data, opts) do
    opts = [server: mgmt, owner: self()] |> Keyword.merge(opts)
    Task.async(fn -> Mgmt.advertise(data, opts) end)
  end

  test "advertise/2 sends ext params + data on the highest instance, then removes after duration" do
    {mgmt, kernel} = start_mgmt()

    data =
      Mgmt.legacy_adv_data([AdData.local_name("ABCDEFGH"), AdData.uuid128_list([<<1::128>>])])

    task = advertise_async(mgmt, data, duration_ms: 50)

    # No instance given: ask the controller how many it has.
    assert expect_command(kernel, @read_features) == <<>>
    complete(kernel, @read_features, 0, features(5))

    assert <<5, flags::little-32, _::binary>> = expect_command(kernel, @params)
    # Intervals default to 20-30 ms (PARAM_INTERVALS set), non-connectable.
    assert Bitwise.band(flags, 0x4001) == 0x4000
    complete(kernel, @params, 0, <<5, 0, 31, 31>>)

    assert expect_command(kernel, @data) == <<5, byte_size(data), 0, data::binary>>
    complete(kernel, @data, 0, <<5>>)

    assert Task.await(task) == {:ok, 5}

    # duration_ms elapses → Remove Advertising for exactly our instance.
    assert expect_command(kernel, @remove) == <<5>>
    complete(kernel, @remove, 0, <<5>>)
    assert {:error, :timeout} = :socket.recv(kernel, 0, 100)
  end

  test "a refused data step reports the status and removes the half-made instance" do
    {mgmt, kernel} = start_mgmt()
    task = advertise_async(mgmt, <<2, 1, 6>>, instance: 3)

    expect_command(kernel, @params)
    complete(kernel, @params, 0, <<3, 0, 31, 31>>)
    expect_command(kernel, @data)
    complete(kernel, @data, 0x0D)

    assert Task.await(task) == {:error, :invalid_params}
    assert expect_command(kernel, @remove) == <<3>>
  end

  test "a refused params step reports the status and sends nothing more" do
    {mgmt, kernel} = start_mgmt()
    task = advertise_async(mgmt, <<2, 1, 6>>, instance: 3)

    expect_command(kernel, @params)
    complete(kernel, @params, 0x0B)

    assert Task.await(task) == {:error, :rejected}
    assert {:error, :timeout} = :socket.recv(kernel, 0, 100)
  end

  test "the owner's exit removes its instance" do
    {mgmt, kernel} = start_mgmt()
    owner = spawn(fn -> Process.sleep(:infinity) end)
    task = advertise_async(mgmt, <<2, 1, 6>>, instance: 2, owner: owner)

    expect_command(kernel, @params)
    complete(kernel, @params, 0, <<2, 0, 31, 31>>)
    expect_command(kernel, @data)
    complete(kernel, @data, 0, <<2>>)
    assert Task.await(task) == {:ok, 2}

    Process.exit(owner, :kill)
    assert expect_command(kernel, @remove) == <<2>>
  end

  test "stop_advertising/2 removes a tracked instance and refuses unknown ones" do
    {mgmt, kernel} = start_mgmt()
    task = advertise_async(mgmt, <<2, 1, 6>>, instance: 4)

    expect_command(kernel, @params)
    complete(kernel, @params, 0, <<4, 0, 31, 31>>)
    expect_command(kernel, @data)
    complete(kernel, @data, 0, <<4>>)
    assert Task.await(task) == {:ok, 4}

    stopper = Task.async(fn -> Mgmt.stop_advertising(4, mgmt) end)
    assert expect_command(kernel, @remove) == <<4>>
    complete(kernel, @remove, 0, <<4>>)
    assert Task.await(stopper) == :ok

    assert Mgmt.stop_advertising(4, mgmt) == {:error, :unknown_instance}
  end

  test "commands queue behind the one in flight" do
    {mgmt, kernel} = start_mgmt()
    first = Task.async(fn -> Mgmt.read_advertising_features(mgmt) end)
    expect_command(kernel, @read_features)
    second = Task.async(fn -> Mgmt.read_advertising_features(mgmt) end)

    # Nothing else goes out until the first reply.
    assert {:error, :timeout} = :socket.recv(kernel, 0, 50)
    complete(kernel, @read_features, 0, features(5))
    assert {:ok, %{max_instances: 5, instances: [1]}} = Task.await(first)

    expect_command(kernel, @read_features)
    complete(kernel, @read_features, 0, features(4))
    assert {:ok, %{max_instances: 4}} = Task.await(second)
  end

  test "an instance removed by someone else is no longer tracked" do
    {mgmt, kernel} = start_mgmt()
    task = advertise_async(mgmt, <<2, 1, 6>>, instance: 6)
    expect_command(kernel, @params)
    complete(kernel, @params, 0, <<6, 0, 31, 31>>)
    expect_command(kernel, @data)
    complete(kernel, @data, 0, <<6>>)
    assert Task.await(task) == {:ok, 6}

    # MGMT Advertising Removed event (bluetoothd restart cleared it).
    :ok = :socket.send(kernel, <<0x24, 0, 0, 0, 1, 0, 6>>)
    assert eventually(fn -> :sys.get_state(mgmt).instances == %{} end)
  end

  # Accept an advertisement on `instance` end to end.
  defp advertise_ok(mgmt, kernel, instance, opts \\ []) do
    task = advertise_async(mgmt, <<2, 1, 6>>, [instance: instance] ++ opts)
    expect_command(kernel, @params)
    complete(kernel, @params, 0, <<instance, 0, 31, 31>>)
    expect_command(kernel, @data)
    complete(kernel, @data, 0, <<instance>>)
    assert Task.await(task) == {:ok, instance}
  end

  test "an expiry racing a replacement on the same instance doesn't remove the replacement" do
    {mgmt, kernel} = start_mgmt()
    advertise_ok(mgmt, kernel, 5, duration_ms: 30)

    # Re-advertise instance 5 and hold the kernel's reply until the old
    # advertisement's duration has elapsed (its removal queues behind).
    task = advertise_async(mgmt, <<2, 1, 6>>, instance: 5)
    expect_command(kernel, @params)
    Process.sleep(60)
    complete(kernel, @params, 0, <<5, 0, 31, 31>>)
    expect_command(kernel, @data)
    complete(kernel, @data, 0, <<5>>)
    assert Task.await(task) == {:ok, 5}

    # The stale removal is skipped: nothing else goes to the kernel, and the
    # replacement is still tracked.
    assert {:error, :timeout} = :socket.recv(kernel, 0, 100)
    assert %{5 => %{removing: false}} = :sys.get_state(mgmt).instances
  end

  test "a failed data step's rollback runs before queued work for the same instance" do
    {mgmt, kernel} = start_mgmt()
    first = advertise_async(mgmt, <<2, 1, 6>>, instance: 3)
    expect_command(kernel, @params)
    complete(kernel, @params, 0, <<3, 0, 31, 31>>)
    expect_command(kernel, @data)

    second = advertise_async(mgmt, <<2, 1, 6>>, instance: 3)
    # Let the second request reach the queue before the first fails.
    _ = :sys.get_state(mgmt)
    complete(kernel, @data, 0x0D)
    assert Task.await(first) == {:error, :invalid_params}

    assert expect_command(kernel, @remove) == <<3>>
    complete(kernel, @remove, 0, <<3>>)
    expect_command(kernel, @params)
    complete(kernel, @params, 0, <<3, 0, 31, 31>>)
    expect_command(kernel, @data)
    complete(kernel, @data, 0, <<3>>)
    assert Task.await(second) == {:ok, 3}
    assert {:error, :timeout} = :socket.recv(kernel, 0, 100)
  end

  test "a failed removal keeps the instance tracked so it can be retried" do
    {mgmt, kernel} = start_mgmt()
    advertise_ok(mgmt, kernel, 4)

    stopper = Task.async(fn -> Mgmt.stop_advertising(4, mgmt) end)
    expect_command(kernel, @remove)
    complete(kernel, @remove, 0x0A)
    assert Task.await(stopper) == {:error, :busy}

    stopper = Task.async(fn -> Mgmt.stop_advertising(4, mgmt) end)
    assert expect_command(kernel, @remove) == <<4>>
    complete(kernel, @remove, 0, <<4>>)
    assert Task.await(stopper) == :ok
    assert :sys.get_state(mgmt).instances == %{}
  end

  test "removing an instance the kernel no longer has counts as removed" do
    {mgmt, kernel} = start_mgmt()
    advertise_ok(mgmt, kernel, 4)

    stopper = Task.async(fn -> Mgmt.stop_advertising(4, mgmt) end)
    expect_command(kernel, @remove)
    complete(kernel, @remove, 0x0D)
    assert Task.await(stopper) == :ok
    assert :sys.get_state(mgmt).instances == %{}
  end

  test "an Advertising Removed event for another controller is ignored" do
    {mgmt, kernel} = start_mgmt()
    advertise_ok(mgmt, kernel, 6)

    # Instance 6 removed on hci1; ours is on hci0.
    :ok = :socket.send(kernel, <<0x24, 0, 1, 0, 1, 0, 6>>)
    _ = :sys.get_state(mgmt)
    assert %{6 => _} = :sys.get_state(mgmt).instances
  end

  test "shutdown also removes an instance whose data command is still in flight" do
    {mgmt, kernel} = start_mgmt()
    _task = advertise_async(mgmt, <<2, 1, 6>>, instance: 7)
    expect_command(kernel, @params)
    complete(kernel, @params, 0, <<7, 0, 31, 31>>)
    expect_command(kernel, @data)

    :ok = GenServer.stop(mgmt)
    assert expect_command(kernel, @remove) == <<7>>
  end

  test "rejects bad input in the caller, before reaching the server" do
    assert Mgmt.advertise(:binary.copy(<<0>>, 256)) == {:error, :too_long}
    assert Mgmt.advertise(<<>>, instance: 0) == {:error, {:invalid, "instance"}}
    assert Mgmt.advertise(<<>>, duration_ms: -1) == {:error, {:invalid, "duration_ms"}}
    assert {:error, {:invalid, _}} = Mgmt.advertise(<<>>, flags: [:bogus])
    assert {:error, {:invalid, _}} = Mgmt.advertise(<<>>, min_interval_ms: 5)
    assert {:error, {:invalid, _}} = Mgmt.advertise(<<>>, tx_power: :loud)
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

  test "public API degrades to :not_running" do
    assert Mgmt.read_advertising_features(:no_such_mgmt) == {:error, :not_running}
  end

  defp eventually(fun, tries \\ 20) do
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
