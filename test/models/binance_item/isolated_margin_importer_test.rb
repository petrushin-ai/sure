# frozen_string_literal: true

require "test_helper"

class BinanceItem::IsolatedMarginImporterTest < ActiveSupport::TestCase
  setup do
    @provider = mock
    @item = BinanceItem.create!(family: families(:dylan_family), name: "B", api_key: "k", api_secret: "s")
  end

  test "keeps each isolated pair as a distinct source" do
    @provider.stubs(:get_isolated_margin_account).returns({
      "assets" => [
        {
          "symbol" => "BTCUSDT",
          "baseAsset" => { "asset" => "BTC", "free" => "0.1", "locked" => "0", "netAsset" => "0.09" },
          "quoteAsset" => { "asset" => "USDT", "free" => "0", "locked" => "0", "netAsset" => "-100" }
        }
      ]
    })

    result = BinanceItem::IsolatedMarginImporter.new(@item, provider: @provider).import

    assert_equal %w[BTC USDT], result[:assets].map { |asset| asset[:symbol] }
    assert result[:assets].all? { |asset| asset[:source] == "isolated_margin:BTCUSDT" }
    assert_equal "-100.0", result[:assets].last[:total]
  end
end
