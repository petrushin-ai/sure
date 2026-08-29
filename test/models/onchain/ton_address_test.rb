# frozen_string_literal: true

require "test_helper"

class Onchain::TonAddressTest < ActiveSupport::TestCase
  USDT_FRIENDLY = "EQCxE6mUtQJKFnGfaROTKOt1lZbDiiX1kCixRv7Nw2Id_sDs"
  USDT_RAW = "0:b113a994b5024a16719f69139328eb759596c38a25f59028b146fecdc3621dfe"

  test "canonicalizes official mainnet user-friendly and raw forms" do
    assert_equal USDT_RAW, Onchain::TonAddress.canonical(USDT_FRIENDLY)
    assert_equal USDT_RAW, Onchain::TonAddress.canonical(USDT_RAW.upcase.sub("0:", "0:"))
  end

  test "bounceable and non-bounceable forms identify one account" do
    assert_equal USDT_RAW, Onchain::TonAddress.canonical(with_tag(USDT_FRIENDLY, 0x51))
  end

  test "rejects testnet-only and corrupt user-friendly addresses" do
    assert_nil Onchain::TonAddress.canonical(with_tag(USDT_FRIENDLY, 0x91))
    assert_nil Onchain::TonAddress.canonical("#{USDT_FRIENDLY.first(47)}A")
  end

  test "rejects unsupported workchains and malformed raw addresses" do
    assert_nil Onchain::TonAddress.canonical("1:#{"0" * 64}")
    assert_nil Onchain::TonAddress.canonical("0:abc")
  end

  private
    def with_tag(address, tag)
      decoded = Base64.urlsafe_decode64(address)
      body = decoded.byteslice(0, 34).dup
      body.setbyte(0, tag)
      Base64.urlsafe_encode64(body + [ crc16(body) ].pack("n"), padding: false)
    end

    def crc16(bytes)
      bytes.each_byte.reduce(0) do |crc, byte|
        crc ^= byte << 8
        8.times { crc = (crc & 0x8000).zero? ? crc << 1 : (crc << 1) ^ 0x1021; crc &= 0xffff }
        crc
      end
    end
end
