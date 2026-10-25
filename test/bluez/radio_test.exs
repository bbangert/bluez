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
    :ok = Radio.subscribe(radio)
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
    :ok = Radio.subscribe(radio)
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
    assert Radio.subscribe(:no_such_radio) == :ok
    assert Radio.holder(0, :no_such_radio) == nil
  end
end
