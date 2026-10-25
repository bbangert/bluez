defmodule Bluez.AdvertReceiverTest do
  use ExUnit.Case, async: true

  alias Bluez.{AdvertReceiver, TestSocketPair}

  @addr_le <<0xFF, 0xEE, 0xDD, 0xCC, 0xBB, 0xAA>>

  defp adv_packet(data, rssi \\ -50) do
    params = <<0x02, 1, 3, 1, @addr_le::binary, byte_size(data), data::binary, rssi::signed>>
    <<0x04, 0x3E, byte_size(params), params::binary>>
  end

  defp start_receiver(open) do
    test_pid = self()

    start_supervised!(
      {AdvertReceiver,
       name: nil,
       adapter_index: 0,
       retry_ms: 20,
       open: open,
       on_report: fn report -> send(test_pid, {:report, report}) end}
    )
  end

  test "fans out every decoded report, verbatim and in order" do
    test_pid = self()

    receiver =
      start_receiver(fn 0 ->
        # Opened in the receiver, which then owns its side (as with HCI).
        {proc, kernel} = TestSocketPair.open()
        send(test_pid, {:kernel, kernel})
        {:ok, proc}
      end)

    assert_receive {:kernel, kernel}, 1_000

    data = <<2, 1, 6, 7, 3, 1, 2, 1, 2, 3, 4>>
    :ok = :socket.send(kernel, adv_packet(data, -61))
    # Non-report traffic is ignored.
    :ok = :socket.send(kernel, <<0x04, 0x0E, 4, 1, 3, 0x0C, 0>>)
    :ok = :socket.send(kernel, adv_packet(<<2, 1, 6>>, -62))

    assert_receive {:report, %{address: 0xAABBCCDDEEFF, data: ^data, rssi: -61}}
    assert_receive {:report, %{data: <<2, 1, 6>>, rssi: -62}}
    refute_receive {:report, _}, 50
    assert AdvertReceiver.listening?(receiver)
  end

  test "stays up and retries while the socket can't be opened" do
    test_pid = self()
    # The open keeps failing until the test flips this (no timing race).
    available = :atomics.new(1, [])
    attempts = :counters.new(1, [])

    receiver =
      start_receiver(fn 0 ->
        :counters.add(attempts, 1, 1)

        if :atomics.get(available, 1) == 0 do
          {:error, :enodev}
        else
          {proc, kernel} = TestSocketPair.open()
          send(test_pid, {:kernel, kernel})
          {:ok, proc}
        end
      end)

    # Several failed attempts, yet still alive and simply not listening.
    assert wait_until(fn -> :counters.get(attempts, 1) >= 3 end)
    refute AdvertReceiver.listening?(receiver)

    :atomics.put(available, 1, 1)
    assert_receive {:kernel, kernel}, 1_000
    assert AdvertReceiver.listening?(receiver)

    :ok = :socket.send(kernel, adv_packet(<<2, 1, 6>>))
    assert_receive {:report, %{data: <<2, 1, 6>>}}
  end

  test "an aborted socket select reopens instead of going deaf" do
    test_pid = self()

    receiver =
      start_receiver(fn 0 ->
        {proc, kernel} = TestSocketPair.open()
        send(test_pid, {:opened, proc, kernel})
        {:ok, proc}
      end)

    assert_receive {:opened, sock, _kernel}, 1_000
    send(receiver, {:"$socket", sock, :abort, {make_ref(), :closed}})

    # Reopened (retry_ms 20) and receiving on the new socket.
    assert_receive {:opened, _sock, kernel}, 1_000
    :ok = :socket.send(kernel, adv_packet(<<2, 1, 6>>))
    assert_receive {:report, %{data: <<2, 1, 6>>}}, 1_000
  end

  test "listening?/1 is false when not running" do
    refute AdvertReceiver.listening?(:no_such_receiver)
  end

  defp wait_until(fun, tries \\ 100) do
    cond do
      fun.() ->
        true

      tries == 0 ->
        false

      true ->
        Process.sleep(10)
        wait_until(fun, tries - 1)
    end
  end
end
