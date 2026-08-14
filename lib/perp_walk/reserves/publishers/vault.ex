defmodule PerpWalk.Reserves.Publishers.Vault do
  @moduledoc false
  @behaviour Vault.Publisher

  alias PerpWalk.Reserves.Publishers.Nostr

  @impl Vault.Publisher
  def publish(%Vault.Proof{} = proof) do
    Nostr.publish_vault_proof(proof)
  end
end
