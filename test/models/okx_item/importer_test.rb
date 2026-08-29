require "test_helper"

class OkxItem::ImporterTest < ActiveSupport::TestCase
  setup do
    @item = OkxItem.create!(family: families(:dylan_family), name: "OKX A", api_key: "k", api_secret: "s", passphrase: "p")
    @provider = mock
    stub_optional_sources
    stub_history
    @provider.stubs(:get_market_price).returns(nil)
  end

  test "combines trading funding earn onchain and loan balances without adding aggregate diagnostics" do
    @provider.stubs(:get_account_balance).returns([ { "details" => [ { "ccy" => "USDT", "eq" => "10", "eqUsd" => "10" } ] } ])
    @provider.stubs(:get_funding_balances).returns([ { "ccy" => "USDC", "bal" => "2" } ])
    @provider.stubs(:get_simple_earn_balances).returns([ { "ccy" => "DAI", "amt" => "3" } ])
    @provider.stubs(:get_onchain_earn_positions).returns([ { "investData" => [ { "ccy" => "USDG", "amt" => "4" } ] } ])
    @provider.stubs(:get_flexible_loans).returns([ {
      "collateralData" => [ { "ccy" => "TUSD", "amt" => "5" } ],
      "loanData" => [ { "ccy" => "USDT", "amt" => "1" } ]
    } ])
    @provider.stubs(:get_okusd_balance).returns([ { "ccy" => "OKUSD", "amt" => "6" } ])
    @provider.stubs(:get_eth_staking_balance).returns([ { "ccy" => "BETH", "amt" => "999" } ])

    OkxItem::Importer.new(@item, provider: @provider).import

    account = @item.okx_accounts.first
    assert_equal BigDecimal("29"), account.current_balance
    assert_equal %w[DAI OKUSD TUSD USDC USDG USDT], account.raw_payload["assets"].map { |row| row["symbol"] }.uniq.sort
    assert_equal true, account.raw_payload.dig("source_status", "eth_staking_aggregate", "diagnostic_only")
  end

  test "omits only balances strictly below one dollar and keeps exactly one dollar" do
    @provider.stubs(:get_account_balance).returns([ { "details" => [
      { "ccy" => "USDT", "eq" => "0.99", "eqUsd" => "0.99" },
      { "ccy" => "USDC", "eq" => "1", "eqUsd" => "1" }
    ] } ])

    OkxItem::Importer.new(@item, provider: @provider).import

    assert_equal [ "USDC" ], @item.okx_accounts.first.raw_payload["assets"].map { |row| row["symbol"] }
  end

  test "keeps last assets when an optional source is temporarily unavailable" do
    @provider.stubs(:get_account_balance).returns([ { "details" => [] } ])
    @provider.stubs(:get_funding_balances).returns([ { "ccy" => "USDC", "bal" => "2" } ])
    OkxItem::Importer.new(@item, provider: @provider).import

    @provider.stubs(:get_funding_balances).raises(Provider::Okx::CapabilityError, "temporarily unavailable")
    OkxItem::Importer.new(@item, provider: @provider).import

    assert_equal [ "USDC" ], @item.okx_accounts.first.reload.raw_payload["assets"].map { |row| row["symbol"] }
  end

  test "consolidates the same asset across several orders within one source" do
    @provider.stubs(:get_account_balance).returns([ { "details" => [] } ])
    @provider.stubs(:get_onchain_earn_positions).returns([
      { "investData" => [ { "ccy" => "USDT", "amt" => "2" } ] },
      { "investData" => [ { "ccy" => "USDT", "amt" => "3" } ] }
    ])

    OkxItem::Importer.new(@item, provider: @provider).import

    rows = @item.okx_accounts.first.raw_payload["assets"]
    assert_equal 1, rows.size
    assert_equal "5.0", rows.first["total"]
  end

  test "core unified-account failure fails the sync even if optional products answer" do
    @provider.stubs(:get_account_balance).raises(Provider::Okx::ApiError, "core unavailable")
    @provider.expects(:get_funding_balances).never

    assert_raises(OkxItem::Importer::CoreAccountUnavailable) do
      OkxItem::Importer.new(@item, provider: @provider).import
    end
  end

  private

    def stub_optional_sources
      @provider.stubs(:get_account_balance).returns([ { "details" => [] } ])
      @provider.stubs(:get_funding_balances).returns([])
      @provider.stubs(:get_non_tradable_assets).returns([])
      @provider.stubs(:get_simple_earn_balances).returns([])
      @provider.stubs(:get_onchain_earn_positions).returns([])
      @provider.stubs(:get_flexible_loans).returns([])
      @provider.stubs(:get_dual_investment_orders).returns([])
      @provider.stubs(:get_okusd_balance).returns([])
      @provider.stubs(:get_positions).returns([])
      @provider.stubs(:get_eth_staking_balance).returns([])
      @provider.stubs(:get_sol_staking_balance).returns([])
      @provider.stubs(:get_stable_rewards_balance).returns([])
      @provider.stubs(:get_copy_positions).returns([])
      @provider.stubs(:get_account_config).returns([])
      @provider.stubs(:get_signal_bots).returns([])
      @provider.stubs(:get_recurring_buys).returns([])
      @provider.stubs(:get_grid_bots).returns([])
    end

    def stub_history
      @provider.stubs(:get_account_bills).returns([])
      @provider.stubs(:get_funding_bills).returns([])
      @provider.stubs(:get_deposit_history).returns([])
      @provider.stubs(:get_withdrawal_history).returns([])
      @provider.stubs(:get_convert_history).returns([])
      @provider.stubs(:get_fills_history).returns([])
    end
end
