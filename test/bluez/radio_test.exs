defmodule Bluez.RadioTest do
  use ExUnit.Case, async: true

  alias Bluez.{Radio, TestLeaseHolder}
  alias Bluez.Radio.Lease

  setup do
    %{radio: start_supervised!({Radio, name: nil})}
  end

  test "one owner per controller; the owner re-acquiring gets the same lease", %{radio: radio} do
    assert {:ok, %Lease{index: 0, mode: :mgmt, holder: holder} = lease} =
             Radio.acquire(server: radio, adapter_index: 0)

    assert holder == self()
    assert Radio.acquire(server: radio, adapter_index: 0) == {:ok, lease}
    assert Radio.valid?(lease)
    assert Radio.holder(0, radio) == self()

    # Another process is refused while it is held; another controller is free.
    test_pid = self()

    other =
      Task.async(fn ->
        {Radio.acquire(server: radio, adapter_index: 0),
         Radio.acquire(server: radio, adapter_index: 1)}
      end)

    assert {{:error, {:held_by, ^test_pid}}, {:ok, %Lease{index: 1}}} = Task.await(other)
  end

  test "the first acquire fixes the controller's mode", %{radio: radio} do
    {:ok, lease} = Radio.acquire(server: radio, adapter_index: 0, mode: :mgmt)
    :ok = Radio.release(lease)

    # Only :mgmt exists so far: other modes are refused before reaching the
    # server...
    assert Radio.acquire(server: radio, adapter_index: 0, mode: :dbus) ==
             {:error, {:invalid, "mode"}}

    # ...and the server keeps a controller in the mode it was first
    # acquired in, even after that lease ended (a future mode can't switch).
    assert GenServer.call(radio, {:acquire, 0, :dbus, self()}) == {:error, {:mode, :mgmt}}
    assert {:ok, %Lease{mode: :dbus}} = GenServer.call(radio, {:acquire, 1, :dbus, self()})
    assert Radio.acquire(server: radio, adapter_index: 1) == {:error, {:mode, :dbus}}
  end

  test "release ends the lease and notifies subscribers", %{radio: radio} do
    {:ok, ^radio} = Radio.subscribe(radio)
    {:ok, %Lease{ref: ref} = lease} = Radio.acquire(server: radio, adapter_index: 0)

    assert Radio.release(lease) == :ok
    assert_receive {:radio_lease_ended, ^ref}
    refute Radio.valid?(lease)
    assert Radio.holder(0, radio) == nil

    # Releasing again (or a stale lease) is a no-op.
    assert Radio.release(lease) == :ok
    refute_receive {:radio_lease_ended, _}, 50
  end

  test "the owner exiting ends its lease, freeing the controller", %{radio: radio} do
    {:ok, ^radio} = Radio.subscribe(radio)
    {holder, %Lease{ref: ref} = lease} = TestLeaseHolder.start(radio)

    TestLeaseHolder.stop(holder)
    assert_receive {:radio_lease_ended, ^ref}, 1_000
    refute Radio.valid?(lease)

    test_pid = self()
    assert {:ok, %Lease{holder: ^test_pid}} = Radio.acquire(server: radio, adapter_index: 0)
  end

  test "a stale lease can't end its successor", %{radio: radio} do
    {:ok, ^radio} = Radio.subscribe(radio)
    {holder, old} = TestLeaseHolder.start(radio)
    assert TestLeaseHolder.call(holder, &Radio.release/1) == :ok

    {:ok, %Lease{ref: new_ref} = new} = Radio.acquire(server: radio, adapter_index: 0)
    assert Radio.release(old) == :ok
    refute Radio.valid?(old)
    assert Radio.valid?(new)

    # Nor does the old owner's exit, after it released.
    TestLeaseHolder.stop(holder)
    assert Radio.valid?(new)
    refute_received {:radio_lease_ended, ^new_ref}
  end

  test "a dead subscriber is dropped", %{radio: radio} do
    gone = spawn(fn -> {:ok, ^radio} = Radio.subscribe(radio) end)
    ref = Process.monitor(gone)
    assert_receive {:DOWN, ^ref, :process, ^gone, _}

    # The Radio's own DOWN for it may still be on its way: poll.
    assert eventually(fn -> not Map.has_key?(:sys.get_state(radio).subscribers, gone) end)
  end

  test "check_holder/2 accepts only the caller's own lease, of the given mode", %{radio: radio} do
    {:ok, lease} = Radio.acquire(server: radio, adapter_index: 0)
    assert Radio.check_holder(lease, :mgmt) == :ok
    assert Radio.check_holder(lease, :dbus) == {:error, {:mode, :mgmt}}

    assert Task.await(Task.async(fn -> Radio.check_holder(lease, :mgmt) end)) ==
             {:error, :not_lease_holder}

    assert Radio.check_holder(:not_a_lease, :mgmt) == {:error, :not_lease_holder}
  end

  test "rejects a bad adapter_index and degrades when not running" do
    # MGMT indices are 16 bits, 0xFFFF reserved: beyond would alias another
    # controller.
    for bad <- [-1, 0xFFFF, 0x10000, 1.0] do
      assert Radio.acquire(server: :no_such_radio, adapter_index: bad) ==
               {:error, {:invalid, "adapter_index"}}
    end

    assert Radio.acquire(server: :no_such_radio, adapter_index: 0) == {:error, :not_running}
    assert Radio.subscribe(:no_such_radio) == {:error, :not_running}
    assert Radio.holder(0, :no_such_radio) == nil
  end

  defp eventually(fun, tries \\ 100) do
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
