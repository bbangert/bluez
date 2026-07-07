defmodule Bluez.DeviceCacheTest do
  use ExUnit.Case, async: true

  alias Bluez.DeviceCache

  @props %{"Address" => "11:22:33:44:55:66", "ManufacturerData" => %{0x004C => <<0x01>>}}
  @heartbeat 10_000

  describe "emit?/5" do
    test "first sight (no previous payload) emits" do
      assert DeviceCache.emit?(<<1>>, nil, nil, 0, @heartbeat)
    end

    test "payload change emits" do
      assert DeviceCache.emit?(<<2>>, <<1>>, 0, 100, @heartbeat)
    end

    test "unchanged payload within the heartbeat does not emit" do
      refute DeviceCache.emit?(<<1>>, <<1>>, 0, 5_000, @heartbeat)
    end

    test "unchanged payload after the heartbeat emits" do
      assert DeviceCache.emit?(<<1>>, <<1>>, 0, 10_000, @heartbeat)
    end

    test "is total: last_raw present but last_emit nil emits (no arithmetic on nil)" do
      assert DeviceCache.emit?(<<1>>, <<1>>, nil, 5_000, @heartbeat)
    end
  end

  describe "upsert/4" do
    test "emits on first sight, suppresses an identical update, re-emits after heartbeat" do
      cache = DeviceCache.new()

      {cache, adverts} = DeviceCache.upsert(cache, "/dev/a", @props, 0)
      assert [%{address: 0x112233445566}] = adverts

      {cache, adverts} = DeviceCache.upsert(cache, "/dev/a", @props, 5_000)
      assert adverts == []

      {_cache, adverts} = DeviceCache.upsert(cache, "/dev/a", @props, 11_000)
      assert [%{}] = adverts
    end

    test "emits immediately when the advertising payload changes" do
      cache = DeviceCache.new()
      {cache, _} = DeviceCache.upsert(cache, "/dev/a", @props, 0)

      changed = Map.put(@props, "ManufacturerData", %{0x004C => <<0x02>>})
      {_cache, adverts} = DeviceCache.upsert(cache, "/dev/a", changed, 1_000)
      assert [%{}] = adverts
    end

    test "skips devices whose props don't reconstruct (no address)" do
      {cache, adverts} = DeviceCache.upsert(DeviceCache.new(), "/dev/x", %{"RSSI" => -50}, 0)
      assert adverts == []
      # still cached (so we don't re-reconstruct churn), but emitted nothing
      assert DeviceCache.size(cache) == 1
    end

    test "caps the cache (LRU by last_seen), evicting the oldest" do
      cache =
        Enum.reduce(0..600, DeviceCache.new(), fn i, acc ->
          {acc, _} = DeviceCache.upsert(acc, "/dev/#{i}", @props, i)
          acc
        end)

      assert DeviceCache.size(cache) == 512
      # oldest (last_seen 0) evicted, newest retained
      refute Map.has_key?(cache.devices, "/dev/0")
      assert Map.has_key?(cache.devices, "/dev/600")
    end
  end

  describe "remove/2" do
    test "drops a device path" do
      {cache, _} = DeviceCache.upsert(DeviceCache.new(), "/dev/a", @props, 0)
      assert DeviceCache.size(cache) == 1
      assert DeviceCache.size(DeviceCache.remove(cache, "/dev/a")) == 0
    end
  end

  describe "seen_within/3" do
    test "counts distinct devices inside the window, boundary inclusive" do
      cache = DeviceCache.new()
      {cache, _} = DeviceCache.upsert(cache, "/dev/old", @props, 0)
      {cache, _} = DeviceCache.upsert(cache, "/dev/edge", @props, 5_000)
      {cache, _} = DeviceCache.upsert(cache, "/dev/fresh", @props, 9_000)

      now = 10_000
      assert DeviceCache.seen_within(cache, now, 5_000) == 2
      assert DeviceCache.seen_within(cache, now, 500) == 0
      assert DeviceCache.seen_within(cache, now, 60_000) == 3
    end

    test "re-seeing a device refreshes its window membership without double-counting" do
      cache = DeviceCache.new()
      {cache, _} = DeviceCache.upsert(cache, "/dev/a", @props, 0)
      {cache, _} = DeviceCache.upsert(cache, "/dev/a", @props, 8_000)

      assert DeviceCache.seen_within(cache, 10_000, 5_000) == 1
    end

    test "empty cache → 0" do
      assert DeviceCache.seen_within(DeviceCache.new(), 1_000, 1_000) == 0
    end
  end
end
