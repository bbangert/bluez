defmodule Bluez.AdapterGateTest do
  # Not async: drives the global adapter-path :persistent_term.
  use ExUnit.Case, async: false

  alias Bluez.{Advertiser, DevicePath, Mgmt, TestSocketPair}
  alias Bluez.Rebus.{Message, TestServer}

  setup do
    previous = :persistent_term.get(DevicePath.adapter_path_key(), nil)
    :persistent_term.erase(DevicePath.adapter_path_key())

    on_exit(fn ->
      if previous,
        do: :persistent_term.put(DevicePath.adapter_path_key(), previous),
        else: :persistent_term.erase(DevicePath.adapter_path_key())
    end)
  end

  test "resolved_adapter_path/0 is :error until the Client publishes one" do
    assert DevicePath.resolved_adapter_path() == :error
    assert DevicePath.adapter_path() == "/org/bluez/hci0"

    :persistent_term.put(DevicePath.adapter_path_key(), "/org/bluez/hci1")
    assert DevicePath.resolved_adapter_path() == {:ok, "/org/bluez/hci1"}
  end

  test "Mgmt refuses to act on the hci0 fallback" do
    test_pid = self()

    open = fn ->
      {proc, kernel} = TestSocketPair.open()
      :ok = :socket.setopt(kernel, :otp, :controlling_process, test_pid)
      send(test_pid, {:kernel, kernel})
      {:ok, proc}
    end

    mgmt = start_supervised!({Mgmt, name: nil, open: open})
    assert_receive {:kernel, kernel}

    assert Mgmt.advertise(<<2, 1, 6>>, server: mgmt) == {:error, :no_adapter_index}
    assert {:error, :timeout} = :socket.recv(kernel, 0, 50)
  end

  test "Advertiser refuses to register on the hci0 fallback" do
    {:ok, svr} = start_supervised({TestServer, tap: self()})
    {:ok, addr} = TestServer.get_listen_addr(svr)
    connect_fun = fn -> Bluez.Rebus.connect(addr) end

    starter = Task.async(fn -> GenServer.start(Advertiser, connect_fun: connect_fun) end)
    assert_receive {^svr, %Message{header_fields: %{member: "Hello"}} = hello}, 1_000

    TestServer.push(
      svr,
      Message.new!(:method_return,
        reply_serial: hello.serial,
        signature: "s",
        flags: [],
        body: [":1.100"]
      )
    )

    {:ok, adv} = Task.await(starter)
    on_exit(fn -> Process.exit(adv, :kill) end)

    assert Advertiser.advertise(%{type: :broadcast}, server: adv) == {:error, :no_adapter}
    refute_receive {^svr, %Message{header_fields: %{member: "RegisterAdvertisement"}}}, 50
  end
end
