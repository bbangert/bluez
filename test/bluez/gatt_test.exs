defmodule Bluez.GattTest do
  use ExUnit.Case, async: true

  alias Bluez.{DevicePath, Gatt, GattTree}

  # The Gatt GenServer needs a live D-Bus connection (hardware-validated,
  # like Bluez.Client); the pair/remove RESULT handling is pure state +
  # subscriber messaging, so those handle_info clauses are exercised
  # directly here.

  @address 0xAABBCCDDEEFF
  @gen 7

  defp entry(subscriber, overrides \\ %{}) do
    Map.merge(
      %{
        path: DevicePath.from_address(@address),
        subscriber: subscriber,
        status: :ready,
        tree: nil,
        resolve_timer: nil,
        gen: @gen
      },
      overrides
    )
  end

  # Mirrors init/1's defaults for the fields these handlers touch,
  # including the two injection seams (default: raw send / no-op).
  defp state(subscriber, overrides \\ %{}) do
    Map.merge(
      %{
        conns: %{@address => entry(subscriber)},
        notify_paths: %{},
        gen_seq: @gen,
        on_gatt_event: fn sub, event -> send(sub, event) end,
        on_connections_changed: fn -> :ok end
      },
      overrides
    )
  end

  defp bare_state(overrides \\ %{}), do: state(self(), Map.merge(%{conns: %{}}, overrides))

  describe "pair_result" do
    test "success reports paired with no error" do
      state = state(self())

      assert {:noreply, ^state} =
               Gatt.handle_info({:pair_result, @address, @gen, self(), :ok}, state)

      assert_receive {:gatt_pair, @address, true, 0}
    end

    test "failure forwards the error code" do
      state = state(self())

      assert {:noreply, ^state} =
               Gatt.handle_info({:pair_result, @address, @gen, self(), {:error, -1}}, state)

      assert_receive {:gatt_pair, @address, false, -1}
    end

    test "reply is delivered even when the entry is already gone" do
      # A failed Pair can drop the link; the Connected=false signal tears
      # the entry down before the pair Task's result arrives. The reply
      # must still reach the captured subscriber (hw-observed on H60B0).
      state = bare_state()

      assert {:noreply, ^state} =
               Gatt.handle_info({:pair_result, @address, @gen, self(), {:error, -1}}, state)

      assert_receive {:gatt_pair, @address, false, -1}
    end
  end

  describe "remove_result (unpair / clear_cache)" do
    test "success replies, then reports the disconnect, then drops the entry" do
      char_path = entry(self()).path <> "/service000a/char000b"

      state =
        state(self(), %{
          notify_paths: %{
            char_path => {@address, 12},
            "/org/bluez/hci0/dev_11_22_33_44_55_66/service0001/char0002" => {0x112233445566, 9}
          }
        })

      assert {:noreply, new_state} =
               Gatt.handle_info(
                 {:remove_result, @address, @gen, :gatt_unpair, self(), :ok},
                 state
               )

      # The op reply must land before the connection teardown envelope.
      assert {:messages,
              [
                {:gatt_unpair, @address, true, 0},
                {:gatt_connection, @address, {:error, -2}}
              ]} = Process.info(self(), :messages)

      # Entry gone; only this address's notification routes swept.
      assert new_state.conns == %{}

      assert Map.keys(new_state.notify_paths) == [
               "/org/bluez/hci0/dev_11_22_33_44_55_66/service0001/char0002"
             ]
    end

    test "clear_cache uses its own reply envelope" do
      state = state(self())

      assert {:noreply, new_state} =
               Gatt.handle_info(
                 {:remove_result, @address, @gen, :gatt_clear_cache, self(), :ok},
                 state
               )

      assert_receive {:gatt_clear_cache, @address, true, 0}
      assert_receive {:gatt_connection, @address, {:error, -2}}
      assert new_state.conns == %{}
    end

    test "failure keeps the entry and forwards the error" do
      state = state(self())

      assert {:noreply, ^state} =
               Gatt.handle_info(
                 {:remove_result, @address, @gen, :gatt_unpair, self(), {:error, -1}},
                 state
               )

      assert_receive {:gatt_unpair, @address, false, -1}
      refute_received {:gatt_connection, _, _}
    end

    test "success after the Connected=false signal already tore the entry down" do
      # BlueZ disconnects the device DURING RemoveDevice, before the method
      # returns — the signal path can drop the entry (and send its own
      # teardown envelope) first. The op reply must still be delivered, with
      # no duplicate teardown envelope (hw-observed on H60B0).
      state = bare_state()

      assert {:noreply, ^state} =
               Gatt.handle_info(
                 {:remove_result, @address, @gen, :gatt_clear_cache, self(), :ok},
                 state
               )

      assert_receive {:gatt_clear_cache, @address, true, 0}
      refute_received {:gatt_connection, _, _}
    end

    test "success for a replaced entry replies without touching the new entry" do
      # A new connect generation owns the address; the old op's reply goes
      # to its captured subscriber and the fresh entry stays intact.
      state = state(self())

      assert {:noreply, ^state} =
               Gatt.handle_info(
                 {:remove_result, @address, @gen - 1, :gatt_unpair, self(), :ok},
                 state
               )

      assert_receive {:gatt_unpair, @address, true, 0}
      refute_received {:gatt_connection, _, _}
      assert map_size(state.conns) == 1
    end
  end

  describe "pair/unpair/clear_cache casts for unknown addresses" do
    test "are dropped without crashing (no subscriber to answer)" do
      state = bare_state(%{gen_seq: 0})

      assert {:noreply, ^state} = Gatt.handle_cast({:pair, @address}, state)
      assert {:noreply, ^state} = Gatt.handle_cast({:unpair, @address}, state)
      assert {:noreply, ^state} = Gatt.handle_cast({:clear_cache, @address}, state)
    end
  end

  describe "get_services" do
    test "streams neutral Service structs then the done marker" do
      service = %Gatt.Service{uuid: 0x180F, handle: 0x0A}
      tree = %GattTree{services: [service]}
      state = state(self(), %{conns: %{@address => entry(self(), %{tree: tree})}})

      assert {:noreply, _} = Gatt.handle_cast({:get_services, @address}, state)
      assert_receive {:gatt_service, @address, ^service}
      assert_receive {:gatt_services_done, @address}
    end

    test "a not-ready link answers with the handle-0 gatt_read error" do
      state = state(self(), %{conns: %{@address => entry(self(), %{status: :connecting})}})

      assert {:noreply, _} = Gatt.handle_cast({:get_services, @address}, state)
      assert_receive {:gatt_read, @address, 0, {:error, -2}}
    end
  end

  describe "on_gatt_event seam" do
    test "every subscriber-bound event flows through the injected fun" do
      test_pid = self()
      subscriber = spawn(fn -> Process.sleep(:infinity) end)
      on_exit(fn -> Process.exit(subscriber, :kill) end)

      state =
        state(subscriber, %{
          on_gatt_event: fn sub, event -> send(test_pid, {:seam, sub, event}) end
        })

      Gatt.handle_info({:pair_result, @address, @gen, subscriber, :ok}, state)
      assert_receive {:seam, ^subscriber, {:gatt_pair, @address, true, 0}}
      # The default raw-send path must NOT have been used.
      refute_received {:gatt_pair, _, _, _}
    end
  end

  describe "on_connections_changed seam" do
    test "dropping an entry invokes the injected fun" do
      test_pid = self()

      state =
        state(self(), %{on_connections_changed: fn -> send(test_pid, :slots_changed) end})

      assert {:noreply, _} =
               Gatt.handle_info(
                 {:remove_result, @address, @gen, :gatt_unpair, self(), :ok},
                 state
               )

      assert_receive :slots_changed
    end
  end
end
