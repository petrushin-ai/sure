require "test_helper"

class Provider::OkxTest < ActiveSupport::TestCase
  setup do
    @provider = Provider::Okx.new(api_key: "key", api_secret: "secret", passphrase: "phrase")
  end

  test "signs the exact timestamp method and request path with base64 HMAC SHA256" do
    timestamp = "2026-08-29T10:00:00.000Z"
    request_path = "/api/v5/account/balance?ccy=BTC"
    headers = @provider.send(:auth_headers, timestamp, request_path)
    expected = Base64.strict_encode64(
      OpenSSL::HMAC.digest("sha256", "secret", "#{timestamp}GET#{request_path}")
    )

    assert_equal "key", headers["OK-ACCESS-KEY"]
    assert_equal "phrase", headers["OK-ACCESS-PASSPHRASE"]
    assert_equal expected, headers["OK-ACCESS-SIGN"]
    refute headers.key?("x-simulated-trading")
  end

  test "classifies invalid credentials without exposing response HTML" do
    response = mock_response(200, { "code" => "50113", "msg" => "Invalid Sign" })
    assert_raises(Provider::Okx::AuthenticationError) { @provider.send(:handle_response, response) }

    html = mock_response(403, "<!DOCTYPE html><html>blocked</html>")
    error = assert_raises(Provider::Okx::ApiError) { @provider.send(:handle_response, html) }
    assert_equal "Unexpected HTML response from OKX", error.message
  end

  test "classifies rate limit and timestamp errors" do
    assert_raises(Provider::Okx::RateLimitError) do
      @provider.send(:handle_response, mock_response(200, { "code" => "50011", "msg" => "too many" }))
    end
    assert_raises(Provider::Okx::TimestampError) do
      @provider.send(:handle_response, mock_response(200, { "code" => "50102", "msg" => "expired" }))
    end
  end

  test "does not treat an optional disabled product as invalid credentials" do
    error = assert_raises(Provider::Okx::CapabilityError) do
      @provider.send(:handle_response, mock_response(200, { "code" => "51000", "msg" => "Product not enabled" }))
    end
    assert_equal "Product not enabled", error.message
  end

  test "returns data from a successful OKX envelope" do
    data = [ { "ccy" => "BTC" } ]
    assert_equal data, @provider.send(:handle_response, mock_response(200, { "code" => "0", "msg" => "", "data" => data }))
  end

  private

    def mock_response(code, body)
      response = mock
      response.stubs(:code).returns(code)
      response.stubs(:parsed_response).returns(body)
      response
    end
end
