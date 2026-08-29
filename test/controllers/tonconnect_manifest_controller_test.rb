# frozen_string_literal: true

require "test_helper"

class TonconnectManifestControllerTest < ActionDispatch::IntegrationTest
  test "manifest is public, same-origin and wallet compatible" do
    get tonconnect_manifest_url

    assert_response :success
    manifest = response.parsed_body
    assert_equal root_url.chomp("/"), manifest["url"]
    assert_equal "Sure", manifest["name"]
    assert_match %r{\Ahttps?://}, manifest["iconUrl"]
    assert_equal "*", response.headers["Access-Control-Allow-Origin"]
  end
end
