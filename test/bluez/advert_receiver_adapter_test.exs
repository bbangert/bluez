defmodule Bluez.AdvertReceiverAdapterTest do
  # Not async: drives the global resolved-adapter :persistent_term.
  use ExUnit.Case, async: false

  alias Bluez.{AdvertReceiver, DevicePath, TestSocketPair}

  setup do
    previous = :persistent_term.get(DevicePath.resolved_adapter_key(), nil)
    :persistent_term.erase(DevicePath.resolved_adapter_key())

    on_exit(fn ->
      if previous,
        do: :persistent_term.put(DevicePath.resolved_adapter_key(), previous),
        else: :persistent_term.erase(DevicePath.resolved_adapter_key())
    end)
  end

  # Reports each open to the test; the test keeps the kernel side so it
  # can't close and provoke a reopen of its own.
  defp start_receiver(opts) do
    test_pid = self()

    open = fn index ->
      {proc, kernel} = TestSocketPair.open()
      send(test_pid, {:opened, index, kernel})
      {:ok, proc}
    end

    start_supervised!(
      {AdvertReceiver, [name: nil, retry_ms: 20, adapter_check_ms: 20, open: open] ++ opts}
    )
  end

  test "without adapter_index:, waits for Bluez.Client's adapter, then follows changes" do
    receiver = start_receiver([])

    # Not resolved yet: never listens on the hci0 fallback.
    refute_receive {:opened, _, _}, 250
    refute AdvertReceiver.listening?(receiver)

    :persistent_term.put(DevicePath.resolved_adapter_key(), "/org/bluez/hci1")
    assert_receive {:opened, 1, _kernel}, 1_000

    # A later selection change (e.g. a radio switch) moves the socket...
    :persistent_term.put(DevicePath.resolved_adapter_key(), "/org/bluez/hci2")
    assert_receive {:opened, 2, _kernel}, 1_000

    # ...while a Client restart in progress (unresolved) keeps it.
    :persistent_term.erase(DevicePath.resolved_adapter_key())
    refute_receive {:opened, _, _}, 250
    assert AdvertReceiver.listening?(receiver)
  end

  test "an adapter_index outside 0..0xFFFE is refused, never wrapped onto another controller" do
    for bad <- [0xFFFF, 0x10000, -1, "0"] do
      assert {:error, {:invalid_option, :adapter_index}} =
               GenServer.start(AdvertReceiver, adapter_index: bad)
    end

    # A resolved one out of range counts as unresolved.
    :persistent_term.put(DevicePath.resolved_adapter_key(), "/org/bluez/hci65536")
    start_receiver([])
    refute_receive {:opened, _, _}, 250
  end

  test "an explicit adapter_index: is never re-resolved" do
    :persistent_term.put(DevicePath.resolved_adapter_key(), "/org/bluez/hci1")
    start_receiver(adapter_index: 0)

    assert_receive {:opened, 0, _kernel}, 1_000
    refute_receive {:opened, _, _}, 250
  end
end
