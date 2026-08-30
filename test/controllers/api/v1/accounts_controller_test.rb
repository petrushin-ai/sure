# frozen_string_literal: true

require "test_helper"

class Api::V1::AccountsControllerTest < ActionDispatch::IntegrationTest
  setup do
    @user = users(:family_admin) # dylan_family user
    @other_family_user = users(:family_member)
    @other_family_user.update!(family: families(:empty))

    @user.api_keys.active.destroy_all
    @api_key = ApiKey.create!(
      user: @user,
      name: "Test Read Key",
      scopes: [ "read" ],
      source: "web",
      display_key: "test_read_#{SecureRandom.hex(8)}"
    )
    @write_key = ApiKey.create!(
      user: @user,
      name: "Test Read Write Key",
      scopes: [ "read_write" ],
      source: "web",
      display_key: "test_read_write_#{SecureRandom.hex(8)}"
    )

    @other_family_user.api_keys.active.destroy_all
    @other_family_api_key = ApiKey.create!(
      user: @other_family_user,
      name: "Other Family Read Key",
      scopes: [ "read" ],
      source: "web",
      display_key: "other_family_read_#{SecureRandom.hex(8)}"
    )
    @other_family_write_key = ApiKey.create!(
      user: @other_family_user,
      name: "Other Family Read Write Key",
      scopes: [ "read_write" ],
      source: "web",
      display_key: "other_family_read_write_#{SecureRandom.hex(8)}"
    )
  end

  test "should require authentication" do
    get "/api/v1/accounts"
    assert_response :unauthorized

    response_body = JSON.parse(response.body)
    assert_equal "unauthorized", response_body["error"]
  end

  test "should require read_accounts scope" do
    api_key_without_read = ApiKey.new(
      user: @user,
      name: "No Read Key",
      scopes: [],
      source: "web",
      display_key: "no_read_#{SecureRandom.hex(8)}"
    )
    # Valid persisted API keys can only be read/read_write; this intentionally
    # bypasses validations to exercise the runtime insufficient-scope guard.
    api_key_without_read.save!(validate: false)

    get "/api/v1/accounts", params: {}, headers: api_headers(api_key_without_read)

    assert_response :forbidden
    response_body = JSON.parse(response.body)
    assert_equal "insufficient_scope", response_body["error"]
  ensure
    api_key_without_read&.destroy
  end

  test "should return user's family accounts successfully" do
    get "/api/v1/accounts", params: {}, headers: api_headers(@api_key)

    assert_response :success
    response_body = JSON.parse(response.body)

    # Should have accounts array
    assert response_body.key?("accounts")
    assert response_body["accounts"].is_a?(Array)

    # Should have pagination metadata
    assert response_body.key?("pagination")
    assert response_body["pagination"].key?("page")
    assert response_body["pagination"].key?("per_page")
    assert response_body["pagination"].key?("total_count")
    assert response_body["pagination"].key?("total_pages")

    # All accounts should belong to user's family
    response_body["accounts"].each do |account|
      # We'll validate this by checking the user's family has these accounts
      family_account_names = @user.family.accounts.pluck(:name)
      assert_includes family_account_names, account["name"]
    end
  end

  test "should only return active accounts" do
    # Make one account inactive
    inactive_account = accounts(:depository)
    inactive_account.disable!

    get "/api/v1/accounts", params: {}, headers: api_headers(@api_key)

    assert_response :success
    response_body = JSON.parse(response.body)

    # Should not include the inactive account
    account_names = response_body["accounts"].map { |a| a["name"] }
    assert_not_includes account_names, inactive_account.name
  end

  test "should include disabled accounts when requested" do
    inactive_account = accounts(:depository)
    inactive_account.disable!

    get "/api/v1/accounts", params: { include_disabled: true }, headers: api_headers(@api_key)

    assert_response :success
    response_body = JSON.parse(response.body)

    account = response_body["accounts"].find { |account_data| account_data["id"] == inactive_account.id }
    assert_not_nil account
    assert_equal "disabled", account["status"]
  end

  test "should show active account" do
    account = accounts(:depository)

    get "/api/v1/accounts/#{account.id}", headers: api_headers(@api_key)

    assert_response :success
    response_body = JSON.parse(response.body)
    assert_equal account.id, response_body["id"]
    assert_equal account.status, response_body["status"]
    assert_equal account.balance_money.format, response_body["balance"]
    assert_equal money_cents(account.balance_money), response_body["balance_cents"]
    assert_equal account.cash_balance_money.format, response_body["cash_balance"]
    assert_equal money_cents(account.cash_balance_money), response_body["cash_balance_cents"]
    assert_nullable_equal account.subtype, response_body["subtype"]
    assert response_body.key?("institution_name")
    assert response_body.key?("institution_domain")
    assert_nullable_equal account.institution_name, response_body["institution_name"]
    assert_nullable_equal account.institution_domain, response_body["institution_domain"]
    assert_equal account.created_at.iso8601, response_body["created_at"]
    assert_equal account.updated_at.iso8601, response_body["updated_at"]
  end

  test "should return 404 for unknown account on show" do
    get "/api/v1/accounts/#{SecureRandom.uuid}", headers: api_headers(@api_key)

    assert_response :not_found
    response_body = JSON.parse(response.body)
    assert_equal "not_found", response_body["error"]
  end

  test "should return 404 for malformed account id on show" do
    get "/api/v1/accounts/not-a-uuid", headers: api_headers(@api_key)

    assert_response :not_found
    response_body = JSON.parse(response.body)
    assert_equal "not_found", response_body["error"]
    assert_equal "Account not found", response_body["message"]
  end

  test "should require authentication on show" do
    account = accounts(:depository)

    get "/api/v1/accounts/#{account.id}"

    assert_response :unauthorized
    response_body = JSON.parse(response.body)
    assert_equal "unauthorized", response_body["error"]
  end

  test "should require read scope on show" do
    account = accounts(:depository)
    api_key_without_read = ApiKey.new(
      user: @user,
      name: "No Read Show Key",
      scopes: [],
      source: "web",
      display_key: "no_read_show_#{SecureRandom.hex(8)}"
    )
    # Valid persisted API keys can only be read/read_write; this intentionally
    # bypasses validations to exercise the runtime insufficient-scope guard.
    api_key_without_read.save!(validate: false)

    get "/api/v1/accounts/#{account.id}", headers: api_headers(api_key_without_read)

    assert_response :forbidden
    response_body = JSON.parse(response.body)
    assert_equal "insufficient_scope", response_body["error"]
  ensure
    api_key_without_read&.destroy
  end

  test "should hide disabled account by default on show" do
    inactive_account = accounts(:depository)
    inactive_account.disable!

    get "/api/v1/accounts/#{inactive_account.id}", headers: api_headers(@api_key)

    assert_response :not_found
  end

  test "should show disabled account when requested" do
    inactive_account = accounts(:depository)
    inactive_account.disable!

    get "/api/v1/accounts/#{inactive_account.id}",
        params: { include_disabled: true },
        headers: api_headers(@api_key)

    assert_response :success
    response_body = JSON.parse(response.body)
    assert_equal inactive_account.id, response_body["id"]
    assert_equal "disabled", response_body["status"]
  end

  test "should expose subtype across account types" do
    expected_subtypes = {
      accounts(:depository) => "checking",
      accounts(:credit_card) => "credit_card",
      accounts(:investment) => "brokerage",
      accounts(:loan) => "mortgage",
      accounts(:property) => "single_family_home",
      accounts(:vehicle) => "sedan",
      accounts(:crypto) => "exchange",
      accounts(:other_asset) => "collectible",
      accounts(:other_liability) => "personal_debt"
    }

    expected_subtypes.each { |account, subtype| account.accountable.update!(subtype: subtype) }

    expected_subtypes.each do |account, subtype|
      get "/api/v1/accounts/#{account.id}", headers: api_headers(@api_key)

      assert_response :success
      assert_equal subtype, JSON.parse(response.body)["subtype"]
    end
  end

  test "should update a reviewed T-Bank credit card snapshot" do
    account = accounts(:credit_card)
    account.update!(currency: "RUB", balance: 120_569, notes: "Keep this note")

    patch "/api/v1/accounts/#{account.id}/credit_card_snapshot",
          params: { credit_card_snapshot: tbank_credit_card_snapshot },
          headers: api_headers(@write_key)

    assert_response :success
    response_body = JSON.parse(response.body)
    assert_equal "519667.35", response_body.dig("credit_card", "available_credit")
    assert_equal "7000.0", response_body.dig("credit_card", "minimum_payment")
    assert_includes response_body["notes"], "Keep this note"
    assert_includes response_body["notes"], "Credit limit: 640000.0 RUB"
    assert_includes response_body["notes"], "Total debt: 120569.0 RUB"
    assert_includes response_body["notes"], "Payment due date: 2026-09-22"
    assert_includes response_body["notes"], "Cards: ·3154, ·9146"

    account.reload
    assert_equal BigDecimal("519667.35"), account.credit_card.available_credit
    assert_equal BigDecimal("7000"), account.credit_card.minimum_payment
    assert_equal 1, account.notes.scan("[family-connectors:tbank-credit-snapshot]").size

    patch "/api/v1/accounts/#{account.id}/credit_card_snapshot",
          params: { credit_card_snapshot: tbank_credit_card_snapshot },
          headers: api_headers(@write_key)

    assert_response :success
    assert_equal 1, account.reload.notes.scan("[family-connectors:tbank-credit-snapshot]").size
  end

  test "should require write scope for a credit card snapshot" do
    account = accounts(:credit_card)
    account.update!(currency: "RUB", balance: 120_569)

    patch "/api/v1/accounts/#{account.id}/credit_card_snapshot",
          params: { credit_card_snapshot: tbank_credit_card_snapshot },
          headers: api_headers(@api_key)

    assert_response :forbidden
  end

  test "should require authentication for a credit card snapshot" do
    account = accounts(:credit_card)

    patch "/api/v1/accounts/#{account.id}/credit_card_snapshot",
          params: { credit_card_snapshot: tbank_credit_card_snapshot }

    assert_response :unauthorized
  end

  test "should not update another family's credit card" do
    account = accounts(:credit_card)
    account.update!(currency: "RUB", balance: 120_569)
    previous_available_credit = account.credit_card.available_credit

    patch "/api/v1/accounts/#{account.id}/credit_card_snapshot",
          params: { credit_card_snapshot: tbank_credit_card_snapshot },
          headers: api_headers(@other_family_write_key)

    assert_response :not_found
    assert_equal previous_available_credit, account.reload.credit_card.available_credit
  end

  test "should reject a snapshot for a non-credit account" do
    account = accounts(:depository)

    patch "/api/v1/accounts/#{account.id}/credit_card_snapshot",
          params: { credit_card_snapshot: tbank_credit_card_snapshot },
          headers: api_headers(@write_key)

    assert_response :unprocessable_entity
    assert_equal "validation_failed", JSON.parse(response.body)["error"]
  end

  test "should reject a credit snapshot whose debt does not match the account" do
    account = accounts(:credit_card)
    account.update!(currency: "RUB", balance: 1)

    patch "/api/v1/accounts/#{account.id}/credit_card_snapshot",
          params: { credit_card_snapshot: tbank_credit_card_snapshot },
          headers: api_headers(@write_key)

    assert_response :unprocessable_entity
    assert_equal "Credit card balance does not match total debt", JSON.parse(response.body)["message"]
  end

  test "should not return other family's accounts" do
    get "/api/v1/accounts", params: {}, headers: api_headers(@other_family_api_key)

    assert_response :success
    response_body = JSON.parse(response.body)

    # Should return empty array since other family has no accounts in fixtures
    assert_equal [], response_body["accounts"]
    assert_equal 0, response_body["pagination"]["total_count"]
  end

  test "should handle pagination parameters" do
    # Test with pagination params
    get "/api/v1/accounts", params: { page: 1, per_page: 2 }, headers: api_headers(@api_key)

    assert_response :success
    response_body = JSON.parse(response.body)

    # Should respect per_page limit
    assert response_body["accounts"].length <= 2
    assert_equal 1, response_body["pagination"]["page"]
    assert_equal 2, response_body["pagination"]["per_page"]
  end

  test "should return proper account data structure" do
    get "/api/v1/accounts", params: {}, headers: api_headers(@api_key)

    assert_response :success
    response_body = JSON.parse(response.body)

    # Should have at least one account from fixtures
    assert response_body["accounts"].length > 0

    account = response_body["accounts"].first

    # Check required fields are present
    required_fields = %w[id name balance balance_cents cash_balance cash_balance_cents currency classification account_type]
    required_fields.each do |field|
      assert account.key?(field), "Account should have #{field} field"
    end

    # Check data types
    assert account["id"].is_a?(String), "ID should be string (UUID)"
    assert account["name"].is_a?(String), "Name should be string"
    assert account["balance"].is_a?(String), "Balance should be string (money)"
    assert account["balance_cents"].is_a?(Integer), "Balance cents should be integer"
    assert account["cash_balance_cents"].is_a?(Integer), "Cash balance cents should be integer"
    assert account["currency"].is_a?(String), "Currency should be string"
    assert %w[asset liability].include?(account["classification"]), "Classification should be asset or liability"
  end

  test "should handle invalid pagination parameters gracefully" do
    # Test with invalid page number
    get "/api/v1/accounts", params: { page: -1, per_page: "invalid" }, headers: api_headers(@api_key)

    # Should still return success with default pagination
    assert_response :success
    response_body = JSON.parse(response.body)

    # Should have pagination info (with defaults applied)
    assert response_body.key?("pagination")
    assert response_body["pagination"]["page"] >= 1
    assert response_body["pagination"]["per_page"] > 0
  end

  test "should sort accounts alphabetically" do
    get "/api/v1/accounts", params: {}, headers: api_headers(@api_key)

    assert_response :success
    response_body = JSON.parse(response.body)

    # Should be sorted alphabetically by name
    account_names = response_body["accounts"].map { |a| a["name"] }
    assert_equal account_names.sort, account_names
  end

  private

    def api_headers(api_key)
      { "X-Api-Key" => api_key.plain_key }
    end

    def money_cents(money)
      (money.amount * money.currency.minor_unit_conversion).round(0).to_i
    end

    def assert_nullable_equal(expected, actual)
      expected.nil? ? assert_nil(actual) : assert_equal(expected, actual)
    end

    def tbank_credit_card_snapshot
      {
        provider: "tbank",
        snapshot_date: "2026-08-31",
        credit_limit: "640000",
        total_debt: "120569",
        available_credit: "519667.35",
        minimum_payment: "7000",
        grace_period_payment: "120332.65",
        payment_due_date: "2026-09-22",
        card_last4s: %w[9146 3154],
        current_month_spending: "24265",
        reward_miles: 9780,
        source_reference: "a" * 16
      }
    end
end
