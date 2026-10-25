defmodule Bluez.AdapterGateTest do
  # Not async: drives the global resolved-adapter :persistent_term.
  use ExUnit.Case, async: false

  alias Bluez.{Client, DevicePath, Radio}

  setup do
    previous = :persistent_term.get(DevicePath.resolved_adapter_key(), nil)
    :persistent_term.erase(DevicePath.resolved_adapter_key())

    on_exit(fn ->
      if previous,
        do: :persistent_term.put(DevicePath.resolved_adapter_key(), previous),
        else: :persistent_term.erase(DevicePath.resolved_adapter_key())
    end)
  end

  test "resolved_adapter_path/0 is :error until the Client publishes one" do
    assert DevicePath.resolved_adapter_path() == :error

    :persistent_term.put(DevicePath.resolved_adapter_key(), "/org/bluez/hci1")
    assert DevicePath.resolved_adapter_path() == {:ok, "/org/bluez/hci1"}
  end

  test "a (re)starting Client clears the previous incarnation's resolution" do
    :persistent_term.put(DevicePath.resolved_adapter_key(), "/org/bluez/hci1")

    # Fails to connect right after init clears the marker — the point is
    # that a new incarnation never inherits the old selection.
    assert {:error, _} = GenServer.start(Client, connect_fun: fn -> {:error, :no_bus} end)
    assert DevicePath.resolved_adapter_path() == :error
  end

  test "Radio refuses to lease the hci0 fallback" do
    radio = start_supervised!({Radio, name: nil})
    assert Radio.acquire(server: radio) == {:error, :no_adapter_index}

    # Once the Client has resolved an adapter, that is the default.
    :persistent_term.put(DevicePath.resolved_adapter_key(), "/org/bluez/hci1")
    assert {:ok, %Radio.Lease{index: 1}} = Radio.acquire(server: radio)
  end
end
