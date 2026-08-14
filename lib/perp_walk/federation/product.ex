defmodule PerpWalk.Federation.Product do
  @moduledoc """
  Minimal `Cartel.Product` implementation for PERP WALK.

  PERP WALK uses Cartel's federation runtime (cluster, key store,
  signed transport, peer health) and signs via `Darks.Multisig` —
  Monero-native protocol. The signing flow lives in
  `PerpWalk.Federation.Signer`, not on this module.

  Cartel's product behaviour only requires `handle_mesh_message/3`;
  PERP WALK has no product-level mesh messages today, so the
  default no-op from `use Cartel.Product` is fine.
  """

  use Cartel.Product
end
