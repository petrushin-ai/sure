# frozen_string_literal: true

require "test_helper"

class Provider::OkxAdapterTest < ActiveSupport::TestCase
  setup do
    @item = OkxItem.create!(
      family: families(:dylan_family),
      name: "OKX A",
      api_key: "okx_adapter_key",
      api_secret: "okx_adapter_secret",
      passphrase: "okx_adapter_passphrase",
      institution_name: "OKX",
      institution_domain: "okx.com",
      institution_url: "https://www.okx.com",
      institution_color: "#000000"
    )
    @provider_account = @item.okx_accounts.create!(
      name: "OKX A",
      account_type: "combined",
      currency: "USD",
      current_balance: 100
    )
  end

  test "registers OkxAccount with the provider factory" do
    adapter = Provider::Factory.create_adapter(@provider_account)

    assert_instance_of Provider::OkxAdapter, adapter
    assert_equal "okx", adapter.provider_name
    assert_equal @item, adapter.item
  end

  test "supports crypto accounts and exposes the item sync path" do
    adapter = Provider::OkxAdapter.new(@provider_account)

    assert_equal [ "Crypto" ], Provider::OkxAdapter.supported_account_types
    assert_equal Rails.application.routes.url_helpers.sync_okx_item_path(@item), adapter.sync_path
    assert_not adapter.can_delete_holdings?
  end

  test "falls back to item institution metadata" do
    adapter = Provider::OkxAdapter.new(@provider_account)

    assert_equal "OKX", adapter.institution_name
    assert_equal "okx.com", adapter.institution_domain
    assert_equal "https://www.okx.com", adapter.institution_url
    assert_equal "#000000", adapter.institution_color
  end

  test "prefers provider account institution metadata" do
    @provider_account.update!(institution_metadata: {
      "name" => "OKX Sub-account",
      "domain" => "my.okx.com",
      "url" => "https://my.okx.com",
      "color" => "#111111"
    })
    adapter = Provider::OkxAdapter.new(@provider_account)

    assert_equal "OKX Sub-account", adapter.institution_name
    assert_equal "my.okx.com", adapter.institution_domain
    assert_equal "https://my.okx.com", adapter.institution_url
    assert_equal "#111111", adapter.institution_color
  end
end
