defmodule Bluez.RadioTest do
  use ExUnit.Case, async: true

  alias Bluez.Radio
  alias Bluez.Radio.Lease

  setup do
    %{radio: start_supervised!({Radio, name: nil})}
  end

  test "one lease per controller; the holder re-acquiring gets the same lease", %{radio: radio} do
    assert {:ok, %Lease{index: 0, holder: holder} = lease} =
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

  test "the holder exiting ends its lease, freeing the controller", %{radio: radio} do
    {:ok, ^radio} = Radio.subscribe(radio)
    test_pid = self()

    holder =
      spawn(fn ->
        {:ok, lease} = Radio.acquire(server: radio, adapter_index: 0)
        send(test_pid, {:lease, lease})
        Process.sleep(:infinity)
      end)

    assert_receive {:lease, %Lease{ref: ref} = lease}
    Process.exit(holder, :kill)

    assert_receive {:radio_lease_ended, ^ref}, 1_000
    refute Radio.valid?(lease)
    assert {:ok, %Lease{holder: ^test_pid}} = Radio.acquire(server: radio, adapter_index: 0)
  end

  test "a stale lease can't end its successor", %{radio: radio} do
    {:ok, ^radio} = Radio.subscribe(radio)
    {holder, %Lease{ref: old_ref} = old} = Bluez.TestLeaseHolder.start(radio)
    assert Bluez.TestLeaseHolder.call(holder, &Radio.release/1) == :ok
    assert_receive {:radio_lease_ended, ^old_ref}

    # The controller is re-acquired; the old lease is now stale.
    {:ok, %Lease{ref: new_ref} = new} = Radio.acquire(server: radio, adapter_index: 0)
    assert Radio.release(old) == :ok
    refute Radio.valid?(old)
    assert Radio.valid?(new)

    # Nor does the old holder's exit, after it released.
    Bluez.TestLeaseHolder.stop(holder)
    assert Radio.valid?(new)
    refute_received {:radio_lease_ended, ^new_ref}
  end

  test "every subscriber is notified, once each; dead ones are dropped", %{radio: radio} do
    test_pid = self()

    _forwarder =
      spawn_link(fn ->
        {:ok, ^radio} = Radio.subscribe(radio)
        send(test_pid, :subscribed)
        receive do: (msg -> send(test_pid, {:forwarded, msg}))
      end)

    assert_receive :subscribed
    {:ok, ^radio} = Radio.subscribe(radio)
    # Subscribing twice doesn't double the notifications.
    {:ok, ^radio} = Radio.subscribe(radio)
    gone = spawn(fn -> {:ok, ^radio} = Radio.subscribe(radio) end)
    ref = Process.monitor(gone)
    assert_receive {:DOWN, ^ref, :process, ^gone, _}

    {:ok, %Lease{ref: lease_ref} = lease} = Radio.acquire(server: radio, adapter_index: 0)
    :ok = Radio.release(lease)

    assert_receive {:radio_lease_ended, ^lease_ref}
    refute_received {:radio_lease_ended, _}
    assert_receive {:forwarded, {:radio_lease_ended, ^lease_ref}}
    # The Radio's own DOWN for it may still be on its way: poll.
    assert eventually(fn -> not Map.has_key?(:sys.get_state(radio).subscribers, gone) end)
  end

  test "check_holder/1 accepts only a lease held by the caller", %{radio: radio} do
    {:ok, lease} = Radio.acquire(server: radio, adapter_index: 0)
    assert Radio.check_holder(lease) == :ok

    assert Task.await(Task.async(fn -> Radio.check_holder(lease) end)) ==
             {:error, :not_lease_holder}

    assert Radio.check_holder(:not_a_lease) == {:error, :not_lease_holder}
  end

  test "rejects a bad adapter_index and degrades when not running" do
    assert Radio.acquire(server: :no_such_radio, adapter_index: -1) ==
             {:error, {:invalid, "adapter_index"}}

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
