require "test_helper"

class BinanceItemsControllerTest < ActionDispatch::IntegrationTest
  include ActiveJob::TestHelper

  setup do
    sign_in users(:family_admin)
    @family = families(:dylan_family)
    @binance_item = BinanceItem.create!(
      family: @family,
      name: "Test Binance",
      api_key: "test_key",
      api_secret: "test_secret"
    )
  end

  test "should destroy binance item" do
    assert_difference("BinanceItem.count", 0) do # doesn't delete immediately
      delete binance_item_url(@binance_item)
    end

    assert_redirected_to settings_providers_path
    @binance_item.reload
    assert @binance_item.scheduled_for_deletion?
  end

  test "should sync binance item" do
    post sync_binance_item_url(@binance_item)
    assert_response :redirect
  end

  test "creates a second named Binance connection" do
    assert_difference "@family.binance_items.count", 1 do
      post binance_items_url, params: {
        binance_item: {
          name: "Business Binance",
          api_key: "business_key",
          api_secret: "business_secret"
        }
      }
    end

    assert_redirected_to settings_providers_path
    assert_equal "Business Binance", @family.binance_items.order(:created_at).last.name
  end

  test "updates a connection name without clearing blank credentials" do
    patch binance_item_url(@binance_item), params: {
      binance_item: {
        name: "Long-term Binance",
        api_key: "",
        api_secret: ""
      }
    }

    assert_redirected_to settings_providers_path
    @binance_item.reload
    assert_equal "Long-term Binance", @binance_item.name
    assert_equal "test_key", @binance_item.api_key
    assert_equal "test_secret", @binance_item.api_secret
  end

  test "provider panel keeps the add connection form after a connection exists" do
    get connect_form_settings_providers_url(provider_key: "binance")

    assert_response :success
    assert_select "#binance-providers-panel form[action='#{binance_items_path}']"
    assert_select "#binance-providers-panel input[name='binance_item[name]']"
  end

  test "should show setup_accounts page" do
    get setup_accounts_binance_item_url(@binance_item)
    assert_response :success
  end

  test "complete_account_setup creates accounts for selected binance_accounts" do
    binance_account = @binance_item.binance_accounts.create!(
      name: "Spot Portfolio",
      account_type: "spot",
      currency: "USD",
      current_balance: 1000.0
    )

    assert_difference "Account.count", 1 do
      post complete_account_setup_binance_item_url(@binance_item), params: {
        selected_accounts: [ binance_account.id ]
      }
    end

    assert_response :redirect

    binance_account.reload
    assert_not_nil binance_account.current_account
    assert_equal "Crypto", binance_account.current_account.accountable_type
  end

  test "complete_account_setup uses the requested account name" do
    binance_account = @binance_item.binance_accounts.create!(
      name: "Test Binance",
      account_type: "combined",
      currency: "USD",
      current_balance: 1000.0
    )

    post complete_account_setup_binance_item_url(@binance_item), params: {
      selected_accounts: [ binance_account.id ],
      account_names: { binance_account.id.to_s => "Family savings" }
    }

    assert_response :redirect
    assert_equal "Family savings", binance_account.reload.name
    assert_equal "Family savings", binance_account.current_account.name
  end

  test "complete_account_setup updates sync_start_date when provided with a valid past date" do
    binance_account = @binance_item.binance_accounts.create!(
      name: "Spot Portfolio",
      account_type: "spot",
      currency: "USD",
      current_balance: 1000.0
    )

    past_date = (Date.current - 7.days).to_s

    post complete_account_setup_binance_item_url(@binance_item), params: {
      selected_accounts: [ binance_account.id ],
      sync_start_date: past_date
    }

    assert_response :redirect
    @binance_item.reload
    assert_equal Date.parse(past_date), @binance_item.sync_start_date
  end

  test "complete_account_setup rejects a future sync_start_date and sets flash alert" do
    binance_account = @binance_item.binance_accounts.create!(
      name: "Spot Portfolio",
      account_type: "spot",
      currency: "USD",
      current_balance: 1000.0
    )

    future_date = (Date.current + 2.days).to_s
    original_sync_date = @binance_item.sync_start_date

    post complete_account_setup_binance_item_url(@binance_item), params: {
      selected_accounts: [ binance_account.id ],
      sync_start_date: future_date
    }

    @binance_item.reload
    assert_nil @binance_item.sync_start_date
    assert_equal "Sync start date must be a valid date in the past.", flash[:alert]
  end

  test "complete_account_setup with no selection shows message" do
    @binance_item.binance_accounts.create!(
      name: "Spot Portfolio",
      account_type: "spot",
      currency: "USD",
      current_balance: 1000.0
    )

    assert_no_difference "Account.count" do
      post complete_account_setup_binance_item_url(@binance_item), params: {
        selected_accounts: []
      }
    end

    assert_response :redirect
  end

  test "complete_account_setup skips already linked accounts" do
    binance_account = @binance_item.binance_accounts.create!(
      name: "Spot Portfolio",
      account_type: "spot",
      currency: "USD",
      current_balance: 1000.0
    )

    # Pre-link the account
    account = Account.create!(
      family: @family,
      name: "Existing Binance",
      balance: 1000,
      currency: "USD",
      accountable: Crypto.create!(subtype: "exchange")
    )
    AccountProvider.create!(account: account, provider: binance_account)

    assert_no_difference "Account.count" do
      post complete_account_setup_binance_item_url(@binance_item), params: {
        selected_accounts: [ binance_account.id ]
      }
    end
  end

  test "cannot access other family's binance_item" do
    other_family = families(:empty)
    other_item = BinanceItem.create!(
      family: other_family,
      name: "Other Binance",
      api_key: "other_test_key",
      api_secret: "other_test_secret"
    )

    get setup_accounts_binance_item_url(other_item)
    assert_response :not_found
  end

  test "link_existing_account links manual account to binance_account" do
    manual_account = Account.create!(
      family: @family,
      name: "Manual Crypto",
      balance: 0,
      currency: "USD",
      accountable: Crypto.create!(subtype: "exchange")
    )

    binance_account = @binance_item.binance_accounts.create!(
      name: "Spot Portfolio",
      account_type: "spot",
      currency: "USD",
      current_balance: 1000.0
    )

    assert_difference "AccountProvider.count", 1 do
      post link_existing_account_binance_items_url, params: {
        account_id: manual_account.id,
        binance_account_id: binance_account.id
      }
    end

    binance_account.reload
    assert_equal manual_account, binance_account.current_account
  end

  test "link_existing_account rejects account with existing provider" do
    linked_account = Account.create!(
      family: @family,
      name: "Already Linked",
      balance: 0,
      currency: "USD",
      accountable: Crypto.create!(subtype: "exchange")
    )

    other_binance_account = @binance_item.binance_accounts.create!(
      name: "Other Account",
      account_type: "margin",
      currency: "USD",
      current_balance: 500.0
    )
    AccountProvider.create!(account: linked_account, provider: other_binance_account)

    binance_account = @binance_item.binance_accounts.create!(
      name: "Spot Portfolio",
      account_type: "spot",
      currency: "USD",
      current_balance: 1000.0
    )

    assert_no_difference "AccountProvider.count" do
      post link_existing_account_binance_items_url, params: {
        account_id: linked_account.id,
        binance_account_id: binance_account.id
      }
    end
  end

  test "select_existing_account renders without layout" do
    account = Account.create!(
      family: @family,
      name: "Manual Account",
      balance: 0,
      currency: "USD",
      accountable: Crypto.create!(subtype: "exchange")
    )

    get select_existing_account_binance_items_url, params: { account_id: account.id }
    assert_response :success
  end
end
