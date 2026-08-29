# frozen_string_literal: true

require "test_helper"

class OkxAccount::HoldingsProcessorTest < ActiveSupport::TestCase
  setup do
    @family = families(:dylan_family)
    @family.update!(currency: "USD")
    @item = OkxItem.create!(
      family: @family, name: "OKX (A)", api_key: "k", api_secret: "s", passphrase: "p"
    )
    @provider_account = @item.okx_accounts.create!(
      name: "OKX (A)", account_type: "combined", currency: "USD", current_balance: 300,
      raw_payload: {
        "assets" => [
          { "symbol" => "ETH", "total" => "2", "source" => "trading", "usd_price" => "100" },
          { "symbol" => "ETH", "total" => "1", "source" => "simple_earn", "usd_price" => "100" }
        ]
      }
    )
    @account = Account.create!(
      family: @family, name: "OKX (A)", balance: 300, cash_balance: 0, currency: "USD",
      accountable: Crypto.create!(subtype: "exchange")
    )
    AccountProvider.create!(account: @account, provider: @provider_account)
  end

  test "aggregates the same asset across OKX products into one holding" do
    Security.find_or_create_by!(ticker: "CRYPTO:ETH") { |security| security.name = "ETH" }

    OkxAccount::HoldingsProcessor.new(@provider_account).process

    holding = @account.reload.current_holdings.find { |row| row.ticker == "CRYPTO:ETH" }
    assert_equal 3, holding.qty
    assert_equal 300, holding.amount
    assert_match(/okx_ETH_combined_/, holding.external_id)
  end
end
