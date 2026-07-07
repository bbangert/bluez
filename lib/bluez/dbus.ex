defmodule Bluez.DBus do
  @moduledoc """
  Shared helpers for outbound D-Bus method calls to `org.bluez` over a
  `rebus` connection, used by `Bluez.Client` (passive
  scanning) and `Bluez.Gatt` (active connections).

  The rebus connection correlates in-flight calls by serial and replies via
  `GenServer.reply/2`, so concurrent calls on one connection don't
  serialize — a slow `Device1.Connect` does not block a `ReadValue` to
  another device. The timeout here is purely the caller's patience
  (`GenServer.call/3` exit, surfaced as `{:error, {:exit, ...}}`).

  Callers beware: these block the calling process for up to `timeout`.
  Call from a `Task` (never from a GenServer's own loop) for anything
  that can be slow — `Connect` can take ~25 s, GATT reads up to the ATT
  timeout.
  """

  require Logger

  @bluez "org.bluez"
  @om_iface "org.freedesktop.DBus.ObjectManager"

  # Bluez.Rebus.Connection.send/2 uses GenServer.call's 5s default; keep parity.
  @default_timeout 5_000

  @doc """
  Synchronous method call to `org.bluez` → `{:ok, reply_body} | {:error, reason}`.

  Pass `signature: ""` for argument-less members. Errors are normalized:
  a D-Bus error reply yields `{:error, error_name}`, a raise yields
  `{:error, exception}`, and a `GenServer.call` timeout / dead connection
  yields `{:error, {:exit, reason}}` (exits are caught, not propagated).
  """
  @spec call(pid(), String.t(), String.t(), String.t(), String.t(), list(), timeout()) ::
          {:ok, list()} | {:error, term()}
  def call(conn, path, interface, member, signature, body, timeout \\ @default_timeout) do
    call_to(conn, @bluez, path, interface, member, signature, body, timeout)
  end

  @doc """
  Like `call/7` but to an arbitrary bus name. `call/7` is this with
  `destination: "org.bluez"`; `Bluez.BlueAlsa` uses it to reach
  `org.bluealsa` over the same kind of connection. Same error normalization.
  """
  @spec call_to(
          pid(),
          String.t(),
          String.t(),
          String.t(),
          String.t(),
          String.t(),
          list(),
          timeout()
        ) ::
          {:ok, list()} | {:error, term()}
  def call_to(
        conn,
        destination,
        path,
        interface,
        member,
        signature,
        body,
        timeout \\ @default_timeout
      ) do
    opts = [
      destination: destination,
      path: path,
      interface: interface,
      member: member,
      body: body
    ]

    opts = if signature == "", do: opts, else: Keyword.put(opts, :signature, signature)
    msg = Bluez.Rebus.Message.new!(:method_call, opts)

    case GenServer.call(conn, {:send, msg}, timeout) do
      %Bluez.Rebus.Message{type: :method_return, body: reply_body} ->
        {:ok, reply_body}

      %Bluez.Rebus.Message{type: :error, header_fields: hf, body: eb} ->
        Logger.warning("Bluez.DBus: #{member} error #{inspect(hf[:error_name])} #{inspect(eb)}")
        {:error, hf[:error_name]}
    end
  rescue
    e ->
      Logger.warning("Bluez.DBus: #{member} raised #{inspect(e)}")
      {:error, e}
  catch
    :exit, reason ->
      Logger.warning("Bluez.DBus: #{member} exited #{inspect(reason)}")
      {:error, {:exit, reason}}
  end

  @doc """
  Install a bus-side match rule so the daemon routes matching signals to
  this connection (rebus installs none by itself).
  """
  @spec add_match(pid(), String.t()) :: term()
  def add_match(conn, rule) do
    Bluez.Rebus.Connection.send(
      conn,
      Bluez.Rebus.Message.new!(:method_call,
        destination: "org.freedesktop.DBus",
        path: "/org/freedesktop/DBus",
        interface: "org.freedesktop.DBus",
        member: "AddMatch",
        signature: "s",
        body: [rule]
      )
    )
  end

  @doc "Fetch org.bluez's full object tree (`ObjectManager.GetManagedObjects`)."
  @spec get_managed_objects(pid(), timeout()) :: {:ok, list()} | {:error, term()}
  def get_managed_objects(conn, timeout \\ @default_timeout) do
    case call(conn, "/", @om_iface, "GetManagedObjects", "", [], timeout) do
      {:ok, [objects]} -> {:ok, objects}
      {:ok, other} -> {:error, {:unexpected_reply, other}}
      other -> other
    end
  end
end
