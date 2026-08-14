defmodule PerpWalk.Reserves.Supervisor do
  @moduledoc """
  Supervises the reserves proof-generation cycle.

  Wiring:
    - `Reserves.Publishers.Nostr` — secp256k1-signed NIP-33
      replaceable events (kind 30078) published to configured relays
      over Tor. Signing key encrypted at rest via `Storage.Facade`.
    - `Vault.Generator` — timer-driven cycle (snapshot → attest →
      sign → evaluate → publish). Publishers: the Event publisher
      (PubSub for admin dashboard) and the Vault publisher wrapper
      (delegates to Nostr).

  Restart strategy is `:rest_for_one`: if Nostr crashes, the Generator
  restarts alongside it so the publishers list re-resolves cleanly.
  """

  use Supervisor

  alias PerpWalk.Federation.Facade, as: FederationFacade
  alias PerpWalk.Storage.Facade, as: StorageFacade

  @default_proof_interval_ms 10 * 60 * 1_000

  def start_link(init_arg) do
    Supervisor.start_link(__MODULE__, init_arg, name: __MODULE__)
  end

  @impl true
  def init(_init_arg) do
    proof_interval = get_config(:proof_interval_ms, @default_proof_interval_ms)

    generator_opts = [
      source: get_config(:source, PerpWalk.Reserves.Source),
      publishers: [
        PerpWalk.Reserves.Publishers.Event,
        PerpWalk.Reserves.Publishers.Vault
      ],
      attestation_collector: PerpWalk.Reserves.Attestation.Collector,
      # 2-of-3 federation: publish only when the local guardian's
      # self-attestation is joined by at least one peer's endorsement.
      # A partitioned or refusing peer now blocks publication rather
      # than allowing a self-signed "healthy" proof to ship.
      # Overridable for single-node dev/test rigs via
      # `config :perpwalk, :reserves, attestation_threshold: 1`.
      attestation_threshold: get_config(:attestation_threshold, 2),
      interval_ms: proof_interval,
      dets_file: StorageFacade.reserves_proofs_path(),
      keys_dir: StorageFacade.keys_path(),
      # Per-record AAD binds Vault-guardian-key ciphertexts to their
      # purpose so a swap between distinct at-rest secrets (e.g.
      # swapping the guardian key file with an unrelated encrypted
      # blob) triggers a tag mismatch on decrypt. The default AAD
      # `"perpwalk-v1"` reused across every at-rest record left
      # file-swap swaps undetectable.
      cipher:
        {fn plaintext -> StorageFacade.encrypt(plaintext, "perpwalk-vault-guardian-key-v1") end,
         fn ciphertext -> StorageFacade.decrypt(ciphertext, "perpwalk-vault-guardian-key-v1") end},
      halt_check: fn -> if FederationFacade.halted?(), do: :halted, else: :ok end
    ]

    generator_opts =
      case get_config(:signer, :default) do
        :default -> Keyword.put(generator_opts, :signer, &PerpWalk.Reserves.Signer.sign/2)
        signer -> Keyword.put(generator_opts, :signer, signer)
      end

    children = [
      PerpWalk.Reserves.Publishers.Nostr,
      {Vault.Generator, generator_opts}
    ]

    Supervisor.init(children, strategy: :rest_for_one, max_restarts: 3, max_seconds: 5)
  end

  defp get_config(key, default) do
    Application.get_env(:perpwalk, :reserves, [])
    |> Keyword.get(key, default)
  end
end
