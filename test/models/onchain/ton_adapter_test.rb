# frozen_string_literal: true

require "test_helper"

class Onchain::TonAdapterTest < ActiveSupport::TestCase
  ADDRESS = "0:#{"1" * 64}"
  OTHER = "0:#{"2" * 64}"
  USDT = Onchain::TonAdapter::TRUSTED_JETTONS.keys.sole
  UNKNOWN = "0:#{"3" * 64}"
  FRIENDLY = "EQCxE6mUtQJKFnGfaROTKOt1lZbDiiX1kCixRv7Nw2Id_sDs"

  setup do
    @provider = mock("toncenter")
    Provider::Toncenter.stubs(:new).returns(@provider)
    @adapter = Onchain::TonAdapter.new(credentials: { toncenter_api_key: "key", sync_start_date: Date.new(2026, 1, 2) })
  end

  test "accepts TON forms and canonicalizes them without a request" do
    assert @adapter.valid_address?(FRIENDLY)
    assert_equal USDT, @adapter.canonical_address(FRIENDLY)
    assert_not @adapter.valid_address?("nope")
  end

  test "builds GRAM and Jetton assets and signed finalized movements" do
    stub_account(balance: "2500000000")
    stub_wallets(
      rows: [
        { "jetton" => USDT, "balance" => "1250000" },
        { "jetton" => UNKNOWN, "balance" => "3000" }
      ],
      metadata: {
        UNKNOWN => { "token_info" => [
          { "type" => "jetton_masters", "symbol" => "JET", "name" => "Example", "valid" => true,
            "is_scam" => false, "extra" => { "decimals" => 3 } }
        ] }
      }
    )
    start_utime = Date.new(2026, 1, 2).to_time.to_i
    @provider.expects(:ton_transfers).with(ADDRESS, start_utime: start_utime, max_rows: history_budget).returns(page([
      { "action_id" => "in", "success" => true, "finality" => "finalized", "end_utime" => 1_770_000_000,
        "details" => { "source" => OTHER, "destination" => ADDRESS, "value" => "500000000" } },
      { "action_id" => "failed", "success" => false, "finality" => "finalized", "end_utime" => 1_770_000_001,
        "details" => { "source" => OTHER, "destination" => ADDRESS, "value" => "900000000" } }
    ]))
    @provider.expects(:jetton_transfers).with(ADDRESS, start_utime: start_utime, max_rows: history_budget).returns(page([
      { "transaction_hash" => "hash", "transaction_lt" => "5", "transaction_now" => 1_770_000_002,
        "jetton_master" => USDT, "source" => ADDRESS, "destination" => OTHER, "amount" => "250000",
        "transaction_aborted" => false }
    ]))

    snapshot = @adapter.fetch_snapshot(ADDRESS)

    assert_equal BigDecimal("2.5"), snapshot.find_asset(kind: "native").quantity
    usdt = snapshot.find_asset(kind: "jetton", contract: USDT)
    assert_equal BigDecimal("1.25"), usdt.quantity
    assert usdt.notable?
    jet = snapshot.find_asset(kind: "jetton", contract: UNKNOWN)
    assert_match(/\AJETTON:/, jet.symbol)
    assert_equal "Example (unverified)", jet.name
    assert_not jet.notable?
    assert_equal [ BigDecimal("0.5"), BigDecimal("-0.25") ], snapshot.movements.sort_by(&:timestamp).map(&:amount)
    assert_not snapshot.history_truncated?
  end

  test "keeps balances when history fails and flags invalid token precision" do
    stub_account(balance: "0")
    stub_wallets(
      rows: [ { "jetton" => UNKNOWN, "balance" => "1" } ],
      metadata: { UNKNOWN => { "token_info" => [
        { "type" => "jetton_masters", "valid" => true, "extra" => { "decimals" => "30" } }
      ] } }
    )
    @provider.stubs(:ton_transfers).raises(Provider::Toncenter::ApiError, "down")
    @provider.stubs(:jetton_transfers).raises(Provider::Toncenter::ApiError, "down")

    snapshot = @adapter.fetch_snapshot(ADDRESS)

    assert_equal [ "GRAM" ], snapshot.assets.map(&:symbol)
    assert snapshot.assets_truncated?
    assert snapshot.history_truncated?
  end

  test "reports an account-state timeout as a chain outage" do
    @provider.stubs(:account_state).raises(Provider::Toncenter::ApiError, "down")

    assert_raises Onchain::Chains::UnreachableError do
      @adapter.fetch_snapshot(ADDRESS)
    end
  end

  private
    def page(rows, metadata: {}, truncated: false)
      Provider::Toncenter::Page.new(rows: rows, metadata: metadata, truncated: truncated)
    end

    def stub_account(balance:)
      @provider.stubs(:account_state).with(ADDRESS).returns({ "balance" => balance })
    end

    def stub_wallets(rows:, metadata: {})
      @provider.stubs(:jetton_wallets).with(ADDRESS, max_rows: Onchain::AssetBudget.tokens)
        .returns(page(rows, metadata: metadata))
    end

    def history_budget
      Onchain::HistoryBudget.pages * Onchain::HistoryBudget::PAGE_SIZE
    end
end
