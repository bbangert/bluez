defmodule Bluez.Gatt.Service do
  @moduledoc """
  A GATT primary/secondary service discovered on a connected device —
  the neutral shape `Bluez.GattTree` builds
  and `Bluez.Gatt` emits in `{:gatt_service, address, service}`
  events. Hosts translate it to their own wire shape in the `on_gatt_event:`
  fun.

  `uuid` is a 16-bit integer for Bluetooth-SIG base UUIDs, else the full
  16-byte binary (see `Bluez.GattTree.to_uuid/1`).
  """

  alias Bluez.Gatt.Characteristic

  @type uuid :: non_neg_integer() | <<_::128>>

  @type t :: %__MODULE__{
          uuid: uuid(),
          handle: non_neg_integer(),
          characteristics: [Characteristic.t()]
        }

  @enforce_keys [:uuid, :handle]
  defstruct [:uuid, :handle, characteristics: []]
end
