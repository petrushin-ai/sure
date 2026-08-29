# frozen_string_literal: true

require "test_helper"

class Provider::ToncenterTest < ActiveSupport::TestCase
  ADDRESS = "0:#{"1" * 64}"

  setup do
    @provider = Provider::Toncenter.new(api_key: "secret", min_request_interval: 0, max_retries: 0)
  end

  test "reads an account through API v3 and sends the optional key in a header" do
    request = stub_request(:get, "#{Provider::Toncenter.base_url}/accountStates")
      .with(query: hash_including("address" => ADDRESS), headers: { "X-API-Key" => "secret" })
      .to_return(status: 200, body: { accounts: [ { balance: "123" } ] }.to_json, headers: json_headers)

    assert_equal "123", @provider.account_state(ADDRESS)["balance"]
    assert_requested request, times: 1
  end

  test "paginates with a bounded extra row and reports truncation" do
    request = stub_request(:get, "#{Provider::Toncenter.base_url}/jetton/wallets")
      .with(query: hash_including("owner_address" => ADDRESS, "limit" => "2", "offset" => "0"))
      .to_return(
        status: 200,
        body: { jetton_wallets: [ { address: "one" }, { address: "two" } ], metadata: { "0:master" => {} } }.to_json,
        headers: json_headers
      )

    page = @provider.jetton_wallets(ADDRESS, max_rows: 1)

    assert_equal [ "one" ], page.rows.pluck("address")
    assert page.truncated
    assert_equal({ "0:master" => {} }, page.metadata)
    assert_requested request, times: 1
  end

  test "always sends the history lower bound" do
    request = stub_request(:get, "#{Provider::Toncenter.base_url}/actions")
      .with(query: hash_including("account" => ADDRESS, "start_utime" => "1234", "action_type" => "ton_transfer"))
      .to_return(status: 200, body: { actions: [] }.to_json, headers: json_headers)

    @provider.ton_transfers(ADDRESS, start_utime: 1234, max_rows: 10)

    assert_requested request, times: 1
  end

  test "translates timeouts into provider errors" do
    stub_request(:get, "#{Provider::Toncenter.base_url}/accountStates")
      .with(query: hash_including("address" => ADDRESS)).to_timeout
    assert_raises Provider::Toncenter::ApiError do
      @provider.account_state(ADDRESS)
    end
  end

  test "reports rate limits after the configured retry budget" do
    stub_request(:get, "#{Provider::Toncenter.base_url}/accountStates")
      .with(query: hash_including("address" => ADDRESS)).to_return(status: 429, body: "limited")
    assert_raises Provider::Toncenter::RateLimitError do
      @provider.account_state(ADDRESS)
    end
  end

  private
    def json_headers
      { "Content-Type" => "application/json" }
    end
end
