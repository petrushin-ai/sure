# frozen_string_literal: true

require "test_helper"

class BinanceItem::FundingImporterTest < ActiveSupport::TestCase
  setup do
    @provider = mock
    @item = BinanceItem.create!(family: families(:dylan_family), name: "B", api_key: "k", api_secret: "s")
  end

  test "imports every nonzero funding balance component" do
    @provider.stubs(:get_funding_wallet).returns([
      { "asset" => "USDT", "free" => "10", "locked" => "2", "freeze" => "3", "withdrawing" => "4" },
      { "asset" => "BTC", "free" => "0", "locked" => "0", "freeze" => "0", "withdrawing" => "0" }
    ])

    result = BinanceItem::FundingImporter.new(@item, provider: @provider).import

    assert_equal "funding", result[:source]
    assert_equal 1, result[:assets].size
    assert_equal "19.0", result[:assets].first[:total]
    assert_equal "9.0", result[:assets].first[:locked]
  end
end
