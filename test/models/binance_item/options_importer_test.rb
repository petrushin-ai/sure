# frozen_string_literal: true

require "test_helper"

class BinanceItem::OptionsImporterTest < ActiveSupport::TestCase
  setup do
    @provider = mock
    @item = BinanceItem.create!(family: families(:dylan_family), name: "B", api_key: "k", api_secret: "s")
  end

  test "imports standalone Options equity" do
    @provider.stubs(:get_options_account).returns({
      "asset" => [ { "asset" => "USDT", "equity" => "125", "available" => "100" } ]
    })

    result = BinanceItem::OptionsImporter.new(@item, provider: @provider).import

    assert_equal "options", result[:source]
    assert_equal "125.0", result[:assets].first[:total]
    assert_equal "25.0", result[:assets].first[:locked]
  end

  test "treats Options permission denial as source unavailable" do
    @provider.stubs(:get_options_account).raises(Provider::Binance::AuthenticationError, "not enabled")

    result = BinanceItem::OptionsImporter.new(@item, provider: @provider).import

    assert_equal [], result[:assets]
    assert_equal "not enabled", result[:error]
  end
end
