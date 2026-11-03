defmodule Bluez.HciUserTest do
  use ExUnit.Case, async: true

  @moduletag :capture_log

  alias Bluez.{HciUser, TestSocketPair}
  alias Bluez.HciUser.Codec

  @reset 0x0C03
  @read_bd_addr 0x1009
  @read_local_version 0x1001
  @le_scan_params 0x200B
  @le_scan_enable 0x200C
  @le_create_conn 0x200D

  @set_powered 0x0005
  @read_index_list 0x0003
  @read_controller_info 0x0004

  # Address B8:FB:B3:1B:3B:44 as it travels over HCI (little-endian).
  @bd_addr 0xB8FBB31B3B44
  @addr_le <<0x44, 0x3B, 0x1B, 0xB3, 0xFB, 0xB8>>

  # The test plays the controller on the other end of the user channel.
  defp user_channel_open(type \\ :dgram) do
    test_pid = self()

    fn index ->
      {proc, kernel} = TestSocketPair.open(type)
      # The test owns the controller side, so it outlives the server.
      :ok = :socket.setopt(kernel, :otp, :controlling_process, test_pid)
      send(test_pid, {:bound, index, proc, kernel})
      {:ok, proc}
    end
  end

  defp start_server(opts \\ []) do
    {type, opts} = Keyword.pop(opts, :socket_type, :dgram)

    opts =
      Keyword.merge(
        [index: 0, power_off_first: false, owner: self(), open: user_channel_open(type)],
        opts
      )

    server = start_supervised!({HciUser, opts})
    assert_receive {:bound, _index, proc, kernel}, 1_000
    %{server: server, proc: proc, kernel: kernel}
  end

  defp expect_command(kernel, opcode) do
    assert {:ok, <<0x01, ^opcode::little-16, len, params::binary-size(len)>>} =
             :socket.recv(kernel, 0, 1_000)

    params
  end

  defp refute_command(kernel, wait \\ 150),
    do: assert({:error, :timeout} = :socket.recv(kernel, 0, wait))

  defp event(kernel, code, params),
    do: :ok = :socket.send(kernel, <<0x04, code, byte_size(params), params::binary>>)

  # Command Complete: return parameters with the Status byte first.
  defp complete(kernel, opcode, rp, ncmd \\ 1),
    do: event(kernel, 0x0E, <<ncmd, opcode::little-16, rp::binary>>)

  defp command_status(kernel, opcode, status, ncmd \\ 1),
    do: event(kernel, 0x0F, <<status, ncmd, opcode::little-16>>)

  defp async(fun), do: Task.async(fun)

  defp forward(pid) do
    receive do
      msg -> send(pid, msg)
    end

    forward(pid)
  end

  defp wait_until(fun, tries \\ 200) do
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

  # Whether the server has sent the task's command (it is in flight), or
  # the task finished first. While a send blocks, the server can't answer.
  defp sent_or_done(server, task) do
    case Task.yield(task, 10) do
      {:ok, result} ->
        {:done, result}

      nil ->
        in_flight =
          try do
            :sys.get_state(server, 100).in_flight
          catch
            :exit, _reason -> nil
          end

        if in_flight, do: :sent, else: sent_or_done(server, task)
    end
  end

  describe "commands" do
    test "a Command Complete answers its command, Status byte stripped" do
      %{server: server, kernel: kernel} = start_server()

      task = async(fn -> HciUser.command(server, @read_bd_addr) end)
      assert expect_command(kernel, @read_bd_addr) == <<>>
      complete(kernel, @read_bd_addr, <<0>> <> @addr_le)

      assert Task.await(task) == {:ok, @addr_le}
    end

    test "the named helpers encode their parameters and decode the reply" do
      %{server: server, kernel: kernel} = start_server()

      task = async(fn -> HciUser.read_bd_addr(server) end)
      expect_command(kernel, @read_bd_addr)
      complete(kernel, @read_bd_addr, <<0>> <> @addr_le)
      assert Task.await(task) == {:ok, @bd_addr}

      task = async(fn -> HciUser.read_local_version(server) end)
      expect_command(kernel, @read_local_version)
      complete(kernel, @read_local_version, <<0, 10, 0x0B, 0, 10, 93, 0, 0x22, 0xD9>>)

      assert {:ok, %{manufacturer: 93, lmp_subversion: 0xD922, hci_version: 10}} =
               Task.await(task)

      task =
        async(fn ->
          HciUser.le_set_scan_parameters(server, type: :passive, interval_ms: 30, window_ms: 30)
        end)

      assert expect_command(kernel, @le_scan_params) == <<0, 0x30, 0, 0x30, 0, 0, 0>>
      complete(kernel, @le_scan_params, <<0>>)
      assert Task.await(task) == :ok

      task = async(fn -> HciUser.le_set_scan_enable(server, true, false) end)
      assert expect_command(kernel, @le_scan_enable) == <<1, 0>>
      complete(kernel, @le_scan_enable, <<0>>)
      assert Task.await(task) == :ok
    end

    test "a short reply decodes as :malformed_reply" do
      %{server: server, kernel: kernel} = start_server()

      task = async(fn -> HciUser.read_bd_addr(server) end)
      expect_command(kernel, @read_bd_addr)
      complete(kernel, @read_bd_addr, <<0, 1, 2>>)
      assert Task.await(task) == {:error, :malformed_reply}
    end

    test "a non-zero status is an error" do
      %{server: server, kernel: kernel} = start_server()

      task = async(fn -> HciUser.le_set_scan_enable(server, true, false) end)
      expect_command(kernel, @le_scan_enable)
      complete(kernel, @le_scan_enable, <<0x0C>>)
      assert Task.await(task) == {:error, {:status, 0x0C}}
    end

    test "Command Status answers: 0 is pending, anything else an error" do
      %{server: server, kernel: kernel} = start_server()

      task = async(fn -> HciUser.command(server, @le_create_conn, <<1, 2, 3>>) end)
      assert expect_command(kernel, @le_create_conn) == <<1, 2, 3>>
      command_status(kernel, @le_create_conn, 0)
      assert Task.await(task) == {:ok, :pending}

      task = async(fn -> HciUser.command(server, @le_create_conn, <<1, 2, 3>>) end)
      expect_command(kernel, @le_create_conn)
      command_status(kernel, @le_create_conn, 0x01)
      assert Task.await(task) == {:error, {:status, 0x01}}
    end

    test "invalid helper options raise in the caller, sending nothing" do
      %{server: server, kernel: kernel} = start_server()

      assert_raise ArgumentError, fn ->
        HciUser.le_set_scan_parameters(server, type: :passive, interval_ms: 30, window_ms: 40)
      end

      assert_raise ArgumentError, fn ->
        HciUser.le_set_advertising_data(server, :binary.copy(<<0>>, 32))
      end

      refute_command(kernel)
      assert Process.alive?(server)
    end

    test "commands go out one at a time by default, in call order" do
      %{server: server, kernel: kernel} = start_server()

      first = async(fn -> HciUser.command(server, @reset) end)
      expect_command(kernel, @reset)
      second = async(fn -> HciUser.command(server, @read_bd_addr) end)
      # The controller still has a credit, but one is already in flight.
      refute_command(kernel)

      complete(kernel, @reset, <<0>>)
      assert Task.await(first) == {:ok, <<>>}
      expect_command(kernel, @read_bd_addr)
      complete(kernel, @read_bd_addr, <<0>> <> @addr_le)
      assert Task.await(second) == {:ok, @addr_le}
    end

    test "a reply for another opcode doesn't answer the command in flight" do
      %{server: server, kernel: kernel} = start_server()

      task = async(fn -> HciUser.command(server, @read_bd_addr) end)
      expect_command(kernel, @read_bd_addr)
      complete(kernel, @reset, <<0>>)
      refute Task.yield(task, 100)

      complete(kernel, @read_bd_addr, <<0>> <> @addr_le)
      assert Task.await(task) == {:ok, @addr_le}
    end

    test "Num_HCI_Command_Packets = 0 holds commands until a credit is granted" do
      %{server: server, kernel: kernel} = start_server()

      first = async(fn -> HciUser.command(server, @reset) end)
      expect_command(kernel, @reset)
      complete(kernel, @reset, <<0>>, 0)
      assert Task.await(first) == {:ok, <<>>}

      second = async(fn -> HciUser.command(server, @read_bd_addr) end)
      refute_command(kernel)

      # A NOP Command Complete (opcode 0) grants the credit back.
      complete(kernel, 0x0000, <<>>, 1)
      expect_command(kernel, @read_bd_addr)
      complete(kernel, @read_bd_addr, <<0>> <> @addr_le)
      assert Task.await(second) == {:ok, @addr_le}
    end
  end

  describe "timeouts" do
    test "an unanswered command is a fault: the channel closes" do
      %{server: server, kernel: kernel} = start_server()
      mon = Process.monitor(server)

      enable = async(fn -> HciUser.le_set_advertising_enable(server, true, 100) end)
      assert expect_command(kernel, 0x200A) == <<1>>
      # Same opcode, queued behind it: a late enable reply must never
      # acknowledge this disable.
      disable = async(fn -> HciUser.le_set_advertising_enable(server, false) end)

      assert Task.await(enable) == {:error, :timeout}
      assert Task.await(disable) == {:error, :closed}
      assert_receive {:bluez_hci_user, ^server, {:closed, :command_timeout}}, 1_000
      assert_receive {:DOWN, ^mon, :process, ^server, :normal}, 1_000

      # The disable was never sent, and the socket is closed.
      refute_command(kernel)
      assert {:error, :econnrefused} = :socket.send(kernel, <<0x04, 0x0E, 4, 1, 0x0A, 0x20, 0>>)
      assert HciUser.le_set_advertising_enable(server, false) == {:error, :closed}
    end

    test "a reply read only after the deadline is still a timeout" do
      %{server: server, kernel: kernel} = start_server()
      mon = Process.monitor(server)

      task = async(fn -> HciUser.le_set_advertising_enable(server, true, 100) end)
      expect_command(kernel, 0x200A)

      :ok = :sys.suspend(server)
      # Readiness queued before the timeout fires, by an earlier event...
      event(kernel, 0x05, <<0, 0x40, 0x00, 0x13>>)
      Process.sleep(150)
      # ...and the reply arriving after the deadline, read in the same drain.
      complete(kernel, 0x200A, <<0>>)
      :ok = :sys.resume(server)

      assert Task.await(task) == {:error, :timeout}
      assert_receive {:bluez_hci_user, ^server, {:closed, :command_timeout}}, 1_000
      assert_receive {:DOWN, ^mon, :process, ^server, :normal}, 1_000
    end

    test "a Command Complete without a Status byte is a fault" do
      %{server: server, kernel: kernel} = start_server()
      mon = Process.monitor(server)

      task = async(fn -> HciUser.le_set_advertising_enable(server, true) end)
      expect_command(kernel, 0x200A)
      complete(kernel, 0x200A, <<>>)

      assert Task.await(task) == {:error, :malformed_reply}
      assert_receive {:bluez_hci_user, ^server, {:closed, :malformed_reply}}, 1_000
      assert_receive {:DOWN, ^mon, :process, ^server, :normal}, 1_000
    end

    test "a request that expired in the mailbox is rejected, never sent" do
      %{server: server, kernel: kernel} = start_server()

      :ok = :sys.suspend(server)
      task = async(fn -> HciUser.command(server, @reset, <<>>, 50) end)
      Process.sleep(100)
      :ok = :sys.resume(server)

      assert Task.await(task) == {:error, :timeout}
      refute_command(kernel)

      # Nothing faulted: the next command goes out as usual.
      task = async(fn -> HciUser.command(server, @read_bd_addr) end)
      expect_command(kernel, @read_bd_addr)
      complete(kernel, @read_bd_addr, <<0>> <> @addr_le)
      assert Task.await(task) == {:ok, @addr_le}
    end

    test "a send the socket can't take by the deadline is a fault" do
      # The smallest send buffer: a few unread commands fill it.
      inner = user_channel_open()

      open = fn index ->
        {:ok, proc} = inner.(index)
        :ok = :socket.setopt(proc, {:socket, :sndbuf}, 1)
        {:ok, proc}
      end

      %{server: server, kernel: kernel} = start_server(open: open)
      mon = Process.monitor(server)
      big = :binary.copy(<<0xA5>>, 255)

      # Each command is answered but never read, until a send blocks.
      result =
        Enum.reduce_while(1..100, nil, fn _i, nil ->
          task = async(fn -> HciUser.command(server, 0xFC01, big, 300) end)

          case sent_or_done(server, task) do
            :sent ->
              complete(kernel, 0xFC01, <<0>>)
              assert Task.await(task) == {:ok, <<>>}
              {:cont, nil}

            {:done, result} ->
              {:halt, result}
          end
        end)

      assert result == {:error, :timeout}
      assert_receive {:bluez_hci_user, ^server, {:closed, :send_timeout}}, 1_000
      assert_receive {:DOWN, ^mon, :process, ^server, :normal}, 1_000
    end

    test "a command waiting for a credit times out without being sent" do
      %{server: server, kernel: kernel} = start_server()

      first = async(fn -> HciUser.command(server, @reset) end)
      expect_command(kernel, @reset)
      complete(kernel, @reset, <<0>>, 0)
      assert Task.await(first) == {:ok, <<>>}

      assert HciUser.command(server, @read_bd_addr, <<>>, 100) == {:error, :timeout}

      complete(kernel, 0x0000, <<>>, 1)
      refute_command(kernel)
    end

    test "no credit for ncmd_timeout restores one and reports :command_stall" do
      %{server: server, kernel: kernel} = start_server(ncmd_timeout: 100)

      first = async(fn -> HciUser.command(server, @reset) end)
      expect_command(kernel, @reset)
      complete(kernel, @reset, <<0>>, 0)
      assert Task.await(first) == {:ok, <<>>}

      second = async(fn -> HciUser.command(server, @read_bd_addr) end)
      assert_receive {:bluez_hci_user, ^server, :command_stall}, 1_000
      expect_command(kernel, @read_bd_addr)
      complete(kernel, @read_bd_addr, <<0>> <> @addr_le)
      assert Task.await(second) == {:ok, @addr_le}
    end
  end

  describe "events" do
    test "Hardware Error reaches the owner" do
      %{server: server, kernel: kernel} = start_server()

      event(kernel, 0x10, <<0x42>>)
      assert_receive {:bluez_hci_user, ^server, {:hardware_error, 0x42}}, 1_000
      assert Process.alive?(server)
    end

    test "advertising reports are decoded, one message per report" do
      %{server: server, kernel: kernel} = start_server()

      data = <<2, 1, 6, 3, 3, 0xAA, 0xFE>>

      legacy =
        <<0x02, 2, 0, 0, @addr_le::binary, byte_size(data), data::binary, -60::signed, 3, 1,
          @addr_le::binary, 0, -70::signed>>

      event(kernel, 0x3E, legacy)

      ext =
        <<0x0D, 1, 0x13::little-16, 1, @addr_le::binary, 1, 0, 0xFF, 127, -55::signed,
          0::little-16, 0, 0::48, byte_size(data), data::binary>>

      event(kernel, 0x3E, ext)

      assert_receive {:bluez_hci_user, ^server,
                      {:adv_report,
                       %{address: @bd_addr, data: ^data, rssi: -60, connectable: true}}},
                     1_000

      assert_receive {:bluez_hci_user, ^server,
                      {:adv_report, %{data: <<>>, rssi: -70, event_type: 3}}},
                     1_000

      assert_receive {:bluez_hci_user, ^server,
                      {:adv_report, %{data: ^data, rssi: -55, legacy: true, address_type: 1}}},
                     1_000
    end

    test "reports are dropped while the owner is backlogged, other events never" do
      test_pid = self()

      # Holds its mailbox until told to forward everything to the test.
      owner =
        spawn_link(fn ->
          receive do
            :go -> forward(test_pid)
          end
        end)

      %{server: server, kernel: kernel} = start_server(owner: owner, max_owner_backlog: 3)

      report = <<3, 0, @addr_le::binary, 0, -50::signed>>
      event(kernel, 0x3E, <<0x02, 6>> <> :binary.copy(report, 6))
      event(kernel, 0x10, <<0x42>>)
      event(kernel, 0x05, <<0, 0x40, 0x00, 0x13>>)

      # Three reports delivered, three dropped, both other events kept.
      assert wait_until(fn ->
               Process.info(owner, :message_queue_len) == {:message_queue_len, 5}
             end)

      send(owner, :go)

      for _i <- 1..3, do: assert_receive({:bluez_hci_user, ^server, {:adv_report, _}}, 1_000)
      assert_receive {:bluez_hci_user, ^server, {:hardware_error, 0x42}}, 1_000
      assert_receive {:bluez_hci_user, ^server, {:event, 0x05, _}}, 1_000
      refute_receive {:bluez_hci_user, ^server, _other}, 100

      # Caught up: the drop count first, then reports again.
      event(kernel, 0x3E, <<0x02, 1>> <> report)
      assert_receive {:bluez_hci_user, ^server, {:reports_dropped, 3}}, 1_000
      assert_receive {:bluez_hci_user, ^server, {:adv_report, %{rssi: -50}}}, 1_000
    end

    test "other events are forwarded raw; data packets are dropped" do
      %{server: server, kernel: kernel} = start_server()

      # An ACL data packet, then Disconnection Complete, then an LE Meta
      # subevent other than a report.
      :ok = :socket.send(kernel, <<0x02, 0x40, 0x00, 1, 0, 0xAA>>)
      event(kernel, 0x05, <<0, 0x40, 0x00, 0x13>>)
      event(kernel, 0x3E, <<0x12, 0, 1, 0, 0, 0>>)

      assert_receive {:bluez_hci_user, ^server, {:event, 0x05, <<0, 0x40, 0x00, 0x13>>}}, 1_000
      assert_receive {:bluez_hci_user, ^server, {:event, 0x3E, <<0x12, 0, 1, 0, 0, 0>>}}, 1_000
      refute_receive {:bluez_hci_user, ^server, _other}, 100
    end
  end

  describe "closing" do
    test "a socket error fails pending commands, tells the owner and stops" do
      %{server: server, proc: proc, kernel: kernel} = start_server()
      mon = Process.monitor(server)

      task = async(fn -> HciUser.command(server, @reset) end)
      expect_command(kernel, @reset)
      # What the socket layer delivers when the select is aborted under us.
      send(server, {:"$socket", proc, :abort, {make_ref(), :enodev}})

      assert Task.await(task) == {:error, :closed}
      assert_receive {:bluez_hci_user, ^server, {:closed, {:abort, :enodev}}}, 1_000
      assert_receive {:DOWN, ^mon, :process, ^server, :normal}, 1_000
      assert HciUser.command(server, @reset) == {:error, :closed}
    end

    test "end of file on the socket closes it" do
      %{server: server, kernel: kernel} = start_server(socket_type: :seqpacket)
      mon = Process.monitor(server)

      :socket.close(kernel)
      assert_receive {:bluez_hci_user, ^server, {:closed, :eof}}, 1_000
      assert_receive {:DOWN, ^mon, :process, ^server, :normal}, 1_000
    end

    test "a failed send closes it" do
      %{server: server, kernel: kernel} = start_server()
      mon = Process.monitor(server)

      :socket.close(kernel)
      assert HciUser.command(server, @reset) == {:error, :closed}
      assert_receive {:bluez_hci_user, ^server, {:closed, :econnrefused}}, 1_000
      assert_receive {:DOWN, ^mon, :process, ^server, :normal}, 1_000
    end

    test "close/1 closes the socket, failing pending commands" do
      %{server: server, kernel: kernel} = start_server()

      task = async(fn -> HciUser.command(server, @reset) end)
      expect_command(kernel, @reset)
      assert HciUser.close(server) == :ok
      assert Task.await(task) == {:error, :closed}

      # The server's side is closed: the "kernel" can no longer reach it.
      assert {:error, :econnrefused} = :socket.send(kernel, <<0x04, 0x10, 1, 0>>)
      assert HciUser.close(server) == :ok
    end

    test "the owner exiting closes the socket" do
      owner =
        spawn(fn ->
          receive do
            :stop -> :ok
          end
        end)

      %{server: server, kernel: kernel} = start_server(owner: owner)
      mon = Process.monitor(server)

      send(owner, :stop)
      assert_receive {:DOWN, ^mon, :process, ^server, :normal}, 1_000
      assert {:error, :econnrefused} = :socket.send(kernel, <<0x04, 0x10, 1, 0>>)
    end
  end

  describe "bring-up" do
    # Plays the kernel's MGMT side: `answer.(opcode, index, params)` gives
    # `{status, return_params}`; every command is also reported to the test.
    defp fake_mgmt(answer) do
      test_pid = self()

      fn ->
        {proc, kernel} = TestSocketPair.open()
        responder = spawn(fn -> mgmt_loop(kernel, test_pid, answer) end)
        :ok = :socket.setopt(kernel, :otp, :controlling_process, responder)
        {:ok, proc}
      end
    end

    defp mgmt_loop(kernel, test_pid, answer) do
      case :socket.recv(kernel, 0, 1_000) do
        {:ok, <<opcode::little-16, index::little-16, len::little-16, params::binary-size(len)>>} ->
          send(test_pid, {:mgmt, opcode, index, params})
          {status, rp} = answer.(opcode, index, params)
          ev = <<opcode::little-16, status, rp::binary>>

          :ok =
            :socket.send(
              kernel,
              <<0x0001::little-16, index::little-16, byte_size(ev)::little-16, ev::binary>>
            )

          mgmt_loop(kernel, test_pid, answer)

        {:error, _reason} ->
          :socket.close(kernel)
      end
    end

    defp controller_info(address),
      do:
        <<address::little-48, 10, 93::little-16, 0xFFFF::little-32, 0::little-32>> <>
          :binary.copy(<<0>>, 263)

    @other_addr 0x001122334455

    defp two_controllers do
      fn
        @read_index_list, 0xFFFF, <<>> -> {0, <<2::little-16, 0::little-16, 1::little-16>>}
        @read_controller_info, 0, <<>> -> {0, controller_info(@other_addr)}
        @read_controller_info, 1, <<>> -> {0, controller_info(@bd_addr)}
        @set_powered, _index, <<0>> -> {0, <<0::little-32>>}
      end
    end

    test "powers the controller off through MGMT before binding" do
      %{server: server} =
        start_server(index: 1, power_off_first: true, open_control: fake_mgmt(two_controllers()))

      assert_received {:mgmt, @set_powered, 1, <<0>>}
      assert HciUser.index(server) == {:ok, 1}
    end

    test "resolves :address to the controller's index" do
      %{server: server} =
        start_server(
          index: nil,
          address: "B8:FB:B3:1B:3B:44",
          power_off_first: true,
          open_control: fake_mgmt(two_controllers())
        )

      assert HciUser.index(server) == {:ok, 1}

      # Resolved first, then powered off.
      assert_received {:mgmt, @read_index_list, 0xFFFF, <<>>}
      assert_received {:mgmt, @read_controller_info, 0, <<>>}
      assert_received {:mgmt, @read_controller_info, 1, <<>>}
      assert_received {:mgmt, @set_powered, 1, <<0>>}
    end

    test "find_index/2 reports an absent address" do
      open_control = fake_mgmt(two_controllers())
      assert HciUser.find_index(@bd_addr, open_control: open_control) == {:ok, 1}

      assert HciUser.find_index(0x0A0B0C0D0E0F, open_control: open_control) ==
               {:error, :not_found}

      assert HciUser.find_index("nope") == {:error, {:invalid_address, "nope"}}
    end

    test "a refused power-off fails the start without binding" do
      refuse = fn @set_powered, _index, _params -> {0x11, <<>>} end

      assert HciUser.start_link(
               index: 3,
               owner: self(),
               open_control: fake_mgmt(refuse),
               open: user_channel_open()
             ) == {:error, {:power_off, :invalid_index}}

      refute_received {:bound, _, _, _}
    end

    test "a failed bind fails start_link without taking the caller down" do
      assert HciUser.start_link(
               index: 0,
               power_off_first: false,
               open: fn 0 -> {:error, :ebusy} end
             ) ==
               {:error, {:bind, :ebusy}}

      assert HciUser.start_link(power_off_first: false) ==
               {:error, {:invalid_option, :index_or_address}}
    end
  end

  test "the codec's opcodes match the helpers' commands" do
    assert Codec.opcode(:reset) == @reset
    assert Codec.opcode(:le_set_scan_enable) == @le_scan_enable
  end
end
