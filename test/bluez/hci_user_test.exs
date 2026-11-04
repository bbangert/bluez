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

  # The server's traced steps, in order, until it stops.
  defp trace_steps(server, acc) do
    receive do
      {:trace, ^server, :call, {:socket, :close, _args}} ->
        trace_steps(server, [:close | acc])

      {:trace, ^server, :send, {_tag, {:error, :timeout}}, _to} ->
        trace_steps(server, [:reply | acc])

      {:trace, ^server, :send, {:bluez_hci_user, ^server, {:closed, _}}, _to} ->
        trace_steps(server, [:closed | acc])

      {:trace, ^server, _kind, _what, _to} ->
        trace_steps(server, acc)

      {:trace, ^server, _kind, _what} ->
        trace_steps(server, acc)
    after
      200 -> Enum.reverse(acc)
    end
  end

  defp fill(sock) do
    case :socket.send(sock, :binary.copy(<<0>>, 256), [], 10) do
      :ok -> fill(sock)
      {:error, :timeout} -> :ok
    end
  end

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

  defp assert_receive_command_sent(server, tries \\ 100) do
    cond do
      :sys.get_state(server).in_flight != nil -> :ok
      tries == 0 -> flunk("command never sent")
      true -> Process.sleep(5) && assert_receive_command_sent(server, tries - 1)
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
      # Released before anyone hears of the fault: re-binding can't race it.
      assert {:error, :econnrefused} = :socket.send(kernel, <<0x04, 0x10, 1, 0>>)
      assert Task.await(disable) == {:error, :closed}
      assert_receive {:bluez_hci_user, ^server, {:closed, :command_timeout}}, 1_000
      assert_receive {:DOWN, ^mon, :process, ^server, :normal}, 1_000

      # The disable was never sent.
      refute_command(kernel)
      assert HciUser.le_set_advertising_enable(server, false) == {:error, :closed}
    end

    test "the socket is closed before the fault is reported to anyone" do
      %{server: server, kernel: kernel} = start_server()

      # An isolated trace session: the server's socket close, and its sends.
      session = :trace.session_create(:hci_user_close_order, self(), [])
      on_exit(fn -> :trace.session_destroy(session) end)
      :trace.function(session, {:socket, :close, 1}, true, [:local])
      :trace.process(session, server, true, [:call, :send])

      task = async(fn -> HciUser.le_set_advertising_enable(server, true, 100) end)
      expect_command(kernel, 0x200A)
      assert Task.await(task) == {:error, :timeout}
      assert_receive {:bluez_hci_user, ^server, {:closed, :command_timeout}}, 1_000

      # In the order they happened: the close first, then the caller's
      # reply and the owner's message.
      assert [:close, :reply, :closed] = server |> trace_steps([]) |> Enum.uniq()
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

      assert_receive {:bluez_hci_user, ^server, {:closed, {:abort, :enodev}}}, 1_000
      # Already closed when the owner hears of it.
      assert {:error, :econnrefused} = :socket.send(kernel, <<0x04, 0x10, 1, 0>>)
      assert Task.await(task) == {:error, :closed}
      assert_receive {:DOWN, ^mon, :process, ^server, :normal}, 1_000
      assert HciUser.command(server, @reset) == {:error, :closed}
    end

    test "the first recv error closes it, though later reads wouldn't fail" do
      %{server: server, kernel: kernel} = start_server(socket_type: :seqpacket)
      mon = Process.monitor(server)

      # The controller side goes away with a command still unread: the next
      # read fails once (:econnreset), then would only see end of file.
      # Like an unplug's :epipe, the single error must close the channel.
      task = async(fn -> HciUser.command(server, @reset) end)
      assert_receive_command_sent(server)
      :socket.close(kernel)

      assert_receive {:bluez_hci_user, ^server, {:closed, :econnreset}}, 1_000
      assert Task.await(task) == {:error, :closed}
      assert_receive {:DOWN, ^mon, :process, ^server, :normal}, 1_000
    end

    test "an :epipe send (an unplugged controller) closes it" do
      %{server: server, kernel: kernel} = start_server(socket_type: :seqpacket)
      mon = Process.monitor(server)

      # The controller side stops reading: sending to it fails with :epipe.
      :ok = :socket.shutdown(kernel, :read)

      assert HciUser.command(server, @reset) == {:error, :closed}
      assert_receive {:bluez_hci_user, ^server, {:closed, :epipe}}, 1_000
      assert_receive {:DOWN, ^mon, :process, ^server, :normal}, 1_000
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

          case answer.(opcode, index, params) do
            :no_reply -> mgmt_loop(kernel, test_pid, answer)
            {status, rp} -> mgmt_reply(kernel, test_pid, answer, index, opcode, status, rp)
          end

        {:error, _reason} ->
          :socket.close(kernel)
      end
    end

    defp mgmt_reply(kernel, test_pid, answer, index, opcode, status, rp) do
      ev = <<opcode::little-16, status, rp::binary>>
      packet = <<0x0001::little-16, index::little-16, byte_size(ev)::little-16, ev::binary>>

      # The other side may have given up (and closed) meanwhile.
      case :socket.send(kernel, packet) do
        :ok -> mgmt_loop(kernel, test_pid, answer)
        {:error, _reason} -> :socket.close(kernel)
      end
    end

    defp controller_info(address, current_settings \\ 0),
      do:
        <<address::little-48, 10, 93::little-16, 0xFFFF::little-32, current_settings::little-32>> <>
          :binary.copy(<<0>>, 263)

    # Refuses the first `busy` binds with :ebusy, counting every attempt.
    defp busy_then_open(busy, attempts) do
      inner = user_channel_open()

      fn index ->
        :counters.add(attempts, 1, 1)
        if :counters.get(attempts, 1) <= busy, do: {:error, :ebusy}, else: inner.(index)
      end
    end

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

    test "an expired MGMT deadline sends nothing" do
      test_pid = self()

      open_control = fn ->
        {proc, kernel} = TestSocketPair.open()
        :ok = :socket.setopt(kernel, :otp, :controlling_process, test_pid)
        send(test_pid, {:control_kernel, kernel})
        {:ok, proc}
      end

      assert HciUser.start_link(
               index: 0,
               mgmt_timeout: 0,
               open_control: open_control,
               open: user_channel_open()
             ) == {:error, {:power_off, :timeout}}

      assert_received {:control_kernel, kernel}
      assert {:error, :timeout} = :socket.recv(kernel, 0, 100)
    end

    test "nothing is read once the MGMT deadline has passed" do
      test_pid = self()

      open_control = fn ->
        {proc, kernel} = TestSocketPair.open()
        :ok = :socket.setopt(kernel, :otp, :controlling_process, test_pid)
        send(test_pid, {:control_kernel, self(), kernel})
        {:ok, proc}
      end

      task =
        Task.async(fn ->
          HciUser.start(
            index: 0,
            owner: test_pid,
            mgmt_timeout: 100,
            open_control: open_control,
            open: user_channel_open()
          )
        end)

      assert_receive {:control_kernel, server, kernel}, 1_000
      assert {:ok, <<0x0005::little-16, _::binary>>} = :socket.recv(kernel, 0, 1_000)

      # The server is waiting for the reply. Hold it past its deadline, then
      # let unrelated events — and after them the very reply it wants —
      # arrive: reading on past the deadline would reach the reply.
      true = :erlang.suspend_process(server)
      Process.sleep(200)
      index_added = <<0x0004::little-16, 5::little-16, 0::little-16>>
      for _i <- 1..20, do: :ok = :socket.send(kernel, index_added)
      rp = <<0x0005::little-16, 0, 0::little-32>>
      :ok = :socket.send(kernel, <<1::little-16, 0::little-16, byte_size(rp)::little-16>> <> rp)
      true = :erlang.resume_process(server)

      assert Task.await(task) == {:error, {:power_off, :timeout}}
      refute_received {:bound, _, _, _}
    end

    test "a MGMT command the control socket can't take times out" do
      test_pid = self()

      # The smallest send buffer, filled with packets nobody reads.
      open_control = fn ->
        {proc, kernel} = TestSocketPair.open()
        :ok = :socket.setopt(kernel, :otp, :controlling_process, test_pid)
        :ok = :socket.setopt(proc, {:socket, :sndbuf}, 1)
        fill(proc)
        {:ok, proc}
      end

      task =
        Task.async(fn ->
          HciUser.start_link(
            index: 0,
            mgmt_timeout: 200,
            open_control: open_control,
            open: user_channel_open()
          )
        end)

      assert Task.yield(task, 1_500) == {:ok, {:error, {:power_off, :timeout}}}
    end

    test "an unanswered MGMT command times out by :mgmt_timeout, leaving the bind budget" do
      # Read Controller Info during the retry is never answered.
      answer = fn
        @set_powered, 0, <<0>> -> {0, <<0::little-32>>}
        @read_controller_info, 0, <<>> -> :no_reply
      end

      attempts = :counters.new(1, [])

      # It gives up on the reply after 100 ms, and the second bind (well
      # inside the 2 s budget) succeeds.
      %{server: server} =
        start_server(
          power_off_first: true,
          mgmt_timeout: 100,
          bind_timeout: 2_000,
          open_control: fake_mgmt(answer),
          open: busy_then_open(1, attempts)
        )

      assert HciUser.index(server) == {:ok, 0}
      assert :counters.get(attempts, 1) == 2
      assert_received {:mgmt, @read_controller_info, 0, <<>>}
    end

    test "no pause is taken once the MGMT work has spent the bind budget" do
      test_pid = self()

      answer = fn
        @set_powered, 0, <<0>> -> {0, <<0::little-32>>}
        @read_controller_info, 0, <<>> -> :no_reply
      end

      assert HciUser.start_link(
               index: 0,
               power_off_first: true,
               mgmt_timeout: 2_000,
               bind_timeout: 300,
               open_control: fake_mgmt(answer),
               open: fn 0 -> {:error, :ebusy} end,
               sleep: fn ms ->
                 send(test_pid, :slept)
                 Process.sleep(ms)
               end
             ) == {:error, {:bind, :ebusy}}

      # The unanswered Read Controller Info used up the budget.
      assert_received {:mgmt, @read_controller_info, 0, <<>>}
      refute_received :slept
    end

    test "a bind due after the deadline (the retry overslept) is not attempted" do
      attempts = :counters.new(1, [])

      assert HciUser.start_link(
               index: 0,
               power_off_first: false,
               bind_timeout: 100,
               # The second bind would succeed, but comes too late.
               open: busy_then_open(1, attempts),
               sleep: fn _ms -> Process.sleep(150) end
             ) == {:error, {:bind, :ebusy}}

      assert :counters.get(attempts, 1) == 1
    end

    test "a refused power-off fails the start at once, without binding" do
      for {status, reason} <- [{0x11, :invalid_index}, {0x03, :failed}] do
        calls = :counters.new(1, [])

        refuse = fn @set_powered, _index, _params ->
          :counters.add(calls, 1, 1)
          {status, <<>>}
        end

        assert HciUser.start_link(
                 index: 3,
                 owner: self(),
                 open_control: fake_mgmt(refuse),
                 open: user_channel_open()
               ) == {:error, {:power_off, reason}}

        # Only Busy is retried.
        assert :counters.get(calls, 1) == 1
      end

      refute_received {:bound, _, _, _}
    end

    # MGMT Busy (0x0A) for the first `busy` Set Powered commands.
    defp busy_power_off(busy, calls) do
      fn @set_powered, 0, <<0>> ->
        :counters.add(calls, 1, 1)
        if :counters.get(calls, 1) <= busy, do: {0x0A, <<>>}, else: {0, <<0::little-32>>}
      end
    end

    test "a power-off refused as Busy (bluetoothd configuring the index) is retried" do
      calls = :counters.new(1, [])

      %{server: server} =
        start_server(power_off_first: true, open_control: fake_mgmt(busy_power_off(3, calls)))

      assert :counters.get(calls, 1) == 4
      assert HciUser.index(server) == {:ok, 0}
    end

    test "a power-off still Busy when the budget is spent fails with :busy" do
      calls = :counters.new(1, [])
      started = System.monotonic_time(:millisecond)

      assert HciUser.start_link(
               index: 0,
               bind_timeout: 200,
               open_control: fake_mgmt(busy_power_off(1_000, calls)),
               open: user_channel_open()
             ) == {:error, {:power_off, :busy}}

      assert :counters.get(calls, 1) >= 3
      assert System.monotonic_time(:millisecond) - started < 1_000
      refute_received {:bound, _, _, _}
    end

    test "reads finding the controller off don't use up the re-power-off allowance" do
      reads = :counters.new(1, [])
      set_powered = :counters.new(1, [])

      # Off for the first six retry rounds (more than the allowance of five
      # power-offs), then bluetoothd powers it on.
      answer = fn
        @set_powered, 0, <<0>> ->
          :counters.add(set_powered, 1, 1)
          {0, <<0::little-32>>}

        @read_controller_info, 0, <<>> ->
          :counters.add(reads, 1, 1)
          {0, controller_info(@bd_addr, if(:counters.get(reads, 1) >= 7, do: 1, else: 0))}
      end

      attempts = :counters.new(1, [])

      start_server(
        power_off_first: true,
        open_control: fake_mgmt(answer),
        open: busy_then_open(7, attempts)
      )

      # The initial power-off, and the one correcting bluetoothd's power-on.
      assert :counters.get(set_powered, 1) == 2
    end

    test "an inconclusive read after a Busy power-off still ends in :busy" do
      set_powered = :counters.new(1, [])
      reads = :counters.new(1, [])

      # The first retry round finds it on and the power-off Busy; later
      # reads go unanswered.
      answer = fn
        @set_powered, 0, <<0>> ->
          :counters.add(set_powered, 1, 1)
          if :counters.get(set_powered, 1) == 1, do: {0, <<0::little-32>>}, else: {0x0A, <<>>}

        @read_controller_info, 0, <<>> ->
          :counters.add(reads, 1, 1)
          if :counters.get(reads, 1) == 1, do: {0, controller_info(@bd_addr, 1)}, else: :no_reply
      end

      assert HciUser.start_link(
               index: 0,
               mgmt_timeout: 50,
               bind_timeout: 300,
               open_control: fake_mgmt(answer),
               open: fn 0 -> {:error, :ebusy} end
             ) == {:error, {:power_off, :busy}}

      assert :counters.get(reads, 1) >= 2
    end

    test "a re-power-off still Busy when the bind budget is spent fails with :busy" do
      calls = :counters.new(1, [])

      # The first power-off works; bluetoothd then powers the controller
      # on again and refuses every later one as Busy.
      answer = fn
        @set_powered, 0, <<0>> ->
          :counters.add(calls, 1, 1)
          if :counters.get(calls, 1) == 1, do: {0, <<0::little-32>>}, else: {0x0A, <<>>}

        @read_controller_info, 0, <<>> ->
          {0, controller_info(@bd_addr, 1)}
      end

      assert HciUser.start_link(
               index: 0,
               bind_timeout: 200,
               open_control: fake_mgmt(answer),
               open: fn 0 -> {:error, :ebusy} end
             ) == {:error, {:power_off, :busy}}

      assert_received {:mgmt, @set_powered, 0, <<0>>}
      assert_received {:mgmt, @read_controller_info, 0, <<>>}
      assert_received {:mgmt, @set_powered, 0, <<0>>}
    end

    test "a bind refused with :ebusy is retried until it succeeds" do
      attempts = :counters.new(1, [])
      %{server: server} = start_server(open: busy_then_open(3, attempts))

      assert :counters.get(attempts, 1) == 4
      assert HciUser.index(server) == {:ok, 0}
    end

    test "a controller bluetoothd powers on while the bind is retried is powered off again" do
      powered = :atomics.new(1, [])
      :atomics.put(powered, 1, 1)

      answer = fn
        @set_powered, 0, <<0>> ->
          :atomics.put(powered, 1, 0)
          {0, <<0::little-32>>}

        @read_controller_info, 0, <<>> ->
          {0, controller_info(@bd_addr, :atomics.get(powered, 1))}
      end

      attempts = :counters.new(1, [])

      busy = busy_then_open(2, attempts)

      # bluetoothd powers it back on after the first power-off.
      open = fn index ->
        if :counters.get(attempts, 1) == 0, do: :atomics.put(powered, 1, 1)
        busy.(index)
      end

      start_server(power_off_first: true, open_control: fake_mgmt(answer), open: open)

      assert_received {:mgmt, @set_powered, 0, <<0>>}
      assert_received {:mgmt, @read_controller_info, 0, <<>>}
      assert_received {:mgmt, @set_powered, 0, <<0>>}
    end

    test "MGMT commands while re-powering off share what is left of the bind budget" do
      set_powered_calls = :counters.new(1, [])

      # The controller always reads powered, slowly. The first Set Powered
      # (before binding) is answered; the retry's never is.
      answer = fn
        @set_powered, 0, <<0>> ->
          :counters.add(set_powered_calls, 1, 1)
          if :counters.get(set_powered_calls, 1) == 1, do: {0, <<0::little-32>>}, else: :no_reply

        @read_controller_info, 0, <<>> ->
          Process.sleep(400)
          {0, controller_info(@bd_addr, 1)}
      end

      attempts = :counters.new(1, [])
      started = System.monotonic_time(:millisecond)

      assert HciUser.start_link(
               index: 0,
               power_off_first: true,
               mgmt_timeout: 2_000,
               bind_timeout: 600,
               open_control: fake_mgmt(answer),
               open: busy_then_open(1_000, attempts)
             ) == {:error, {:bind, :ebusy}}

      elapsed = System.monotonic_time(:millisecond) - started

      # The retry did read the controller and try to power it off...
      assert_received {:mgmt, @set_powered, 0, <<0>>}
      assert_received {:mgmt, @read_controller_info, 0, <<>>}
      assert_received {:mgmt, @set_powered, 0, <<0>>}
      # ...but Set Powered only waited out the ~200 ms left of the 600 ms
      # budget, not a fresh 600 ms (~1 000 ms in all) or :mgmt_timeout.
      assert elapsed < 850
      assert :counters.get(attempts, 1) == 1
    end

    test "a bind still refused when the budget is spent fails with :ebusy" do
      attempts = :counters.new(1, [])
      started = System.monotonic_time(:millisecond)

      assert HciUser.start_link(
               index: 0,
               power_off_first: false,
               bind_timeout: 100,
               open: busy_then_open(1_000, attempts)
             ) == {:error, {:bind, :ebusy}}

      assert :counters.get(attempts, 1) >= 3
      assert System.monotonic_time(:millisecond) - started < 1_000
    end

    test "a failed bind fails start_link without taking the caller down" do
      attempts = :counters.new(1, [])

      # Anything but :ebusy is not retried.
      assert HciUser.start_link(
               index: 0,
               power_off_first: false,
               open: fn 0 ->
                 :counters.add(attempts, 1, 1)
                 {:error, :enodev}
               end
             ) == {:error, {:bind, :enodev}}

      assert :counters.get(attempts, 1) == 1

      assert HciUser.start_link(power_off_first: false) ==
               {:error, {:invalid_option, :index_or_address}}
    end
  end

  test "the codec's opcodes match the helpers' commands" do
    assert Codec.opcode(:reset) == @reset
    assert Codec.opcode(:le_set_scan_enable) == @le_scan_enable
  end
end
