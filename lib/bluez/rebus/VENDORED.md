# Vendored: rebus

The `Bluez.Rebus.*` modules in this directory are a vendored, namespaced
copy of [rebus](https://github.com/ausimian/rebus) (a pure-Elixir D-Bus
client by Nick Gunn, MIT licensed — see `REBUS-LICENSE.md`), taken from
the [`bbangert/rebus` `dbus-service`
branch](https://github.com/bbangert/rebus/tree/dbus-service) at commit
`c6f7b64`, which adds the service-side API this library requires
(inbound method-call handling + replies, `NO_REPLY_EXPECTED` handling,
signal emission). Those additions are proposed upstream as
[ausimian/rebus#9](https://github.com/ausimian/rebus/pull/9).

## Why vendored (and namespaced)

hex.pm refuses packages with path/git dependencies, and the service-side
API isn't in a released rebus. Renaming `Rebus` → `Bluez.Rebus` makes the
copy collision-proof: module names are global on the BEAM, so a host app
may depend on any (future) hex rebus alongside this library without
conflict.

Two departures from the upstream source, beyond the rename:

- `rebus`'s OTP application (`Rebus.Application`) is not vendored; the
  `Bluez` supervisor starts the equivalent children
  (`Bluez.Rebus.SignalHandler` + the `Bluez.Rebus.ConnectionSupervisor`
  `DynamicSupervisor`) as its first two children, tying connection
  supervision into the stack's own `:rest_for_one` semantics.
- Every file carries a vendored-origin header.

## Updating

Re-vendor from the fork (or from upstream once #9 merges — at which
point prefer deleting this directory and depending on hex rebus):

    cp $REBUS/lib/rebus.ex lib/bluez/rebus.ex
    cp $REBUS/lib/rebus/{connection,decoder,encoder,message,signal_handler}.ex lib/bluez/rebus/
    # rename: \bRebus\b -> Bluez.Rebus (word-boundary; see git history)
    # re-add the origin headers; update the commit hash above
