# Reviewed argus findings: each is a validated false positive or deliberate
# design, with its reason. Checked by scripts/argus_baseline.exs (see its
# header for the workflow); prefer fixing a finding over adding it here.
[
  %{
    analysis: "startup",
    file: "lib/bluez/rebus.ex",
    title: "init/1 makes a synchronous supervisor call",
    at_label: "this call blocks init until the supervisor answers",
    detail:
      "Bluez.Agent.init/1 reaches DynamicSupervisor.start_child on Bluez.Rebus.ConnectionSupervisor. Every supervisor management call is a GenServer.call into the supervisor; start_child in particular does not return until the new child's init/1 has, so those inits now run inside this one, on the tree's startup path. A child that calls back into Bluez.Agent, or into anything not yet started, deadlocks the boot; terminate_child waits for the whole shutdown of the child.",
    reason:
      "Deliberate: connecting in init/1 makes a down bus fail start_link so the :rest_for_one supervisor retries. Bluez.Rebus.ConnectionSupervisor is an earlier sibling (always up first), Connection.init/1 never calls back into its owner, and its connect/AUTH handshake is bounded by :timeout, so this cannot deadlock or hang the boot. The connection monitors its owner and closes with it."
  },
  %{
    analysis: "startup",
    file: "lib/bluez/rebus.ex",
    title: "init/1 makes a synchronous supervisor call",
    at_label: "this call blocks init until the supervisor answers",
    detail:
      "Bluez.BlueAlsa.init/1 reaches DynamicSupervisor.start_child on Bluez.Rebus.ConnectionSupervisor. Every supervisor management call is a GenServer.call into the supervisor; start_child in particular does not return until the new child's init/1 has, so those inits now run inside this one, on the tree's startup path. A child that calls back into Bluez.BlueAlsa, or into anything not yet started, deadlocks the boot; terminate_child waits for the whole shutdown of the child.",
    reason:
      "Deliberate: connecting in init/1 makes a down bus fail start_link so the :rest_for_one supervisor retries. Bluez.Rebus.ConnectionSupervisor is an earlier sibling (always up first), Connection.init/1 never calls back into its owner, and its connect/AUTH handshake is bounded by :timeout, so this cannot deadlock or hang the boot. The connection monitors its owner and closes with it."
  },
  %{
    analysis: "startup",
    file: "lib/bluez/rebus.ex",
    title: "init/1 makes a synchronous supervisor call",
    at_label: "this call blocks init until the supervisor answers",
    detail:
      "Bluez.Client.init/1 reaches DynamicSupervisor.start_child on Bluez.Rebus.ConnectionSupervisor. Every supervisor management call is a GenServer.call into the supervisor; start_child in particular does not return until the new child's init/1 has, so those inits now run inside this one, on the tree's startup path. A child that calls back into Bluez.Client, or into anything not yet started, deadlocks the boot; terminate_child waits for the whole shutdown of the child.",
    reason:
      "Deliberate: connecting in init/1 makes a down bus fail start_link so the :rest_for_one supervisor retries. Bluez.Rebus.ConnectionSupervisor is an earlier sibling (always up first), Connection.init/1 never calls back into its owner, and its connect/AUTH handshake is bounded by :timeout, so this cannot deadlock or hang the boot. The connection monitors its owner and closes with it."
  },
  %{
    analysis: "startup",
    file: "lib/bluez/rebus.ex",
    title: "init/1 makes a synchronous supervisor call",
    at_label: "this call blocks init until the supervisor answers",
    detail:
      "Bluez.Gatt.init/1 reaches DynamicSupervisor.start_child on Bluez.Rebus.ConnectionSupervisor. Every supervisor management call is a GenServer.call into the supervisor; start_child in particular does not return until the new child's init/1 has, so those inits now run inside this one, on the tree's startup path. A child that calls back into Bluez.Gatt, or into anything not yet started, deadlocks the boot; terminate_child waits for the whole shutdown of the child.",
    reason:
      "Deliberate: connecting in init/1 makes a down bus fail start_link so the :rest_for_one supervisor retries. Bluez.Rebus.ConnectionSupervisor is an earlier sibling (always up first), Connection.init/1 never calls back into its owner, and its connect/AUTH handshake is bounded by :timeout, so this cannot deadlock or hang the boot. The connection monitors its owner and closes with it."
  },
  %{
    analysis: "mailbox",
    file: "lib/bluez/rebus/connection.ex",
    title: "A message the server is sent reaches only its catch-all handle_info/2",
    at_label: "the message is sent here",
    detail:
      "Bluez.Rebus.Connection.dispatch_call/2 sends {:dbus_call, …} to Bluez.BlueAlsa, whose handle_info/2 is where it lands: no clause names it, and the catch-all that takes it does nothing with it but log it or ignore it.",
    reason:
      "False positive: Connection.dispatch_call/2 only sends {:dbus_call, _} to the pid registered via set_method_handler/2, which is only ever Bluez.Client or Bluez.Agent (both handle it). Bluez.Gatt and Bluez.BlueAlsa never register, so this path is unreachable."
  },
  %{
    analysis: "mailbox",
    file: "lib/bluez/rebus/connection.ex",
    title: "A message the server is sent reaches only its catch-all handle_info/2",
    at_label: "the message is sent here",
    detail:
      "Bluez.Rebus.Connection.dispatch_call/2 sends {:dbus_call, …} to Bluez.Gatt, whose handle_info/2 is where it lands: no clause names it, and the catch-all that takes it does nothing with it but log it or ignore it.",
    reason:
      "False positive: Connection.dispatch_call/2 only sends {:dbus_call, _} to the pid registered via set_method_handler/2, which is only ever Bluez.Client or Bluez.Agent (both handle it). Bluez.Gatt and Bluez.BlueAlsa never register, so this path is unreachable."
  }
]
