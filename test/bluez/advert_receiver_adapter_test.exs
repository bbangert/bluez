defmodule Bluez.AdvertReceiverAdapterTest do
  # Not async: drives the global adapter-path :persistent_term.
  use ExUnit.Case, async: false

  alias Bluez.{AdvertReceiver, DevicePath, TestSocketPair}

  setup do
    previous = :persistent_term.get(DevicePath.adapter_path_key(), nil)

    on_exit(fn ->
      if previous,
        do: :persistent_term.put(DevicePath.adapter_path_key(), previous),
        else: :persistent_term.erase(DevicePath.adapter_path_key())
    end)
  end

  test "without adapter_index:, moves to the adapter Bluez.Client selects later" do
    :persistent_term.erase(DevicePath.adapter_path_key())
    test_pid = self()

    start_supervised!(
      {AdvertReceiver,
       name: nil,
       adapter_check_ms: 20,
       open: fn index ->
         {proc, _kernel} = TestSocketPair.open()
         send(test_pid, {:opened, index})
         {:ok, proc}
       end}
    )

    # Before the Client publishes its selection: the hci0 fallback.
    assert_receive {:opened, 0}

    :persistent_term.put(DevicePath.adapter_path_key(), "/org/bluez/hci1")
    assert_receive {:opened, 1}, 1_000
    refute_receive {:opened, _}, 100
  end

  test "an explicit adapter_index: is never re-resolved" do
    :persistent_term.put(DevicePath.adapter_path_key(), "/org/bluez/hci1")
    test_pid = self()

    start_supervised!(
      {AdvertReceiver,
       name: nil,
       adapter_index: 0,
       adapter_check_ms: 20,
       open: fn index ->
         {proc, _kernel} = TestSocketPair.open()
         send(test_pid, {:opened, index})
         {:ok, proc}
       end}
    )

    assert_receive {:opened, 0}
    refute_receive {:opened, _}, 100
  end
end
