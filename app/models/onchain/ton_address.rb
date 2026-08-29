# frozen_string_literal: true

require "base64"

# TON account address parsing without a network call.
#
# TON exposes the same account as either `workchain:hex` or a 36-byte
# user-friendly Base64/Base64URL value. The latter carries bounce/testnet flags
# and a CRC16 checksum. Sure stores the lower-case raw form so bounceable and
# non-bounceable spellings cannot create duplicate wallets.
module Onchain::TonAddress
  RAW_PATTERN = /\A(-?\d+):([0-9a-fA-F]{64})\z/
  USER_FRIENDLY_BYTES = 36
  BOUNCEABLE_TAG = 0x11
  NON_BOUNCEABLE_TAG = 0x51
  TESTNET_FLAG = 0x80
  ALLOWED_WORKCHAINS = [ -1, 0 ].freeze

  class << self
    def valid?(address)
      canonical(address).present?
    end

    def canonical(address)
      value = address.to_s.strip
      return canonical_raw(value) if RAW_PATTERN.match?(value)

      canonical_user_friendly(value)
    rescue ArgumentError
      nil
    end

    private
      def canonical_raw(value)
        match = RAW_PATTERN.match(value)
        return nil if match.nil?

        workchain = Integer(match[1], 10)
        return nil unless ALLOWED_WORKCHAINS.include?(workchain)

        "#{workchain}:#{match[2].downcase}"
      end

      def canonical_user_friendly(value)
        decoded = decode_base64(value)
        return nil unless decoded&.bytesize == USER_FRIENDLY_BYTES

        body = decoded.byteslice(0, 34)
        return nil unless decoded.byteslice(34, 2).unpack1("n") == crc16(body)

        tag = body.getbyte(0)
        # A testnet-only user-friendly spelling must never be silently treated
        # as mainnet. Raw addresses carry no network bit; TonConnect separately
        # supplies and validates its mainnet chain id.
        return nil unless (tag & TESTNET_FLAG).zero?
        return nil unless [ BOUNCEABLE_TAG, NON_BOUNCEABLE_TAG ].include?(tag)

        workchain_byte = body.getbyte(1)
        workchain = workchain_byte >= 128 ? workchain_byte - 256 : workchain_byte
        return nil unless ALLOWED_WORKCHAINS.include?(workchain)

        "#{workchain}:#{body.byteslice(2, 32).unpack1("H*")}"
      end

      def decode_base64(value)
        return nil unless value.match?(/\A[A-Za-z0-9+\/_-]{48}={0,2}\z/)

        normalized = value.tr("-_", "+/")
        normalized += "=" * ((4 - normalized.length % 4) % 4)
        Base64.strict_decode64(normalized)
      end

      # CRC-16/XMODEM, used by TON's user-friendly address format.
      def crc16(bytes)
        bytes.each_byte.reduce(0) do |crc, byte|
          crc ^= byte << 8
          8.times do
            crc = if (crc & 0x8000).zero?
              crc << 1
            else
              (crc << 1) ^ 0x1021
            end
            crc &= 0xffff
          end
          crc
        end
      end
  end
end
