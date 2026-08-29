# frozen_string_literal: true

require "test_helper"

class BinanceItem::CoinFuturesImporterTest < ActiveSupport::TestCase
  setup do
    @provider = mock
    @item = BinanceItem.create!(family: families(:dylan_family), name: "B", api_key: "k", api_secret: "s")
  end

  test "imports COIN-M margin equity" do
    @provider.stubs(:get_coin_futures_account).returns({
      "assets" => [
        { "asset" => "BTC", "walletBalance" => "1", "unrealizedProfit" => "0.1", "marginBalance" => "1.1", "availableBalance" => "0.8" }
      ]
    })

    result = BinanceItem::CoinFuturesImporter.new(@item, provider: @provider).import

    assert_equal "coin_futures", result[:source]
    assert_equal "1.1", result[:assets].first[:total]
    assert_equal "0.8", result[:assets].first[:free]
  end
end
