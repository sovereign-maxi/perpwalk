defmodule PerpWalk.Federation.Signing.MoneroIntegrationTest do
  @moduledoc """
  Integration tests for `PerpWalk.Federation.Signing.Monero`.

  Drives the full multisig signing pipeline against stubbed Darks
  clients. The `:rpc.call` to peers is exercised against
  `Node.self()` (works locally — `:rpc` invokes the function in a
  fresh process on the target node) and `:nodedown@nohost` for the
  fallthrough scenarios.

  Verifies the anti-fragile property: one responsive peer signature
  is sufficient regardless of how many other peers are dead.
  """

  use PerpWalk.IntegrationCase

  alias PerpWalk.Federation.Payout
  alias PerpWalk.Federation.Signing.Monero
  alias PerpWalk.Markets.Position

  defmodule HappyClient do
    @moduledoc false
    def transfer(_),
      do:
        {:ok,
         %{
           tx_hash: "h",
           tx_key: "k",
           fee: 30_000_000,
           multisig_txset: "unsigned-1of3"
         }}

    def describe_transfer(_),
      do:
        {:ok,
         [
           %{
             recipients: [
               %{
                 address:
                   "4AdUndXHHZ6cfufTMvppY6JwXNouMBzSkbLYfpAV5Usx3skxNgYeYTRj5UzqtReoS44qo9mtmXCqY45DJ852K5Jv2684Rge",
                 amount: 5_000_000_000_000
               }
             ],
             fee: 30_000_000,
             amount_in: 5_030_000_000_000,
             amount_out: 5_000_000_000_000,
             change_amount: 0,
             change_address: nil,
             unlock_time: 0
           }
         ]}

    def export_multisig_info, do: {:ok, %{info: "info-#{Node.self()}"}}
    def import_multisig_info(_), do: {:ok, %{n_outputs: 3}}
    def sign_multisig(_), do: {:ok, %{tx_data_hex: "signed-2of3", tx_hash_list: ["intermediate"]}}
    def submit_multisig(_), do: {:ok, %{tx_hash_list: ["TX_FINAL_HASH"]}}
  end

  defmodule NoTxsetClient do
    @moduledoc false
    def transfer(_),
      do: {:ok, %{tx_hash: "h", tx_key: "k", fee: 0, multisig_txset: nil}}

    def export_multisig_info, do: {:ok, %{info: "x"}}
    def import_multisig_info(_), do: {:ok, %{n_outputs: 0}}
    def sign_multisig(_), do: {:error, :unreachable}
    def submit_multisig(_), do: {:error, :unreachable}
  end

  defmodule ExportFailClient do
    @moduledoc false
    def transfer(_), do: {:ok, %{tx_hash: "h", tx_key: "k", fee: 0, multisig_txset: nil}}
    def export_multisig_info, do: {:error, :wallet_unreachable}
    def import_multisig_info(_), do: {:error, :unreachable}
    def sign_multisig(_), do: {:error, :unreachable}
    def submit_multisig(_), do: {:error, :unreachable}
  end

  defmodule SubmitFailClient do
    @moduledoc false
    def transfer(_),
      do:
        {:ok,
         %{
           tx_hash: "h",
           tx_key: "k",
           fee: 30_000_000,
           multisig_txset: "unsigned-1of3"
         }}

    def describe_transfer(_),
      do:
        {:ok,
         [
           %{
             recipients: [
               %{
                 address:
                   "4AdUndXHHZ6cfufTMvppY6JwXNouMBzSkbLYfpAV5Usx3skxNgYeYTRj5UzqtReoS44qo9mtmXCqY45DJ852K5Jv2684Rge",
                 amount: 5_000_000_000_000
               }
             ],
             fee: 30_000_000,
             amount_in: 5_030_000_000_000,
             amount_out: 5_000_000_000_000,
             change_amount: 0,
             change_address: nil,
             unlock_time: 0
           }
         ]}

    def export_multisig_info, do: {:ok, %{info: "info"}}
    def import_multisig_info(_), do: {:ok, %{n_outputs: 3}}
    def sign_multisig(_), do: {:ok, %{tx_data_hex: "signed-2of3", tx_hash_list: ["intermediate"]}}
    def submit_multisig(_), do: {:error, :double_spend}
  end

  setup do
    on_exit(fn ->
      Application.delete_env(:darks, :client)
      Application.put_env(:perpwalk, :federation_signer, tick_interval_ms: 3_600_000)
      Application.delete_env(:perpwalk, :federation)
    end)

    # Monero.sign goes through Peer.sign → Throttle.reserve. Without
    # this reset, accumulated reservations from prior integration tests
    # in the run can push the projected outflow past the 200 XMR /
    # 21600s cap, causing legitimate sign attempts to be policy-rejected
    # as if the leader were compromised. Same pattern as peer_test's
    # file-level setup.
    PerpWalk.Federation.Signing.Peer.Throttle.reset()

    :ok
  end

  defp build_request(amount \\ 5_000_000_000_000) do
    pos = %Position{
      id: "pos-#{System.unique_integer([:positive])}",
      market_id: "mkt",
      account_id: "acct",
      side: :yes,
      contracts: 5,
      amount_paid: amount,
      spread_piconeros: 0,
      status: :settled_winner,
      created_at: DateTime.utc_now(),
      settled_at: DateTime.utc_now()
    }

    # Destination matches the address the HappyClient/SubmitFailClient
    # stubs return from describe_transfer — required by C2's ledger
    # binding: the local :rules_passed payout must match the tx's
    # described recipient. In production this alignment is guaranteed
    # by Darks.transfer/1 building the tx from the request's destination.
    Payout.new(
      pos,
      amount,
      "4AdUndXHHZ6cfufTMvppY6JwXNouMBzSkbLYfpAV5Usx3skxNgYeYTRj5UzqtReoS44qo9mtmXCqY45DJ852K5Jv2684Rge"
    )
  end

  describe "sign/1 — happy path" do
    setup do
      Application.put_env(:darks, :client, HappyClient)
      :ok
    end

    test "returns the on-chain txid when a peer signs and the leader submits" do
      Application.put_env(:perpwalk, :federation, peer_nodes_override: [Node.self()])

      request = build_request()
      # Seed for C2 ledger binding: peer.sign only co-signs if a
      # matching :rules_passed payout is in the local store.
      :ok = seed_rules_passed(request)
      assert {:ok, "TX_FINAL_HASH"} = Monero.sign(request)
    end
  end

  describe "sign/1 — anti-fragile peer fallthrough" do
    setup do
      Application.put_env(:darks, :client, HappyClient)
      :ok
    end

    test "first peer dead, second peer signs — still succeeds" do
      Application.put_env(:perpwalk, :federation, peer_nodes_override: [:nodedown@nohost, Node.self()])

      request = build_request()
      :ok = seed_rules_passed(request)
      assert {:ok, "TX_FINAL_HASH"} = Monero.sign(request)
    end

    test "every peer unreachable returns no_peer_signature_available" do
      Application.put_env(:perpwalk, :federation, peer_nodes_override: [:nodedown_a@nohost, :nodedown_b@nohost])

      request = build_request()
      assert {:error, :no_peer_signature_available} = Monero.sign(request)
    end
  end

  describe "sign/1 — failure surfaces" do
    test "wallet unreachable on export surfaces as :export_failed" do
      Application.put_env(:darks, :client, ExportFailClient)
      Application.put_env(:perpwalk, :federation, peer_nodes_override: [Node.self()])

      request = build_request()
      assert {:error, {:export_failed, :wallet_unreachable}} = Monero.sign(request)
    end

    test "non-multisig wallet returns :no_multisig_txset_returned" do
      Application.put_env(:darks, :client, NoTxsetClient)
      Application.put_env(:perpwalk, :federation, peer_nodes_override: [Node.self()])

      request = build_request()
      assert {:error, :no_multisig_txset_returned} = Monero.sign(request)
    end

    test "submit failure (e.g. double-spend) is classified as ambiguous" do
      # Unrecognised submit errors are wrapped as `:submit_ambiguous`
      # by default. `:double_spend` looks like a pre-relay rejection
      # (daemon refused, we never broadcast) but on a RETRY of an
      # earlier ambiguous submit the "conflicting tx" that triggered
      # this is likely OUR OWN prior submit that DID land. Force
      # operator reconciliation rather than blindly re-signing.
      Application.put_env(:darks, :client, SubmitFailClient)
      Application.put_env(:perpwalk, :federation, peer_nodes_override: [Node.self()])

      request = build_request()
      :ok = seed_rules_passed(request)
      assert {:error, {:submit_ambiguous, :double_spend}} = Monero.sign(request)
    end
  end

  describe "sign/1 — submit-error classification" do
    # Verifies each known error shape lands on the correct side of the
    # ambiguous / definitive line. Uses one-off client modules that
    # short-circuit at submit_multisig with the shape under test; the
    # earlier pipeline stages (export/import/sign/describe) are stubbed
    # to a happy no-op so `submit/1` is reachable.

    defmodule SubmitTimeoutClient do
      @moduledoc false
      def transfer(_),
        do:
          {:ok,
           %{
             tx_hash: "h",
             tx_key: "k",
             fee: 30_000_000,
             multisig_txset: "unsigned"
           }}

      def describe_transfer(_),
        do:
          {:ok,
           [
             %{
               recipients: [
                 %{
                   address:
                     "4AdUndXHHZ6cfufTMvppY6JwXNouMBzSkbLYfpAV5Usx3skxNgYeYTRj5UzqtReoS44qo9mtmXCqY45DJ852K5Jv2684Rge",
                   amount: 5_000_000_000_000
                 }
               ],
               fee: 30_000_000,
               amount_in: 5_030_000_000_000,
               amount_out: 5_000_000_000_000,
               change_amount: 0,
               change_address: nil,
               unlock_time: 0
             }
           ]}

      def export_multisig_info, do: {:ok, %{info: "info"}}
      def import_multisig_info(_), do: {:ok, %{n_outputs: 3}}
      def sign_multisig(_), do: {:ok, %{tx_data_hex: "signed", tx_hash_list: ["intermediate"]}}
      def submit_multisig(_), do: {:error, {:connection_error, :timeout}}
    end

    defmodule SubmitHttp502Client do
      @moduledoc false
      def transfer(_), do: SubmitTimeoutClient.transfer(nil)
      def describe_transfer(_), do: SubmitTimeoutClient.describe_transfer(nil)
      def export_multisig_info, do: SubmitTimeoutClient.export_multisig_info()
      def import_multisig_info(_), do: SubmitTimeoutClient.import_multisig_info(nil)
      def sign_multisig(_), do: SubmitTimeoutClient.sign_multisig(nil)
      def submit_multisig(_), do: {:error, {:http_error, 502}}
    end

    defmodule SubmitHttp400Client do
      @moduledoc false
      def transfer(_), do: SubmitTimeoutClient.transfer(nil)
      def describe_transfer(_), do: SubmitTimeoutClient.describe_transfer(nil)
      def export_multisig_info, do: SubmitTimeoutClient.export_multisig_info()
      def import_multisig_info(_), do: SubmitTimeoutClient.import_multisig_info(nil)
      def sign_multisig(_), do: SubmitTimeoutClient.sign_multisig(nil)
      def submit_multisig(_), do: {:error, {:http_error, 400}}
    end

    defmodule SubmitAuthFailedClient do
      @moduledoc false
      def transfer(_), do: SubmitTimeoutClient.transfer(nil)
      def describe_transfer(_), do: SubmitTimeoutClient.describe_transfer(nil)
      def export_multisig_info, do: SubmitTimeoutClient.export_multisig_info()
      def import_multisig_info(_), do: SubmitTimeoutClient.import_multisig_info(nil)
      def sign_multisig(_), do: SubmitTimeoutClient.sign_multisig(nil)
      def submit_multisig(_), do: {:error, :auth_failed}
    end

    defmodule SubmitEconnRefusedClient do
      @moduledoc false
      def transfer(_), do: SubmitTimeoutClient.transfer(nil)
      def describe_transfer(_), do: SubmitTimeoutClient.describe_transfer(nil)
      def export_multisig_info, do: SubmitTimeoutClient.export_multisig_info()
      def import_multisig_info(_), do: SubmitTimeoutClient.import_multisig_info(nil)
      def sign_multisig(_), do: SubmitTimeoutClient.sign_multisig(nil)
      def submit_multisig(_), do: {:error, {:connection_error, :econnrefused}}
    end

    defmodule SubmitNoTxidClient do
      @moduledoc false
      def transfer(_), do: SubmitTimeoutClient.transfer(nil)
      def describe_transfer(_), do: SubmitTimeoutClient.describe_transfer(nil)
      def export_multisig_info, do: SubmitTimeoutClient.export_multisig_info()
      def import_multisig_info(_), do: SubmitTimeoutClient.import_multisig_info(nil)
      def sign_multisig(_), do: SubmitTimeoutClient.sign_multisig(nil)
      def submit_multisig(_), do: {:ok, %{tx_hash_list: []}}
    end

    test "timeout → {:submit_ambiguous, {:connection_error, :timeout}}" do
      Application.put_env(:darks, :client, SubmitTimeoutClient)
      Application.put_env(:perpwalk, :federation, peer_nodes_override: [Node.self()])

      request = build_request()
      :ok = seed_rules_passed(request)

      assert {:error, {:submit_ambiguous, {:connection_error, :timeout}}} =
               Monero.sign(request)
    end

    test "5xx → ambiguous (wallet may have relayed before erroring)" do
      Application.put_env(:darks, :client, SubmitHttp502Client)
      Application.put_env(:perpwalk, :federation, peer_nodes_override: [Node.self()])

      request = build_request()
      :ok = seed_rules_passed(request)

      assert {:error, {:submit_ambiguous, {:http_error, 502}}} = Monero.sign(request)
    end

    test "no txid returned → ambiguous" do
      Application.put_env(:darks, :client, SubmitNoTxidClient)
      Application.put_env(:perpwalk, :federation, peer_nodes_override: [Node.self()])

      request = build_request()
      :ok = seed_rules_passed(request)

      assert {:error, {:submit_ambiguous, :no_txid_returned}} = Monero.sign(request)
    end

    test "4xx → definitive (wallet rejected before relay)" do
      Application.put_env(:darks, :client, SubmitHttp400Client)
      Application.put_env(:perpwalk, :federation, peer_nodes_override: [Node.self()])

      request = build_request()
      :ok = seed_rules_passed(request)

      assert {:error, {:http_error, 400}} = Monero.sign(request)
    end

    test ":auth_failed → definitive (pre-send auth failure)" do
      Application.put_env(:darks, :client, SubmitAuthFailedClient)
      Application.put_env(:perpwalk, :federation, peer_nodes_override: [Node.self()])

      request = build_request()
      :ok = seed_rules_passed(request)

      assert {:error, :auth_failed} = Monero.sign(request)
    end

    test "econnrefused → definitive (TCP never established)" do
      Application.put_env(:darks, :client, SubmitEconnRefusedClient)
      Application.put_env(:perpwalk, :federation, peer_nodes_override: [Node.self()])

      request = build_request()
      :ok = seed_rules_passed(request)

      assert {:error, {:connection_error, :econnrefused}} = Monero.sign(request)
    end
  end

  # Puts the request in the Federation store in :rules_passed status
  # so the peer.sign ledger-binding gate (C2) accepts the tx as
  # matching a locally-known payout obligation.
  defp seed_rules_passed(%Payout{} = request) do
    PerpWalk.Federation.Store.put_payout(%{request | status: :rules_passed})
  end
end
