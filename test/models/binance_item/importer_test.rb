# frozen_string_literal: true

require "test_helper"

class BinanceItem::ImporterTest < ActiveSupport::TestCase
  setup do
    @family = families(:dylan_family)
    @item = BinanceItem.create!(family: @family, name: "B", api_key: "k", api_secret: "s")
    @provider = mock
    @provider.stubs(:get_spot_price).returns("50000.0")

    stub_spot_result([ { symbol: "BTC", free: "1.0", locked: "0.0", total: "1.0" } ])
    stub_funding_result([])
    stub_margin_result([])
    stub_isolated_margin_result([])
    stub_earn_result([])
    stub_yield_asset_result([])
    stub_futures_result([])
    stub_coin_futures_result([])
    stub_options_result([])
    stub_portfolio_margin_result(error: "not a portfolio margin account")
  end

  test "creates a binance_account of type combined" do
    assert_difference "@item.binance_accounts.count", 1 do
      BinanceItem::Importer.new(@item, binance_provider: @provider).import
    end

    ba = @item.binance_accounts.first
    assert_equal "combined", ba.account_type
    assert_equal "USD", ba.currency
  end

  test "calculates combined USD balance" do
    @provider.stubs(:get_spot_price).with("BTCUSDT").returns("50000.0")

    BinanceItem::Importer.new(@item, binance_provider: @provider).import

    ba = @item.binance_accounts.first
    assert_in_delta 50000.0, ba.current_balance.to_f, 0.01
  end

  test "stablecoins counted at 1.0 without API call" do
    stub_spot_result([ { symbol: "USDT", free: "1000.0", locked: "0.0", total: "1000.0" } ])

    @provider.expects(:get_spot_price).never

    BinanceItem::Importer.new(@item, binance_provider: @provider).import

    ba = @item.binance_accounts.first
    assert_in_delta 1000.0, ba.current_balance.to_f, 0.01
  end

  test "omits current balances below one USD" do
    stub_spot_result([
      { symbol: "USDT", free: "0.99", locked: "0", total: "0.99" },
      { symbol: "USDC", free: "1.00", locked: "0", total: "1.00" }
    ])

    BinanceItem::Importer.new(@item, binance_provider: @provider).import

    assert_equal [ "USDC" ], payload_symbols
    assert_equal BigDecimal("1"), @item.binance_accounts.first.current_balance
    assert_equal "USDT", @item.binance_accounts.first.raw_payload["dust_omitted"].first["symbol"]
  end

  test "preserves an asset when its USD price is temporarily unavailable" do
    @provider.stubs(:get_spot_price).returns(nil)

    BinanceItem::Importer.new(@item, binance_provider: @provider).import

    asset = payload_assets.first
    assert_equal "BTC", asset["symbol"]
    assert_nil asset["usd_value"]
    assert_equal "unavailable", asset["price_status"]
    assert_equal [ { "symbol" => "BTC", "source" => "spot" } ],
                 @item.binance_accounts.first.raw_payload["unpriced_assets"]
  end

  test "retains the last successful quote when current pricing is unavailable" do
    BinanceItem::Importer.new(@item, binance_provider: @provider).import

    @provider.stubs(:get_spot_price).returns(nil)
    BinanceItem::Importer.new(@item, binance_provider: @provider).import

    asset = payload_assets.first
    assert_equal "50000.0", asset["usd_price"]
    assert_equal "50000.0", asset["usd_value"]
    assert_equal "stale", asset["price_status"]
    assert_empty @item.binance_accounts.first.raw_payload["unpriced_assets"]
  end

  test "rate limiting aborts the sync instead of probing more endpoints" do
    BinanceItem::SpotImporter.any_instance.stubs(:import).raises(Provider::Binance::RateLimitError, "slow down")
    BinanceItem::FundingImporter.any_instance.expects(:import).never

    assert_raises Provider::Binance::RateLimitError do
      BinanceItem::Importer.new(@item, binance_provider: @provider).import
    end
  end

  test "portfolio margin replaces overlapping standalone sources" do
    stub_portfolio_margin_result(
      assets: [ { symbol: "USDT", free: "50", locked: "0", total: "50" } ]
    )

    BinanceItem::Importer.new(@item, binance_provider: @provider).import

    raw = @item.binance_accounts.first.raw_payload
    assert raw.key?("portfolio_margin")
    refute raw.key?("margin")
    refute raw.key?("futures")
    refute raw.key?("coin_futures")
    refute raw.key?("options")
  end

  test "skips BinanceAccount creation when all sources empty" do
    stub_spot_result([])
    stub_funding_result([])
    stub_margin_result([])
    stub_isolated_margin_result([])
    stub_earn_result([])
    stub_yield_asset_result([])
    stub_futures_result([])
    stub_coin_futures_result([])
    stub_options_result([])

    assert_no_difference "@item.binance_accounts.count" do
      BinanceItem::Importer.new(@item, binance_provider: @provider).import
    end
  end

  # Each sub-importer swallows its own error and answers with an empty asset
  # list, so a total outage reached the upsert looking exactly like an emptied
  # wallet. It reported success, left the previous payload in place, and the
  # holdings processor re-imported that payload as today's holdings — so an
  # asset already sold came back on every sync.
  test "a total outage is not an empty wallet" do
    stub_failed_result("spot")
    stub_failed_result("funding")
    stub_failed_result("margin")
    stub_failed_result("isolated_margin")
    stub_failed_result("earn")
    stub_failed_result("yield_assets")
    stub_failed_result("futures")
    stub_failed_result("coin_futures")
    stub_failed_result("options")

    assert_raises BinanceItem::Importer::AllRequestsFailed do
      BinanceItem::Importer.new(@item, binance_provider: @provider).import
    end
  end

  # A source that failed tells us nothing about what it holds. Writing only the
  # sources that answered would hand the holdings processor a list missing every
  # margin position, and it removes what is missing — so a transient error, or a
  # key without margin permission, would delete live positions.
  test "a source that failed keeps its last known assets" do
    stub_margin_result([ { symbol: "ETH", free: "2.0", locked: "0.0", total: "2.0" } ])
    BinanceItem::Importer.new(@item, binance_provider: @provider).import
    assert_equal [ "BTC", "ETH" ], payload_symbols.sort

    stub_failed_result("margin")
    BinanceItem::Importer.new(@item, binance_provider: @provider).import

    assert_equal [ "BTC", "ETH" ], payload_symbols.sort,
                 "the unavailable source's positions were dropped"
    assert_equal "margin", payload_assets.find { |a| a["symbol"] == "ETH" }["source"]
  end

  # Carried only while the source is silent: once it answers again, what it says
  # is what stands, including an asset it no longer reports.
  test "a source that answers again overrides what was carried" do
    stub_margin_result([ { symbol: "ETH", free: "2.0", locked: "0.0", total: "2.0" } ])
    BinanceItem::Importer.new(@item, binance_provider: @provider).import

    stub_failed_result("margin")
    BinanceItem::Importer.new(@item, binance_provider: @provider).import
    assert_includes payload_symbols, "ETH"

    stub_margin_result([])
    BinanceItem::Importer.new(@item, binance_provider: @provider).import

    assert_equal [ "BTC" ], payload_symbols, "the carried asset outlived the source coming back"
  end

  # A partial failure returns normally, so it never reaches the rescue that logs
  # a failed import. Support would otherwise have no record that part of the
  # wallet went unread on a sync that reported success.
  test "a source that failed is recorded against the connection" do
    stub_failed_result("margin")

    assert_difference "DebugLogEntry.count", 1 do
      BinanceItem::Importer.new(@item, binance_provider: @provider).import
    end

    entry = DebugLogEntry.order(:created_at).last
    assert_equal "binance", entry.provider_key
    assert_equal [ "margin" ], entry.metadata["unavailable_sources"]
    assert_equal @family, entry.family
  end

  # One call still answering means the picture is trustworthy, even if it is
  # only part of one. Only a complete outage tells us nothing.
  test "a partial outage still records what did answer" do
    stub_failed_result("margin")
    stub_failed_result("earn")
    stub_failed_result("futures")

    BinanceItem::Importer.new(@item, binance_provider: @provider).import

    assert_equal [ "BTC" ], @item.binance_accounts.first.raw_payload["assets"].map { |a| a["symbol"] }
  end

  # The wallet an existing account was built from can legitimately empty out,
  # and that has to be written down: the holdings processor reads this payload,
  # so leaving the old one behind kept the sold assets alive indefinitely.
  test "emptying a wallet is recorded rather than skipped" do
    BinanceItem::Importer.new(@item, binance_provider: @provider).import
    assert_equal [ "BTC" ], @item.binance_accounts.first.raw_payload["assets"].map { |a| a["symbol"] }

    stub_spot_result([])
    BinanceItem::Importer.new(@item, binance_provider: @provider).import

    ba = @item.binance_accounts.first.reload
    assert_empty ba.raw_payload["assets"], "the emptied wallet kept its old asset list"
    assert_equal 0, ba.current_balance.to_d
  end

  test "stores source breakdown in raw_payload" do
    BinanceItem::Importer.new(@item, binance_provider: @provider).import

    ba = @item.binance_accounts.first
    assert ba.raw_payload.key?("spot")
    assert ba.raw_payload.key?("funding")
    assert ba.raw_payload.key?("margin")
    assert ba.raw_payload.key?("isolated_margin")
    assert ba.raw_payload.key?("earn")
    assert ba.raw_payload.key?("yield_assets")
    assert ba.raw_payload.key?("futures")
    assert ba.raw_payload.key?("coin_futures")
    assert ba.raw_payload.key?("options")
    assert_equal "1.0", ba.raw_payload["minimum_holding_usd"]
    assert_equal "ok", ba.raw_payload.dig("source_status", "spot", "status")
  end

  private

    def payload_assets
      @item.binance_accounts.first.reload.raw_payload["assets"]
    end

    def payload_symbols
      payload_assets.map { |a| a["symbol"] }.uniq
    end

    def stub_failed_result(source)
      klass = {
        "spot" => BinanceItem::SpotImporter,
        "funding" => BinanceItem::FundingImporter,
        "margin" => BinanceItem::MarginImporter,
        "isolated_margin" => BinanceItem::IsolatedMarginImporter,
        "earn" => BinanceItem::EarnImporter,
        "yield_assets" => BinanceItem::YieldAssetImporter,
        "futures" => BinanceItem::FuturesImporter,
        "coin_futures" => BinanceItem::CoinFuturesImporter,
        "options" => BinanceItem::OptionsImporter
      }.fetch(source)
      klass.any_instance.stubs(:import).returns(
        { assets: [], raw: nil, source: source, error: "boom" }
      )
    end

    def stub_spot_result(assets)
      BinanceItem::SpotImporter.any_instance.stubs(:import).returns(
        { assets: assets, raw: {}, source: "spot" }
      )
    end

    def stub_margin_result(assets)
      BinanceItem::MarginImporter.any_instance.stubs(:import).returns(
        { assets: assets, raw: {}, source: "margin" }
      )
    end

    def stub_funding_result(assets)
      BinanceItem::FundingImporter.any_instance.stubs(:import).returns(
        { assets: assets, raw: {}, source: "funding" }
      )
    end

    def stub_isolated_margin_result(assets)
      BinanceItem::IsolatedMarginImporter.any_instance.stubs(:import).returns(
        { assets: assets, raw: {}, source: "isolated_margin" }
      )
    end

    def stub_earn_result(assets)
      BinanceItem::EarnImporter.any_instance.stubs(:import).returns(
        { assets: assets, raw: {}, source: "earn" }
      )
    end

    def stub_yield_asset_result(assets)
      BinanceItem::YieldAssetImporter.any_instance.stubs(:import).returns(
        { assets: assets, raw: {}, source: "yield_assets" }
      )
    end

    def stub_futures_result(assets)
      BinanceItem::FuturesImporter.any_instance.stubs(:import).returns(
        { assets: assets, raw: {}, source: "futures" }
      )
    end

    def stub_coin_futures_result(assets)
      BinanceItem::CoinFuturesImporter.any_instance.stubs(:import).returns(
        { assets: assets, raw: {}, source: "coin_futures" }
      )
    end

    def stub_options_result(assets)
      BinanceItem::OptionsImporter.any_instance.stubs(:import).returns(
        { assets: assets, raw: {}, source: "options" }
      )
    end

    def stub_portfolio_margin_result(assets: [], error: nil)
      result = { assets: assets, raw: {}, source: "portfolio_margin", aggregate: true }
      result[:error] = error if error
      BinanceItem::PortfolioMarginImporter.any_instance.stubs(:import).returns(result)
    end
end
