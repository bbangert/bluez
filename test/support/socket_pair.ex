defmodule Bluez.TestSocketPair do
  @moduledoc false
  # A connected pair of AF_UNIX sockets standing in for an AF_BLUETOOTH
  # HCI socket (which host CI kernels don't have): datagram boundaries
  # match HCI's one-packet-per-recv semantics, and `:socket`'s
  # select-based :nowait recv behaves the same.
  #
  # `:dgram` (the default) never reports the peer closing on recv (only a
  # send fails, with :econnrefused); `:seqpacket` reads an empty packet
  # once the peer is closed, standing in for a socket that hits EOF.

  @doc "Returns `{process_side, kernel_side}`; the caller owns both."
  def open(type \\ :dgram) do
    dir = Path.join(System.tmp_dir!(), "bluez-test-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    a = Path.join(dir, "a")
    b = Path.join(dir, "b")

    pair =
      case type do
        :dgram -> dgram(a, b)
        :seqpacket -> seqpacket(a)
      end

    # The paths are only needed to connect.
    File.rm_rf!(dir)
    pair
  end

  defp dgram(a, b) do
    {:ok, sa} = :socket.open(:local, :dgram, :default)
    {:ok, sb} = :socket.open(:local, :dgram, :default)
    :ok = :socket.bind(sa, %{family: :local, path: a})
    :ok = :socket.bind(sb, %{family: :local, path: b})
    :ok = :socket.connect(sa, %{family: :local, path: b})
    :ok = :socket.connect(sb, %{family: :local, path: a})
    {sa, sb}
  end

  defp seqpacket(path) do
    {:ok, listener} = :socket.open(:local, :seqpacket, :default)
    :ok = :socket.bind(listener, %{family: :local, path: path})
    :ok = :socket.listen(listener)
    {:ok, sa} = :socket.open(:local, :seqpacket, :default)
    :ok = :socket.connect(sa, %{family: :local, path: path})
    {:ok, sb} = :socket.accept(listener)
    :socket.close(listener)
    {sa, sb}
  end
end
