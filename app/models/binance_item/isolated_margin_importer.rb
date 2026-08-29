# frozen_string_literal: true

# Fetches every enabled isolated-margin pair. Each pair is kept as a distinct
# source so the same asset held in two isolated wallets is not collapsed.
class BinanceItem::IsolatedMarginImporter
  attr_reader :binance_item, :provider

  def initialize(binance_item, provider:)
    @binance_item = binance_item
    @provider = provider
  end

  def import
    raw = provider.get_isolated_margin_account
    assets = Array(raw["assets"]).flat_map { |account| parse_account(account) }

    { assets: assets, raw: raw, source: "isolated_margin" }
  rescue Provider::Binance::AuthenticationError, Provider::Binance::RateLimitError
    raise
  rescue => e
    Rails.logger.error "BinanceItem::IsolatedMarginImporter #{binance_item.id} - #{e.message}"
    { assets: [], raw: nil, source: "isolated_margin", error: e.message }
  end

  private

    def parse_account(account)
      pair = account["symbol"].presence || "unknown"

      %w[baseAsset quoteAsset].filter_map do |side|
        asset = account[side]
        next unless asset.is_a?(Hash)

        net = asset["netAsset"].to_d
        next if net.zero?

        {
          symbol: asset["asset"],
          free: asset["free"].to_d.to_s("F"),
          locked: asset["locked"].to_d.to_s("F"),
          total: net.to_s("F"),
          net: net.to_s("F"),
          source: "isolated_margin:#{pair}"
        }
      end
    end
end
