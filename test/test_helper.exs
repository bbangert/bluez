# The vendored rebus runtime (normally the first children of the Bluez
# supervisor) — the vendored rebus tests and any connect-path tests need it.
{:ok, _} =
  Supervisor.start_link(
    [
      {Bluez.Rebus.SignalHandler, []},
      {DynamicSupervisor, strategy: :one_for_one, name: Bluez.Rebus.ConnectionSupervisor}
    ],
    strategy: :one_for_one
  )

ExUnit.start()
