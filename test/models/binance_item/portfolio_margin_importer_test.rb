# frozen_string_literal: true

require "test_helper"

class BinanceItem::PortfolioMarginImporterTest < ActiveSupport::TestCase
  setup do
    @provider = mock
    @item = BinanceItem.create!(family: families(:dylan_family), name: "B", api_key: "k", api_secret: "s")
  end

  test "prefers Portfolio Margin Pro and includes derivative equity" do
    @provider.stubs(:get_portfolio_margin_pro_balance).returns([
      {
        "asset" => "USDT", "totalWalletBalance" => "100", "crossMarginFree" => "20",
        "umWalletBalance" => "50", "umUnrealizedPNL" => "5",
        "cmWalletBalance" => "10", "cmUnrealizedPNL" => "2",
        "optionWalletBalance" => "20", "optionEquity" => "23"
      }
    ])
    @provider.expects(:get_portfolio_margin_balance).never

    result = BinanceItem::PortfolioMarginImporter.new(@item, provider: @provider).import

    assert_equal "pro", result[:raw]["mode"]
    assert_equal "110.0", result[:assets].first[:total]
  end

  test "falls back to classic Portfolio Margin" do
    @provider.stubs(:get_portfolio_margin_pro_balance).raises(Provider::Binance::ApiError, "not pro")
    @provider.stubs(:get_portfolio_margin_balance).returns([
      { "asset" => "USDT", "totalWalletBalance" => "10", "umUnrealizedPNL" => "1", "cmUnrealizedPNL" => "2" }
    ])

    result = BinanceItem::PortfolioMarginImporter.new(@item, provider: @provider).import

    assert_equal "classic", result[:raw]["mode"]
    assert_equal "13.0", result[:assets].first[:total]
  end
end
