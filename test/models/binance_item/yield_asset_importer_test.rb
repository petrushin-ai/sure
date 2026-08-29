# frozen_string_literal: true

require "test_helper"

class BinanceItem::YieldAssetImporterTest < ActiveSupport::TestCase
  setup do
    @provider = mock
    @item = BinanceItem.create!(family: families(:dylan_family), name: "B", api_key: "k", api_secret: "s")
  end

  test "imports BFUSD and RWUSD accounts" do
    @provider.stubs(:get_bfusd_account).returns({ "bfusdAmount" => "12.5", "usdtProfit" => "1" })
    @provider.stubs(:get_rwusd_account).returns({ "rwusdAmount" => "7.5", "totalProfit" => "2" })

    result = BinanceItem::YieldAssetImporter.new(@item, provider: @provider).import

    assert_equal %w[BFUSD RWUSD], result[:assets].map { |asset| asset[:symbol] }
    assert_equal %w[12.5 7.5], result[:assets].map { |asset| asset[:total] }
  end

  test "keeps one product when the other is unavailable" do
    @provider.stubs(:get_bfusd_account).raises(Provider::Binance::ApiError, "not enabled")
    @provider.stubs(:get_rwusd_account).returns({ "rwusdAmount" => "7.5" })

    result = BinanceItem::YieldAssetImporter.new(@item, provider: @provider).import

    assert_nil result[:error]
    assert_equal [ "RWUSD" ], result[:assets].map { |asset| asset[:symbol] }
  end
end
