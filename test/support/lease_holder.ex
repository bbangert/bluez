defmodule Bluez.TestLeaseHolder do
  @moduledoc false
  # A process holding a Bluez.Radio lease that runs funs *as the holder* —
  # the transmitters only accept sends from the lease holder, so tests
  # drive them through one of these. Funs run one at a time, in order, as
  # a real protocol driver's sends would.

  alias Bluez.Radio

  @doc "Start a holder (linked to the caller) that acquires `index` on `radio`."
  def start(radio, index \\ 0) do
    test_pid = self()

    pid =
      spawn_link(fn ->
        {:ok, lease} = Radio.acquire(server: radio, adapter_index: index)
        send(test_pid, {:lease, self(), lease})
        loop(lease)
      end)

    receive do
      {:lease, ^pid, lease} -> {pid, lease}
    after
      1_000 -> raise "lease holder did not acquire"
    end
  end

  @doc "Run `fun.(lease)` in the holder; returns a ref for `await/2`."
  def run(holder, fun) do
    ref = make_ref()
    send(holder, {:run, self(), ref, fun})
    ref
  end

  @doc "The result of a `run/2`."
  def await(ref, timeout \\ 5_000) do
    receive do
      {^ref, result} -> result
    after
      timeout -> raise "lease holder call timed out"
    end
  end

  @doc "Run and wait."
  def call(holder, fun), do: holder |> run(fun) |> await()

  @doc "End the holder process (and with it, its lease)."
  def stop(holder) do
    ref = Process.monitor(holder)
    Process.unlink(holder)
    Process.exit(holder, :kill)

    receive do
      {:DOWN, ^ref, :process, ^holder, _} -> :ok
    end
  end

  defp loop(lease) do
    receive do
      {:run, from, ref, fun} ->
        send(from, {ref, fun.(lease)})
        loop(lease)
    end
  end
end
