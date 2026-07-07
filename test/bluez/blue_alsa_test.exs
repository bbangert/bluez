defmodule Bluez.BlueAlsaTest do
  @moduledoc """
  Host tests for `Bluez.BlueAlsa`'s pure/observable behavior.

  The GenServer itself can't be started here — `init/1` calls
  `Bluez.Rebus.connect(:system)`, and there's no system bus on the host (it's part of
  the BT subtree, compile-gated off). So we exercise the signal→PubSub mapping
  by calling `handle_info/2` directly with a constructed state + message, which
  is exactly what the live process would receive from `Bluez.Rebus.add_signal_handler`.
  """
  use ExUnit.Case, async: true

  alias Bluez.BlueAlsa

  @pubsub Bluez.BlueAlsaTest.PubSub

  setup do
    start_supervised!({Phoenix.PubSub, name: @pubsub})
    :ok = Phoenix.PubSub.subscribe(@pubsub, BlueAlsa.pcms_topic())
    ref = make_ref()
    {:ok, state: %{conn: nil, conn_ref: nil, sig_ref: ref, pubsub: @pubsub}, sig_ref: ref}
  end

  defp signal(member) do
    %Bluez.Rebus.Message{
      type: :signal,
      header_fields: %{member: member},
      body: [],
      serial: 1,
      body_length: 0,
      version: 1,
      flags: 0
    }
  end

  test "InterfacesAdded broadcasts a PCM-set change", %{state: state, sig_ref: ref} do
    {:noreply, ^state} = BlueAlsa.handle_info({ref, signal("InterfacesAdded")}, state)
    assert_receive {:bluealsa_pcms_changed}
  end

  test "InterfacesRemoved broadcasts a PCM-set change", %{state: state, sig_ref: ref} do
    {:noreply, ^state} = BlueAlsa.handle_info({ref, signal("InterfacesRemoved")}, state)
    assert_receive {:bluealsa_pcms_changed}
  end

  test "an unrelated org.bluealsa signal does not broadcast", %{state: state, sig_ref: ref} do
    {:noreply, ^state} = BlueAlsa.handle_info({ref, signal("PropertiesChanged")}, state)
    refute_receive {:bluealsa_pcms_changed}, 100
  end
end
