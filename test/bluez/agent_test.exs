defmodule Bluez.AgentTest do
  use ExUnit.Case, async: true

  alias Bluez.Agent

  @rejected "org.bluez.Error.Rejected"
  @device "/org/bluez/hci0/dev_AA_BB_CC_DD_EE_FF"
  @other "/org/bluez/hci0/dev_11_22_33_44_55_66"

  defp expected(paths), do: Map.new(paths, &{&1, make_ref()})

  describe "decide/3 — authorization family" do
    test "confirms only device paths with an in-flight pairing we initiated" do
      expected = expected([@device])

      for member <- ["RequestConfirmation", "RequestAuthorization", "AuthorizeService"] do
        assert Agent.decide(member, [@device, 123_456], expected) == :ack
        assert Agent.decide(member, [@other, 123_456], expected) == {:reject, @rejected}
      end
    end

    test "rejects everything when no pairing is in flight" do
      for member <- ["RequestConfirmation", "RequestAuthorization", "AuthorizeService"] do
        assert Agent.decide(member, [@device], %{}) == {:reject, @rejected}
      end
    end

    test "rejects a malformed body instead of crashing" do
      expected = expected([@device])
      assert Agent.decide("RequestConfirmation", [], expected) == {:reject, @rejected}
      assert Agent.decide("RequestAuthorization", [42], expected) == {:reject, @rejected}
    end
  end

  describe "decide/3 — PIN/passkey family" do
    test "always rejects: NoInputNoOutput has no IO to satisfy them" do
      # Even for an in-flight pairing — we cannot display or collect a code.
      expected = expected([@device])

      for member <- ~w(RequestPinCode DisplayPinCode RequestPasskey DisplayPasskey) do
        assert Agent.decide(member, [@device], expected) == {:reject, @rejected}
      end
    end
  end

  describe "decide/3 — lifecycle" do
    test "acks Release and Cancel" do
      assert Agent.decide("Release", [], %{}) == :ack
      assert Agent.decide("Cancel", [], %{}) == :ack
    end

    test "unknown members fall through to UnknownMethod handling" do
      assert Agent.decide("FrobnicateDevice", [@device], %{}) == :unknown
    end
  end

  # The expect/done/expire state machine is exercised by invoking the
  # callbacks directly — the GenServer itself needs a live D-Bus connection
  # (covered by on-hardware validation, like Bluez.Client/Gatt).
  describe "expectation state machine" do
    test "expect registers a valid device path and arms an expiry" do
      state = %{expected: %{}}

      assert {:reply, :ok, state} = Agent.handle_call({:expect, @device}, self_from(), state)
      assert is_reference(state.expected[@device])
    end

    test "expect refuses paths that aren't hci0 device objects" do
      state = %{expected: %{}}

      for bad <- ["/org/bluez/hci1/dev_AA_BB_CC_DD_EE_FF", "/evil", @device <> "/service000a"] do
        assert {:reply, :ok, %{expected: expected}} =
                 Agent.handle_call({:expect, bad}, self_from(), state)

        assert expected == %{}
      end
    end

    test "pairing_done clears the expectation" do
      {:reply, :ok, state} = Agent.handle_call({:expect, @device}, self_from(), %{expected: %{}})

      assert {:noreply, %{expected: expected}} = Agent.handle_cast({:done, @device}, state)
      assert expected == %{}
    end

    test "expiry clears only the expectation it was armed for" do
      {:reply, :ok, state} = Agent.handle_call({:expect, @device}, self_from(), %{expected: %{}})
      stale_ref = state.expected[@device]

      # A re-pair re-arms with a fresh ref; the old timer must be a no-op.
      {:reply, :ok, state} = Agent.handle_call({:expect, @device}, self_from(), state)

      assert {:noreply, ^state} = Agent.handle_info({:expire, @device, stale_ref}, state)

      live_ref = state.expected[@device]

      assert {:noreply, %{expected: expected}} =
               Agent.handle_info({:expire, @device, live_ref}, state)

      assert expected == %{}
    end
  end

  defp self_from, do: {self(), make_ref()}
end
