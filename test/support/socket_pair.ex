defmodule Bluez.TestSocketPair do
  @moduledoc false
  # A connected pair of AF_UNIX datagram sockets standing in for an
  # AF_BLUETOOTH HCI socket (which host CI kernels don't have): datagram
  # boundaries match HCI's one-packet-per-recv semantics, and `:socket`'s
  # select-based :nowait recv behaves the same.

  @doc "Returns `{process_side, kernel_side}`; the caller owns both."
  def open do
    dir = Path.join(System.tmp_dir!(), "bluez-test-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    a = Path.join(dir, "a")
    b = Path.join(dir, "b")

    {:ok, sa} = :socket.open(:local, :dgram, :default)
    {:ok, sb} = :socket.open(:local, :dgram, :default)
    :ok = :socket.bind(sa, %{family: :local, path: a})
    :ok = :socket.bind(sb, %{family: :local, path: b})
    :ok = :socket.connect(sa, %{family: :local, path: b})
    :ok = :socket.connect(sb, %{family: :local, path: a})
    # The paths are only needed to connect.
    File.rm_rf!(dir)
    {sa, sb}
  end
end
