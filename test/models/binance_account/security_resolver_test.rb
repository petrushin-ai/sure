# frozen_string_literal: true

require "test_helper"

class BinanceAccount::SecurityResolverTest < ActiveSupport::TestCase
  test "creates a canonical offline security without fuzzy provider search" do
    Security.where(ticker: "CRYPTO:CANONICALTEST").delete_all
    Security::Resolver.expects(:new).never

    security = BinanceAccount::SecurityResolver.resolve("CRYPTO:canonicaltest", "CANONICALTEST")

    assert_equal "CRYPTO:CANONICALTEST", security.ticker
    assert_equal "CANONICALTEST", security.name
    assert_equal "XBNC", security.exchange_operating_mic
    assert security.offline?
  ensure
    Security.where(ticker: "CRYPTO:CANONICALTEST").delete_all
  end

  test "reuses an existing exact ticker instead of creating a market-pair security" do
    existing = Security.create!(
      ticker: "CRYPTO:REUSETEST",
      name: "Existing crypto security",
      offline: true
    )
    Security::Resolver.expects(:new).never

    resolved = BinanceAccount::SecurityResolver.resolve("CRYPTO:REUSETEST", "REUSETEST")

    assert_equal existing, resolved
    assert_equal 1, Security.where(ticker: "CRYPTO:REUSETEST").count
  ensure
    Security.where(ticker: "CRYPTO:REUSETEST").delete_all
  end
end
