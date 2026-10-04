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

## Local patch set

Departures from the upstream source, beyond the `Rebus` → `Bluez.Rebus`
rename. Each one must be re-applied when re-vendoring:

1. **No OTP application.** `rebus`'s `Rebus.Application` is not
   vendored; the `Bluez` supervisor starts the equivalent children
   (`Bluez.Rebus.SignalHandler` + the `Bluez.Rebus.ConnectionSupervisor`
   `DynamicSupervisor`) as its first two children, tying connection
   supervision into the stack's own `:rest_for_one` semantics.
2. **Origin headers.** Every file carries a vendored-origin header.
3. **Owner-bound connections** (`rebus.ex`, `rebus/connection.ex`).
   `Bluez.Rebus.connect/2` passes `owner: self()` (overridable via the
   `:owner` opt, which must be a pid — anything else, `nil` included, is
   rejected with `{:error, {:invalid_owner, value}}`; there is no opt-out);
   `Connection.init/1` monitors the owner and the
   connection stops with `{:shutdown, :owner_down}` when it exits (the
   `owner_ref` struct field plus a `:DOWN` clause ahead of the
   signal-handler one). Upstream connections live under the shared
   `DynamicSupervisor` with no tie to the caller, so a restarted owner
   would orphan its old connection and socket. Tested in
   `test/bluez/rebus_test.exs` and `test/bluez/client_test.exs`.
   Relatedly, `Connection.init/1` runs the socket connect and AUTH
   handshake under one deadline (the documented `:timeout` opt, default
   5000 ms) and returns `{:stop, reason}` (closing the socket) on any
   failure; upstream blocks without a timeout and returns a bare
   `{:error, _}` from init/1.
4. **Credo `--strict` cleanups** (no behaviour change), made when credo
   became a CI gate:
   - aliases for nested `Bluez.Rebus.*` modules in code (doc examples
     keep the qualified names) and alphabetised alias blocks in
     `rebus.ex`, `connection.ex` and `message.ex`;
   - the two `TODO` comments in `encoder.ex` (object path / signature
     validation) reworded as plain notes, still not validated;
   - `# credo:disable-for-next-line Credo.Check.Refactor.CyclomaticComplexity`
     on `Encoder.parse_single_type/1`, `Decoder.parse_single_type/1` and
     `Message.validate_header_field/2` (flat dispatch tables);
   - in `message.ex`: `parse/1`'s tail extracted to `take_message/2`,
     `decode/1`'s body decode to `decode_body/4`, `Enum.map_join/3` in
     `generate_signature/1`, `parts != []` in `valid_interface_name?/1`,
     `if` instead of a one-branch `cond` in `valid_bus_name?/1`, an
     implicit `try` in `estimate_header_fields_size/2`, and no redundant
     final `with` clause in `validate/1`;
   - test-file tweaks (aliases, `65_535`-style literals).

   If upstream code reappears unchanged, `mix credo --strict` points at
   exactly these spots again; re-apply the same edits.

## Updating

Re-vendor from the fork (or from upstream once #9 merges — at which
point prefer deleting this directory and depending on hex rebus, after
checking whether upstream has an equivalent of patch 3):

    cp $REBUS/lib/rebus.ex lib/bluez/rebus.ex
    cp $REBUS/lib/rebus/{connection,decoder,encoder,message,signal_handler}.ex lib/bluez/rebus/
    # rename: \bRebus\b -> Bluez.Rebus (word-boundary; see git history)
    # re-add the origin headers; update the commit hash above
    # re-apply the local patch set above (patches 3 and 4), then:
    mix format && mix credo --strict && mix test

The simplest way to re-apply patches 3 and 4 is to diff the current
vendored files against the previous upstream commit (after the rename)
and apply that diff on top of the new copy.
