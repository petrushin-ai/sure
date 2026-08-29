require "test_helper"

class OkxItemsControllerTest < ActionDispatch::IntegrationTest
  include ActiveJob::TestHelper

  setup do
    sign_in users(:family_admin)
    @family = families(:dylan_family)
    @item = OkxItem.create!(family: @family, name: "OKX A", api_key: "key", api_secret: "secret", passphrase: "phrase")
  end

  test "provider panel exposes all three credentials and saved state" do
    get connect_form_settings_providers_url(provider_key: "okx")

    assert_response :success
    assert_select "#okx-providers-panel form[action='#{okx_items_path}']"
    assert_select "input[name='okx_item[api_key]']"
    assert_select "input[name='okx_item[api_secret]']"
    assert_select "input[name='okx_item[passphrase]']"
    assert_select "#okx-providers-panel", text: /saved and encrypted/
  end

  test "blank credential fields preserve saved credentials while renaming" do
    patch okx_item_url(@item), params: { okx_item: { name: "OKX Long-term", api_key: "", api_secret: "", passphrase: "" } }

    assert_redirected_to settings_providers_path
    @item.reload
    assert_equal "OKX Long-term", @item.name
    assert_equal "key", @item.api_key
    assert_equal "secret", @item.api_secret
    assert_equal "phrase", @item.passphrase
  end

  test "creates another named OKX connection" do
    assert_difference "@family.okx_items.count", 1 do
      post okx_items_url, params: { okx_item: { name: "OKX B", api_key: "key-b", api_secret: "secret-b", passphrase: "phrase-b" } }
    end
    assert_redirected_to settings_providers_path
  end

  test "setup accounts uses theme-aware design system inputs" do
    okx_account = @item.okx_accounts.create!(
      name: "OKX Portfolio",
      account_type: "combined",
      currency: "USD",
      current_balance: 100
    )

    get setup_accounts_okx_item_url(@item)

    assert_response :success
    assert_select ".form-field input[type='date'].form-field__input[name='sync_start_date']", count: 1
    assert_select ".form-field input.form-field__input[name='account_names[#{okx_account.id}]']", count: 1
    assert_select "input.input", count: 0
  end
end
