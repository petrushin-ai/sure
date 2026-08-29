require "test_helper"

class Provider::BinanceTest < ActiveSupport::TestCase
  setup do
    @provider = Provider::Binance.new(api_key: "test_key", api_secret: "test_secret")
  end

  test "sign produces HMAC-SHA256 hex digest" do
    params = { "timestamp" => "1000", "recvWindow" => "5000" }
    sig = @provider.send(:sign, params)
    expected = OpenSSL::HMAC.hexdigest("sha256", "test_secret", "recvWindow=5000&timestamp=1000")
    assert_equal expected, sig
  end

  test "auth_headers include X-MBX-APIKEY" do
    headers = @provider.send(:auth_headers)
    assert_equal "test_key", headers["X-MBX-APIKEY"]
  end

  test "timestamp_params returns hash with timestamp and recvWindow" do
    params = @provider.send(:timestamp_params)
    assert params["timestamp"].present?
    assert_in_delta Time.current.to_i * 1000, params["timestamp"].to_i, 5000
    assert_equal "5000", params["recvWindow"]
  end

  test "handle_response raises AuthenticationError on 401" do
    response = mock_httparty_response(401, { "msg" => "Invalid API-key" })
    assert_raises(Provider::Binance::AuthenticationError) do
      @provider.send(:handle_response, response)
    end
  end

  test "handle_response recognizes Binance credential codes on non-401 responses" do
    response = mock_httparty_response(400, { "code" => -2015, "msg" => "Invalid API-key, IP, or permissions" })

    assert_raises(Provider::Binance::AuthenticationError) do
      @provider.send(:handle_response, response)
    end
  end

  test "handle_response raises RateLimitError on 429" do
    response = mock_httparty_response(429, {})
    assert_raises(Provider::Binance::RateLimitError) do
      @provider.send(:handle_response, response)
    end
  end

  test "handle_response raises RateLimitError on an IP ban" do
    response = mock_httparty_response(418, {})
    assert_raises(Provider::Binance::RateLimitError) do
      @provider.send(:handle_response, response)
    end
  end

  test "spot pricing propagates rate limiting" do
    response = mock_httparty_response(429, {})
    Provider::Binance.stubs(:get).returns(response)

    assert_raises(Provider::Binance::RateLimitError) do
      @provider.get_spot_price("BTCUSDT")
    end
  end

  test "paginates all flexible Earn positions" do
    first_page = { "rows" => Array.new(100) { |i| { "asset" => "A#{i}" } }, "total" => 101 }
    second_page = { "rows" => [ { "asset" => "LAST" } ], "total" => 101 }

    @provider.expects(:signed_get).with(
      "/sapi/v1/simple-earn/flexible/position",
      extra_params: { "current" => "1", "size" => "100" }
    ).returns(first_page)
    @provider.expects(:signed_get).with(
      "/sapi/v1/simple-earn/flexible/position",
      extra_params: { "current" => "2", "size" => "100" }
    ).returns(second_page)

    result = @provider.get_simple_earn_flexible

    assert_equal 101, result["rows"].size
    assert_equal 2, result["pages"]
  end

  test "funding wallet uses Binance read-only POST query" do
    @provider.expects(:signed_post).with(
      "/sapi/v1/asset/get-funding-asset",
      extra_params: { "needBtcValuation" => "false" }
    ).returns([])

    assert_equal [], @provider.get_funding_wallet
  end

  test "signed POST sends a hash whose signature matches the encoded query" do
    @provider.stubs(:timestamp_params).returns({ "timestamp" => "1000", "recvWindow" => "5000" })
    expected_query = {
      "needBtcValuation" => "false",
      "recvWindow" => "5000",
      "timestamp" => "1000"
    }
    expected_signature = OpenSSL::HMAC.hexdigest(
      "sha256",
      "test_secret",
      URI.encode_www_form(expected_query)
    )
    response = mock_httparty_response(200, [])

    Provider::Binance.expects(:post).with(
      "/sapi/v1/asset/get-funding-asset",
      base_uri: Provider::Binance::SPOT_BASE_URL,
      query: expected_query.merge("signature" => expected_signature),
      headers: { "X-MBX-APIKEY" => "test_key" }
    ).returns(response)

    assert_equal [], @provider.get_funding_wallet
  end

  test "sanitizes unexpected HTML provider errors" do
    response = mock_httparty_response(403, "<!DOCTYPE html><html><body>blocked</body></html>")

    error = assert_raises(Provider::Binance::ApiError) do
      @provider.send(:handle_response, response)
    end

    assert_equal "Unexpected HTML response from Binance", error.message
  end

  test "uses the correct hosts for derivative account types" do
    @provider.expects(:signed_get).with(
      "/dapi/v1/account", base_url: Provider::Binance::COIN_FUTURES_BASE_URL
    ).returns({})
    @provider.expects(:signed_get).with(
      "/eapi/v1/account", base_url: Provider::Binance::OPTIONS_BASE_URL
    ).returns({})
    @provider.expects(:signed_get).with(
      "/papi/v1/balance", base_url: Provider::Binance::PORTFOLIO_MARGIN_BASE_URL
    ).returns([])

    @provider.get_coin_futures_account
    @provider.get_options_account
    @provider.get_portfolio_margin_balance
  end

  test "handle_response raises ApiError on other non-2xx" do
    response = mock_httparty_response(403, { "msg" => "WAF Limit" })
    assert_raises(Provider::Binance::ApiError) do
      @provider.send(:handle_response, response)
    end
  end

  test "handle_response returns parsed body on 200" do
    response = mock_httparty_response(200, { "balances" => [] })
    result = @provider.send(:handle_response, response)
    assert_equal({ "balances" => [] }, result)
  end

  private

    def mock_httparty_response(code, body)
      response = mock
      response.stubs(:code).returns(code)
      response.stubs(:parsed_response).returns(body)
      response
    end
end
