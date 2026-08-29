# frozen_string_literal: true

# Fetches the Funding wallet used by P2P, Pay, Card and Gift Card.
class BinanceItem::FundingImporter
  attr_reader :binance_item, :provider

  def initialize(binance_item, provider:)
    @binance_item = binance_item
    @provider = provider
  end

  def import
    raw = provider.get_funding_wallet
    assets = Array(raw).filter_map do |row|
      free = row["free"].to_d
      locked = row["locked"].to_d + row["freeze"].to_d + row["withdrawing"].to_d
      total = free + locked
      next if total.zero?

      normalized_asset(row["asset"], free, locked, total)
    end

    { assets: assets, raw: raw, source: "funding" }
  rescue Provider::Binance::RateLimitError
    raise
  rescue => e
    Rails.logger.error "BinanceItem::FundingImporter #{binance_item.id} - #{e.message}"
    { assets: [], raw: nil, source: "funding", error: e.message }
  end

  private

    def normalized_asset(symbol, free, locked, total)
      {
        symbol: symbol,
        free: free.to_s("F"),
        locked: locked.to_s("F"),
        total: total.to_s("F")
      }
    end
end
